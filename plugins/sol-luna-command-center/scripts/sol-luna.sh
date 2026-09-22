#!/usr/bin/env bash
#
# sol-luna.sh — GPT-5.6 Sol command-center plugin (macOS / Linux / ARM).
#
# Workflow:
#   Sol (Codex) --packet--> ChatGPT Web GPT-5.6 Luna Max --result--> Sol (summary)
#
# This file is a strict behavioural twin of scripts/sol-luna.ps1 for Windows.
# It never silently degrades transport or model.
#
# Pure POSIX-userland by design: bash + coreutils + awk ONLY.
# No python, no jq, no node — JSON is handled by the flat-object helpers below.
#
# Usage:
#   bash sol-luna.sh doctor
#   bash sol-luna.sh init
#   bash sol-luna.sh new-packet --spec <spec.json>
#   bash sol-luna.sh dispatch --id <id> [--transport web-desktop|web-manual|local-worker] [--timeout <sec>]
#   bash sol-luna.sh ingest --id <id> --result <file>
#   bash sol-luna.sh summary --id <id> --text-file <file>
#   bash sol-luna.sh status [--id <id>]
#
# Exit codes: 0 ok | 1 usage/validation | 2 runtime | 3 hash mismatch.
# State directory override: SOL_LUNA_STATE_DIR (default: <plugin>/.sol-luna-state).
# SOL_LUNA_CODEX_BIN pins the codex CLI when set (explicit path for pinned /
# non-PATH installs and tests); used by dispatch. Otherwise dispatch resolves
# `codex` from PATH.
#
# JSON limitations (documented, by design):
#   - execution packets are FLAT objects written by this tool; helpers below
#     parse flat objects only (no nested-array traversal except spec fields).
#   - spec arrays are split on the `", "` boundary; a list item that itself
#     contains the literal sequence `", "` will be split — do not put that
#     sequence inside spec strings.

set -euo pipefail

# ---- resolve plugin dir regardless of where the script lives --------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${SOL_LUNA_STATE_DIR:-$PLUGIN_DIR/.sol-luna-state}"
PACKETS_DIR="$STATE_DIR/packets"
RESULTS_DIR="$STATE_DIR/results"
JOURNAL="$STATE_DIR/journal.jsonl"
DEFAULT_MAX_PAYLOAD_BYTES=12000
# memory boundary: execution.json / results are tool-written state; a
# hand-edited or hostile file must never be slurped unbounded (behavioural
# twin of the .ps1 $MAX_JSON_BYTES).
MAX_JSON_BYTES=1048576
MD_BEGIN="sol-luna:begin"
US="$(printf '\037')"     # unit separator for packing multi-line spec fields
LOCK_FILE=""
CLEANUP_FILES=()

log() { printf 'sol-luna: %s\n' "$*" >&2; }
die() { local rc=$1; shift; printf 'sol-luna: %s\n' "$*" >&2; exit "$rc"; }

cleanup() {
    local f
    for f in ${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}; do
        [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
    done
    if [[ -n "$LOCK_FILE" && -e "$LOCK_FILE" ]]; then rm -f "$LOCK_FILE" 2>/dev/null || true; fi
    return 0
}
trap cleanup EXIT

# ---- json helpers (flat objects only; no python/jq) -----------------------
# json_quote: stdin -> one double-quoted JSON string (escapes \ " and all
# ASCII control chars as \uXXXX, plus \n \t \r shorthand).
json_quote() {
    LC_ALL=C awk '
        BEGIN {
            for (i = 0; i < 32; i++) CTRL[sprintf("%c", i)] = sprintf("\\u%04x", i)
            CTRL["\\"] = "\\\\"; CTRL["\""] = "\\\""
            CTRL["\n"] = "\\n"; CTRL["\t"] = "\\t"; CTRL["\r"] = "\\r"
            printf "\""
        }
        {
            if (NR > 1) printf "\\n"
            s = $0; out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c in CTRL) out = out CTRL[c]
                else out = out c
            }
            printf "%s", out
        }
        END { printf "\"" }'
}
qstr() { printf '%s' "${1:-}" | json_quote; }
qnum() { local n="${1:-}"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }

# json_get <file> <key>: print the value of <key> from a flat JSON object.
# Strings are unescaped; numbers/bare tokens are printed as-is.
# Missing key -> exit 1 (callers decide whether that is fatal).
json_get() {
    LC_ALL=C awk -v key="$2" '
    # Windows-side packets may carry a UTF-8 BOM; strip it or key lookups on
    # the first key silently fail (twin of the ps1 -Encoding UTF8 read).
    NR == 1 { sub(/^\xef\xbb\xbf/, "") }
    {
        buf = buf $0
    }
    END {
        s = buf; n = length(s)
        pat = "\"" key "\""
        start = 1
        while (start <= n) {
            off = index(substr(s, start), pat)
            if (off == 0) exit 1
            pos = start + off - 1
            i = pos + length(pat)
            while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
            if (i > n || substr(s, i, 1) != ":") { start = pos + length(pat); continue }
            i++
            while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
            if (i > n) exit 1
            c = substr(s, i, 1)
            if (c == "\"") {
                out = ""; j = i + 1
                while (j <= n) {
                    d = substr(s, j, 1)
                    if (d == "\\") {
                        e = substr(s, j + 1, 1)
                        if (e == "n")      { out = out "\n"; j += 2 }
                        else if (e == "t") { out = out "\t"; j += 2 }
                        else if (e == "r") { out = out "\r"; j += 2 }
                        else if (e == "u") { out = out "?";  j += 6 }
                        else               { out = out e;   j += 2 }
                    } else if (d == "\"") { break }
                    else { out = out d; j++ }
                }
                printf "%s", out
                exit 0
            }
            j = i
            while (j <= n && substr(s, j, 1) ~ /[0-9eE.+-]/) j++
            printf "%s", substr(s, i, j - i)
            exit 0
        }
        exit 1
    }' "$1"
}

# ---- hashing ---------------------------------------------------------------
have_sha()   { command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; }
sha256_file() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else return 127; fi
}

# ---- CPU-time liveness (for the local-worker inactivity watchdog) -----------
# codex exec buffers its stdout (a redirected file stays 0 bytes until the
# process exits), so output growth cannot be used as a "still alive" signal.
# The worker's CPU time advances steadily while the model generates, so that is
# what the watchdog probes. Return the cumulative CPU time in centiseconds for a
# live PID, or 127 / empty if it cannot be read (then the watchdog is skipped
# rather than ever killing a healthy long run).
cpu_centis() {
    local pid="$1" rest
    # Linux /proc: fields 14 (utime) + 15 (stime) in clock ticks (usually 100/s).
    rest="$(sed -n 's/^.*) \(.*\)$/\1/p' "/proc/$pid/stat" 2>/dev/null)" || return 127
    [ -n "$rest" ] || return 127
    # After the comm-field cut, utime is field 12 and stime field 13.
    local t
    t="$(awk '{print ($12 + $13)}' <<<"$rest")" || return 127
    [ -n "$t" ] || return 127
    printf '%s' "$t"
    return 0
}
# Portable-enough fallback: ps -o time= (BSD/macOS) prints [DD-]HH:MM:SS.
# Not used on Linux/git-bash (which has /proc); kept so macOS never kills a
# healthy worker just because /proc is absent.
cpu_seconds_ps() {
    local pid="$1" t
    t="$(ps -o time= -p "$pid" 2>/dev/null)" || return 127
    [ -n "$t" ] || return 127
    local dd=0 hh=0 mm=0 ss=0 rest
    case "$t" in
        *-*) dd="${t%%-*}"; t="${t#*-}";;
    esac
    IFS=: read -r hh mm ss <<<"$t" || true
    echo $(( 10#$dd * 86400 + 10#$hh * 3600 + 10#$mm * 60 + 10#$ss ))
    return 0
}
# Returns 0 if we can measure a live PID's CPU (either /proc or ps -o time=).
have_cpu_watch() {
    local pid="$1"
    cpu_centis "$pid" >/dev/null 2>&1 && return 0
    cpu_seconds_ps "$pid" >/dev/null 2>&1 && return 0
    return 1
}
cpu_progress() {
    # Cumulative CPU in a comparable unit for a live PID; empty if unreadable.
    local pid="$1"
    cpu_centis "$pid" 2>/dev/null && return 0
    cpu_seconds_ps "$pid" 2>/dev/null && return 0
    return 1
}

# file_bytes <path>: byte count with BSD/macOS padding stripped. `wc -c`
# prints leading spaces there, which would break qnum's ^[0-9]+$ check and
# silently record payload_bytes/result_bytes as 0.
file_bytes() {
    local n; n="$(wc -c < "$1" 2>/dev/null || printf 0)"
    n="${n//[!0-9]/}"
    [[ -n "$n" ]] || n=0
    printf '%s' "$n"
}

# ---- paths & misc ----------------------------------------------------------
ensure_dirs() {
    mkdir -p "$PACKETS_DIR" "$RESULTS_DIR"
    [[ -f "$JOURNAL" ]] || : > "$JOURNAL"
    # Migrate pre-1.0 journals (bare event objects) into the current schema.
    if [[ -s "$JOURNAL" ]]; then
        # Migrate probe bounded to a 64 KB head: the journal is append-only
        # and unbounded, and grep must not slurp it on every command (twin of
        # the ps1 Ensure-Dirs head probe). Current-schema lines carry "event"
        # right at the start, so a head miss means "legacy -> migrate once".
        if ! head -c 65536 "$JOURNAL" 2>/dev/null | grep -q '"event"'; then
            local tmp="$JOURNAL.migrate.$$"
            awk '{print "{\"legacy\":" $0 "}"}' "$JOURNAL" > "$tmp" && mv -f "$tmp" "$JOURNAL"
        fi
    fi
}

resolve_home() { printf '%s' "${HOME:-${USERPROFILE:-}}"; }
codex_dir() {
    if [[ -n "${CODEX_HOME:-}" ]]; then printf '%s' "$CODEX_HOME"; return; fi
    printf '%s' "$(resolve_home)/.codex"
}
agent_toml() { printf '%s' "$(codex_dir)/agents/luna-worker.toml"; }
skill_dst()  { printf '%s' "$(codex_dir)/skills/sol-command-center"; }
agents_md()  { printf '%s' "$PWD/AGENTS.md"; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_rand8() {
    # id entropy tiers: openssl > /dev/urandom > bash PRNG fallback
    if command -v openssl >/dev/null 2>&1; then
        local h; h="$(openssl rand -hex 4 2>/dev/null || true)"
        [[ -n "$h" ]] && { printf '%s' "$h"; return 0; }
    fi
    if [[ -r /dev/urandom ]]; then
        local u; u="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        [[ "$u" =~ ^[0-9a-fA-F]{8}$ ]] && { printf '%s' "$u"; return 0; }
    fi
    printf '%08x' "$(( (RANDOM << 16) ^ RANDOM ^ SECONDS ^ $$ ))"
}
# 60-char cap keeps id-derived filenames ("$id.payload.md" etc.) far below
# any filesystem name limit on every supported platform (twin of the .ps1).
valid_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,59}$ ]]; }

journal_log() {
    local event="$1" id="${2:-}" extra="${3:-}"
    ensure_dirs
    { printf '{"stamp":%s,"event":%s,"id":%s,"extra":%s}\n' \
        "$(qstr "$(now_iso)")" "$(qstr "$event")" "$(qstr "$id")" "$(qstr "$extra")"; } >> "$JOURNAL"
}

load_packet_file() {
    local id="$1" what="${2:-load}"
    local file="$PACKETS_DIR/$id.execution.json"
    [[ -f "$file" ]] || die 2 "${what}: packet '$id' not found at $file"
    # memory boundary: refuse to slurp a hand-edited/garbage execution.json
    # (behavioural twin of the .ps1 $MAX_JSON_BYTES guard).
    local sz; sz="$(file_bytes "$file")"
    (( sz <= MAX_JSON_BYTES )) || die 2 "${what}: execution.json for '$id' exceeds $MAX_JSON_BYTES bytes; refusing unbounded read."
    printf '%s' "$file"
}

packet_state() {
    local pfile; pfile="$(load_packet_file "$1" "${2:-load}")"
    json_get "$pfile" state || die 2 "${2:-load}: cannot read state for packet '$1'"
}

# save_packet: atomic write via temp + mv (never a torn execution.json).
save_packet() {
    local id="$1" json="$2"
    local file="$PACKETS_DIR/$id.execution.json"
    local tmp="$file.tmp.$$"
    CLEANUP_FILES+=("$tmp")
    printf '%s\n' "$json" > "$tmp"
    mv -f "$tmp" "$file"
}

# set_packet_props <id> [key=value | key:=numeric]...
# Rebuilds the execution JSON from the existing packet plus overrides.
# Fixed key set == documented packet schema (behavioural twin of the .ps1).
set_packet_props() {
    local id="$1"; shift
    local file="$PACKETS_DIR/$id.execution.json"
    [[ -f "$file" ]] || die 2 "internal: packet '$id' missing for update"

    local v_state="" v_id="" v_created="" v_model="" v_effort="" v_transport="" \
          v_psha="" v_pbytes="" v_disp="" v_rfile="" v_rsha="" v_rbytes="" \
          v_sfile="" v_ssha=""
    local k v
    for k in state id created_at model effort transport payload_sha256 payload_bytes \
             dispatched_at result_file result_sha256 result_bytes summary_file summary_sha256; do
        v="$(json_get "$file" "$k" 2>/dev/null || true)"
        case "$k" in
            state)          v_state="$v";;
            id)             v_id="$v";;
            created_at)     v_created="$v";;
            model)          v_model="$v";;
            effort)         v_effort="$v";;
            transport)      v_transport="$v";;
            payload_sha256) v_psha="$v";;
            payload_bytes)  v_pbytes="$v";;
            dispatched_at)  v_disp="$v";;
            result_file)    v_rfile="$v";;
            result_sha256)  v_rsha="$v";;
            result_bytes)   v_rbytes="$v";;
            summary_file)   v_sfile="$v";;
            summary_sha256) v_ssha="$v";;
        esac
    done

    # An empty state would bypass every state-machine guard downstream
    # ("" != new/done/ingested is refused on read, but never write one back).
    [[ -n "$v_state" ]] || die 2 "internal: refusing to write empty state for packet '$id'"

    local p key val
    for p in "$@"; do
        case "$p" in
            *:=*) key="${p%%:=*}"; val="${p#*:=}";;
            *=*)  key="${p%%=*}";  val="${p#*=}";;
            *) die 2 "internal: bad update pair '$p'";;
        esac
        case "$key" in
            state)          v_state="$val";;
            id)             v_id="$val";;
            created_at)     v_created="$val";;
            model)          v_model="$val";;
            effort)         v_effort="$val";;
            transport)      v_transport="$val";;
            payload_sha256) v_psha="$val";;
            payload_bytes)  v_pbytes="$val";;
            dispatched_at)  v_disp="$val";;
            result_file)    v_rfile="$val";;
            result_sha256)  v_rsha="$val";;
            result_bytes)   v_rbytes="$val";;
            summary_file)   v_sfile="$val";;
            summary_sha256) v_ssha="$val";;
            *) die 2 "internal: unknown packet key '$key'";;
        esac
    done

    local json
    json="$(printf '{"state":%s,"id":%s,"created_at":%s,"model":%s,"effort":%s,"transport":%s,"payload_sha256":%s,"payload_bytes":%s,"dispatched_at":%s,"result_file":%s,"result_sha256":%s,"result_bytes":%s,"summary_file":%s,"summary_sha256":%s}' \
        "$(qstr "$v_state")" "$(qstr "$v_id")" "$(qstr "$v_created")" "$(qstr "$v_model")" \
        "$(qstr "$v_effort")" "$(qstr "$v_transport")" "$(qstr "$v_psha")" "$(qnum "$v_pbytes")" \
        "$(qstr "$v_disp")" "$(qstr "$v_rfile")" "$(qstr "$v_rsha")" "$(qnum "$v_rbytes")" \
        "$(qstr "$v_sfile")" "$(qstr "$v_ssha")")"
    # NOTE: no nested "result" object — execution.json stays a flat object with
    # one canonical key set, identical to what sol-luna.ps1 writes.
    save_packet "$id" "$json"
}

# ---- per-packet dispatch lock (atomic via noclobber) -----------------------
acquire_lock() {
    local id="$1"
    local lock="$STATE_DIR/lock-$id.json"
    local attempt
    for attempt in 1 2; do
        if (set -o noclobber; printf '{"pid":%d,"created":"%s"}\n' "$$" "$(date +%s)" > "$lock") 2>/dev/null; then
            LOCK_FILE="$lock"
            return 0
        fi
        if [[ ! -f "$lock" ]]; then
            # lost a creation race against a lock that is already gone; retry
            sleep 0.2
            continue
        fi
        # Recover a lock left by a dead process older than 1h (mtime based).
        # If mtime cannot be determined (no stat / odd FS), never force-remove:
        # report the conflict and let a human decide.
        local mtime now age
        mtime="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || true)"
        if [[ -z "$mtime" ]]; then
            # stat could not age the lock (no stat(1) / exotic FS). Under
            # set -e the unguarded fallback previously crashed here with an
            # unbound variable; worse, treating 0 as epoch would delete a
            # LIVE process's lock. Never steal what we cannot age.
            log "dispatch: lock for '$id' exists and its age cannot be determined; refusing to steal it"
            return 1
        fi
        now="$(date +%s)"
        age=$(( now - mtime ))
        # Reclaim a lock whose recorded owner PID is gone, even if younger than
        # 1h: a hard-killed dispatch (user Stop / crash) otherwise blocks
        # re-dispatch for up to an hour. If the lock has no readable pid, fall
        # back to the age rule and never steal what we cannot verify is dead.
        local owner_pid owner_gone
        owner_pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$lock" 2>/dev/null)"
        owner_gone=0
        if [[ -n "$owner_pid" && "$owner_pid" -gt 0 ]] 2>/dev/null; then
            kill -0 "$owner_pid" 2>/dev/null || owner_gone=1
        fi
        if (( owner_gone )) || (( mtime > 0 && age > 3600 )); then
            rm -f "$lock" 2>/dev/null || true
            log "dispatch: removed stale lock for '$id' (owner_gone=$owner_gone, ${age}s old)"
            continue
        fi
        return 1
    done
    return 1
}
release_lock() {
    if [[ -n "$LOCK_FILE" && -e "$LOCK_FILE" ]]; then rm -f "$LOCK_FILE" 2>/dev/null || true; fi
    LOCK_FILE=""
    return 0
}

# ---------------------------------------------------------------------------
cmd_doctor() {
    ensure_dirs
    local toml; toml="$(agent_toml)"
    local has_toml=no
    [[ -f "$toml" ]] && has_toml=yes
    local model="gpt-5.6-luna" effort="max"
    if [[ "$has_toml" = yes ]]; then
        local m e
        m="$(sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$toml" | head -n 1)"
        e="$(sed -nE 's/^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$toml" | head -n 1)"
        [[ -n "$m" ]] && model="$m"
        [[ -n "$e" ]] && effort="$e"
    fi
    local cfg; cfg="$(codex_dir)/config.toml"
    local ask=no
    if [[ -f "$cfg" ]] && grep -Eq 'default_mode_request_user_input[[:space:]]*=[[:space:]]*true' "$cfg"; then
        ask=yes
    fi
    local lw=false at=false ct=false rui=false
    [[ "$has_toml" = yes ]] && lw=true && at=true
    [[ -f "$cfg" ]] && ct=true
    [[ "$ask" = yes ]] && rui=true

    printf '%s\n' \
      '{' \
      "  \"os\": \"posix\"," \
      "  \"plugin_dir\": $(qstr "$PLUGIN_DIR")," \
      "  \"state_dir\": $(qstr "$STATE_DIR")," \
      "  \"size_limit_bytes\": $DEFAULT_MAX_PAYLOAD_BYTES," \
      '  "transports": { "web_desktop": true, "web_manual": true, "local_worker": '"$lw"' },' \
      "  \"agent_toml\": $at," \
      "  \"agent_path\": $(qstr "$toml")," \
      "  \"luna_model\": $(qstr "$model")," \
      "  \"luna_effort\": $(qstr "$effort")," \
      "  \"config_toml\": $ct," \
      "  \"request_user_input\": $rui," \
      '  "probe": "local-worker: verify the model round-trip works (model answers a known-answer question correctly). The gpt-5.6-* tiers run on a gpt-5 base, so a gpt-5/GPT-5 self-identification is expected and still counts for the gpt-5.6-luna + max route; do not gate dispatch on an exact slug. web-desktop/web-manual are verified by the user selecting GPT-5.6 Luna Max in the ChatGPT UI — no local probe required."' \
      '}'
    if [[ "$has_toml" != yes ]]; then
        # First-run guard: surface the exact copy-pasteable fix so the missing
        # step (init) cannot be skipped. %q shell-escapes the path (handles
        # spaces in the checkout dir); CODEX_HOME is honoured by init too, so
        # the same command provisions the agent even with a custom home.
        local initq; initq="$(printf '%q' "$SCRIPT_DIR/sol-luna.sh")"
        log ""
        log "doctor: missing luna_worker agent - the plugin is installed but NOT initialized."
        log "  expected agent file: $toml"
        log "  consequence: the local-worker transport is unavailable and Luna model/effort probes cannot run."
        log "  fix (copy/paste, then re-run doctor):"
        log "    bash $initq init"
        log ""
        exit 2
    fi
    exit 0
}

# ---------------------------------------------------------------------------
cmd_init() {
    ensure_dirs
    local changed=0
    local agents_dir; agents_dir="$(codex_dir)/agents"
    mkdir -p "$agents_dir"
    local toml; toml="$(agent_toml)"
    if [[ -f "$toml" ]]; then
        echo "init: existing agent preserved: $toml"
    else
        cp "$PLUGIN_DIR/agents/luna-worker.toml" "$toml"
        echo "init: wrote $toml"; changed=1
    fi
    local dst; dst="$(skill_dst)"
    local skill_existed=false
    [[ -d "$dst" ]] && skill_existed=true
    mkdir -p "$dst"
    # SKILL.md is plugin-owned: refresh on every init so skill updates
    # propagate (the agent TOML above stays preserve-if-present).
    cp -f "$PLUGIN_DIR/skills/sol-command-center/SKILL.md" "$dst/SKILL.md"
    # Clone the launcher runtime next to SKILL.md. The installed skill copy is
    # invoked with CWD = skill dir, so its documented launcher path
    # ('./scripts/sol-luna.sh') must exist HERE - not two levels up in the
    # plugin checkout. The old copy-if-absent install copied only SKILL.md and
    # left the copy referencing a launcher that existed nowhere
    # (../../scripts/ resolved to ~/.codex/scripts/, which is never created).
    local d srcdir dstdir
    for d in scripts agents templates config; do
        srcdir="$PLUGIN_DIR/$d"
        [[ -d "$srcdir" ]] || continue
        dstdir="$dst/$d"
        mkdir -p "$dstdir"
        srcdir="$(cd "$srcdir" && pwd)"
        dstdir="$(cd "$dstdir" && pwd)"
        [[ "$srcdir" = "$dstdir" ]] && continue   # init from the clone itself
        cp -f "$srcdir"/* "$dstdir"/ 2>/dev/null || true
    done
    if [[ "$skill_existed" = true ]]; then
        echo "init: skill runtime refreshed -> $dst"
    else
        echo "init: installed skill (with launcher runtime) -> $dst"; changed=1
    fi
    local amd; amd="$(agents_md)"
    [[ -f "$amd" ]] || : > "$amd"
    if grep -q "$MD_BEGIN" "$amd" 2>/dev/null; then
        log "init: AGENTS.md already carries sol-luna rules"
    else
        if [[ "$(file_bytes "$amd")" -gt 1 ]]; then printf '\n\n' >> "$amd"; fi
        cat "$PLUGIN_DIR/templates/AGENTS.md" >> "$amd"
        echo "init: merged rules into $amd"; changed=1
    fi
    log "init: config.toml is never auto-edited. Apply config/config.toml.example yourself."
    if [[ "$changed" = 0 ]]; then log "init: already configured (idempotent)"; else log "init: done"; fi
    journal_log "init" "" "changed=$changed"
}

# ---------------------------------------------------------------------------
# extract <key>: pull one field out of $spec (scalar or array -> US-joined).
# Limitations documented in the header (flat scan, `", "` boundary splitting).
extract() {
    LC_ALL=C awk -v key="$1" -v us="$US" '
    function unescape(s,  out, j, d, e) {
        out = ""; j = 1
        while (j <= length(s)) {
            d = substr(s, j, 1)
            if (d == "\\") {
                e = substr(s, j + 1, 1)
                if (e == "n")      { out = out "\n"; j += 2 }
                else if (e == "t") { out = out "\t"; j += 2 }
                else if (e == "r") { out = out "\r"; j += 2 }
                else if (e == "u") { out = out "?";  j += 6 }
                else               { out = out e;   j += 2 }
            } else { out = out d; j++ }
        }
        return out
    }
    {
        buf = buf $0 "\n"
    }
    END {
        s = buf; n = length(s)
        pat = "\"" key "\""
        start = 1
        while (start <= n) {
            off = index(substr(s, start), pat)
            if (off == 0) exit 0
            pos = start + off - 1
            i = pos + length(pat)
            while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
            if (i > n || substr(s, i, 1) != ":") { start = pos + length(pat); continue }
            i++
            while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
            if (i > n) exit 0
            c = substr(s, i, 1)
            if (c == "[") {
                j = index(substr(s, i), "]")
                if (j == 0) exit 0
                arr = substr(s, i + 1, j - 2)
                gsub(/^[ \t\r\n]+/, "", arr); gsub(/[ \t\r\n]+$/, "", arr)
                if (arr == "") exit 0
                m = split(arr, parts, /"[ \t]*,[ \t]*"/)
                out2 = ""
                for (k = 1; k <= m; k++) {
                    v = parts[k]
                    sub(/^"/, "", v); sub(/"$/, "", v)
                    v = unescape(v)
                    out2 = (k == 1) ? v : out2 us v
                }
                printf "%s", out2
                exit 0
            } else if (c == "\"") {
                out2 = ""; j = i + 1
                while (j <= n) {
                    d = substr(s, j, 1)
                    if (d == "\\") {
                        e = substr(s, j + 1, 1)
                        if (e == "n")      { out2 = out2 "\n"; j += 2 }
                        else if (e == "t") { out2 = out2 "\t"; j += 2 }
                        else if (e == "r") { out2 = out2 "\r"; j += 2 }
                        else if (e == "u") { out2 = out2 "?";  j += 6 }
                        else               { out2 = out2 e;   j += 2 }
                    } else if (d == "\"") { break }
                    else { out2 = out2 d; j++ }
                }
                printf "%s", out2
                exit 0
            } else {
                j = i
                while (j <= n && substr(s, j, 1) ~ /[0-9eE.+-]/) j++
                printf "%s", substr(s, i, j - i)
                exit 0
            }
        }
    }' "$spec"
}

cmd_new_packet() {
    ensure_dirs
    local spec=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --spec) [[ $# -ge 2 ]] || die 1 "new-packet: --spec needs a value"; spec="$2"; shift 2;;
        *) die 1 "new-packet: unknown option $1";;
    esac; done
    [[ -n "$spec" ]] || die 1 "new-packet: missing --spec <json>"
    [[ -f "$spec" ]] || die 1 "new-packet: spec not found: $spec"
    [[ -r "$spec" ]] || die 1 "new-packet: spec not readable: $spec"
    command -v awk >/dev/null 2>&1 || die 2 "new-packet: awk not found on PATH"
    have_sha || die 2 "new-packet: need shasum(1) or sha256sum(1) on PATH"
    # memory boundary: a spec larger than the read cap can never produce a
    # payload within the 12000-byte limit; refuse unbounded reads (twin of
    # the .ps1 guard).
    (( "$(file_bytes "$spec")" <= MAX_JSON_BYTES )) || die 1 "new-packet: spec too large (max $MAX_JSON_BYTES bytes)"
    # A UTF-8 BOM shifts every key match by one char, so a BOM'd spec yields
    # empty fields and a bogus "spec.goal required". Strip it once into a
    # private BOM-less copy (twin of the ps1 fallback path).
    if [[ "$(head -c 3 "$spec" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "efbbbf" ]]; then
        local bomless="$PACKETS_DIR/.tmp-spec.$$"
        CLEANUP_FILES+=("$bomless")
        tail -c +4 "$spec" > "$bomless"
        spec="$bomless"
    fi
    # Structural gate: the spec must at least be a JSON object ('{' ... '}'
    # after whitespace stripping). Catches plain-text garbage before it
    # degrades into a misleading "spec.goal required" (exit-code twin of the
    # ps1 ConvertFrom-Json refusal). Full syntax stays out of scope on this
    # side: the byte-scanning extractor has no real JSON parser.
    awk 'BEGIN{body=""} {gsub(/[[:space:]]/,""); body=body $0}
         END{ if (body !~ /^[{].*[}]$/) exit 1 }' "$spec" \
        || die 1 "new-packet: invalid spec JSON"

    local goal symptom rootcause scope inputs accept constraints files evidence
    goal="$(extract goal)"
    symptom="$(extract symptom)"
    rootcause="$(extract root_cause)"
    scope="$(extract scope)"
    inputs="$(extract inputs)"
    accept="$(extract acceptance)"
    constraints="$(extract constraints)"
    files="$(extract files)"
    evidence="$(extract evidence)"
    # whitespace-only goal counts as empty (twin of the ps1 .Trim() check)
    [[ -n "${goal//[[:space:]]/}" ]] || die 1 "new-packet: spec.goal required"

    local tmp_payload="$PACKETS_DIR/.tmp-payload.$$"
    CLEANUP_FILES+=("$tmp_payload")
    {
        printf '# Execution packet (GPT-5.6 Luna Max - bounded executor)\n\n## Goal\n%s\n\n' "$goal"
        printf '## Symptom\n%s\n\n' "$symptom"
        printf '## Root cause (from GPT-5.6 Sol command center)\n%s\n\n' "$rootcause"
        printf '## Scope (do not exceed)\n%s\n\n' "$scope"
        printf '## Inputs\n%s\n\n' "$inputs"
        printf '## Acceptance criteria\n%s\n\n' "$accept"
        printf '## Constraints\n%s\n\n' "$constraints"
        printf '## Relevant files\n%s\n\n' "$files"
        printf '## Evidence\n%s\n\n' "$evidence"
        printf 'Return: (1) exact result, (2) files changed/inspected, (3) checks actually run, (4) verification result, (5) remaining risks.\n'
    } > "$tmp_payload"

    local size; size="$(file_bytes "$tmp_payload")"
    if (( size > DEFAULT_MAX_PAYLOAD_BYTES )); then
        die 2 "new-packet: payload $size bytes > limit $DEFAULT_MAX_PAYLOAD_BYTES; compress spec fields."
    fi

    local id; id="$(date -u +%Y%m%d%H%M%S)-$(_rand8)"
    local psha; psha="$(sha256_file "$tmp_payload")"
    mv -f "$tmp_payload" "$PACKETS_DIR/$id.payload.md"
    cp "$spec" "$PACKETS_DIR/$id.spec.json"
    save_packet "$id" "$(printf '{"state":"new","id":%s,"created_at":%s,"model":"gpt-5.6-luna","effort":"max","transport":"","payload_sha256":%s,"payload_bytes":%s,"dispatched_at":"","result_file":"","result_sha256":"","result_bytes":0,"summary_file":"","summary_sha256":""}' \
        "$(qstr "$id")" "$(qstr "$(now_iso)")" "$(qstr "$psha")" "$(qnum "$size")")"
    journal_log "new-packet" "$id" ""
    echo "created: $id"
    echo "execution: $PACKETS_DIR/$id.execution.json"
    echo "payload:   $PACKETS_DIR/$id.payload.md"
    echo "payload_sha256: $psha"
    echo "payload_bytes: $size"
}

# ---------------------------------------------------------------------------
cmd_dispatch() {
    ensure_dirs
    local id="" transport="local-worker" timeout="900"
    while [[ $# -gt 0 ]]; do case "$1" in
        --id) [[ $# -ge 2 ]] || die 1 "dispatch: --id needs a value"; id="$2"; shift 2;;
        --transport) [[ $# -ge 2 ]] || die 1 "dispatch: --transport needs a value"; transport="$2"; shift 2;;
        --timeout) [[ $# -ge 2 ]] || die 1 "dispatch: --timeout needs a value"; timeout="$2"; shift 2;;
        *) die 1 "dispatch: unknown option $1";;
    esac; done
    [[ -n "$id" ]] || die 1 "dispatch: missing --id"
    valid_id "$id" || die 1 "dispatch: invalid id '$id' (allowed: A-Za-z0-9._-)"
    case "$timeout" in ''|*[!0-9]*) die 1 "dispatch: --timeout must be a positive integer";; esac
    # reject absurd lengths before the arithmetic: $((10#<20 digits>)) aborts
    # with a cryptic out-of-range error instead of our usage message
    [[ ${#timeout} -le 9 ]] || die 1 "dispatch: --timeout must be between 1 and 86400"
    # force base-10: bash arithmetic would read a leading-zero value ('08') as
    # an invalid octal literal and die with a cryptic error instead of ours
    timeout="$((10#$timeout))"
    (( timeout >= 1 )) || die 1 "dispatch: --timeout must be >= 1"
    # upper bound twin of the ps1 $MAX_TIMEOUT_SECONDS: keeps the bounded-
    # executor contract (and the ps1 Invoke-Run millisecond math) sane
    (( timeout <= 86400 )) || die 1 "dispatch: --timeout must be between 1 and 86400"

    local pfile; pfile="$(load_packet_file "$id" 'dispatch')"
    local st; st="$(json_get "$pfile" state)" || die 2 "dispatch: cannot read state for '$id'"
    [[ -n "$st" ]] || die 2 "dispatch: packet '$id' corrupt: empty state"
    json_get "$pfile" id >/dev/null 2>&1 || die 2 "dispatch: packet '$id' corrupt: id missing"
    [[ "$st" == "new" ]] || die 1 "dispatch: packet '$id' in state '$st'; only new packets dispatch."

    if ! acquire_lock "$id"; then
        die 2 "dispatch: '$id' already being dispatched (active or recent lock in $STATE_DIR)"
    fi

    local mdfile="$PACKETS_DIR/$id.payload.md"
    [[ -f "$mdfile" ]] || die 1 "dispatch: payload missing: $mdfile"
    # memory boundary (twin of the ps1 MAX_JSON_BYTES guard): creation already
    # caps payloads at 12000 bytes, so a bigger file here was swapped in.
    (( "$(file_bytes "$mdfile")" <= MAX_JSON_BYTES )) || die 2 "dispatch: payload larger than $MAX_JSON_BYTES bytes: $mdfile"
    local expected actual
    expected="$(json_get "$pfile" payload_sha256)" || die 2 "dispatch: cannot read payload_sha256 for '$id'"
    actual="$(sha256_file "$mdfile")" || die 2 "dispatch: no sha256 tool (shasum/sha256sum) on PATH"
    # Digest-shape guards: an empty/truncated hash must never pass as ""==""
    # (twin of the ps1 malformed-sha256 refusal). Expected is normalized to
    # lowercase; bash 3.2 has no ${var,,}, so use tr.
    [[ "$actual" =~ ^[0-9a-f]{64}$ ]] || die 2 "dispatch: bad payload hash for '$id'"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die 2 "dispatch: packet '$id' corrupt: malformed payload_sha256"
    expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
    if [[ "$actual" != "$expected" ]]; then
        journal_log "dispatch-refused" "$id" "transport=$transport reason=payload-hash-mismatch"
        die 3 "dispatch: payload hash mismatch for '$id'; refusing to run degraded."
    fi

    case "$transport" in
        local-worker)
            local runner
            # SOL_LUNA_CODEX_BIN pins the CLI explicitly (pinned / non-PATH
            # installs), twin of the ps1 resolver; otherwise `codex` from PATH.
            # POSIX never routes argv through cmd.exe, so the BatBadBut .exe
            # requirement is a Windows-only concern and does not apply here.
            if [[ -n "${SOL_LUNA_CODEX_BIN:-}" ]]; then
                [[ -f "$SOL_LUNA_CODEX_BIN" ]] || die 2 "dispatch: local-worker: SOL_LUNA_CODEX_BIN not found: $SOL_LUNA_CODEX_BIN"
                runner="$SOL_LUNA_CODEX_BIN"
            else
                runner="$(command -v codex || true)"
                [[ -n "$runner" ]] || die 2 "dispatch: local-worker: \`codex\` not on PATH; enable Codex CLI or use web-manual"
            fi
            local prompt
            # Current codex-cli (>=0.148 alpha): `exec` takes the prompt as a
            # POSITIONAL arg; the agent's model/effort come from config
            # overrides, NOT the removed `-t <agent>` / `-p <prompt>` flags.
            prompt="$(printf "You are the bounded luna_worker execution agent reporting to GPT-5.6 Sol. Complete only the assigned subtask in the execution packet (%s). Stay strictly in scope and file boundaries. Do not spawn agents or change architecture. Verify when practical. Return a result with: (1) exact result, (2) files changed/inspected, (3) checks run, (4) verification, (5) remaining risks.\n\n" "$id"; cat "$mdfile")"
            # stdout is captured as the result; stderr goes to its own file so
            # runner UI noise never pollutes or truncates the captured result.
            # codex exec reads extra input from stdin and blocks until EOF; the
            # shell never closes the inherited stdin, so it would hang forever.
            # Redirect from /dev/null so the prompt (passed as an arg) is the only
            # input. (twin of the ps1 stdin fix)
            local outfile="$RESULTS_DIR/.tmp-stdout.$$"
            local errfile="$RESULTS_DIR/.tmp-stderr.$$"
            # stdout cannot be captured by command-substitution while also
            # polling the live PID, so park it in a file and read it on exit.
            "$runner" exec --skip-git-repo-check --model gpt-5.6-luna -c 'model_reasoning_effort="max"' "$prompt" < /dev/null >"$outfile" 2>"$errfile" &
            local wpid=$!
            CLEANUP_FILES+=("$outfile" "$errfile")
            # Inactivity watchdog, NOT a wall-clock kill. codex exec buffers its
            # stdout (a redirected file stays 0 bytes until the process exits), so
            # output growth cannot signal liveness; the worker's CPU time advances
            # steadily while it generates, so that is what we probe. A healthy
            # 30-minute audit is never cut mid-stream: we only kill when the worker
            # makes NO CPU progress for $timeout consecutive seconds (a real hang).
            # Completion is only the process exiting and returning its data.
            local rc=0 out=""
            if have_cpu_watch "$wpid"; then
                local prev="" cur="" last_prog now
                prev="$(cpu_progress "$wpid" 2>/dev/null || true)"
                last_prog="$(date +%s)"
                while kill -0 "$wpid" 2>/dev/null; do
                    sleep 1
                    cur="$(cpu_progress "$wpid" 2>/dev/null || true)"
                    now="$(date +%s)"
                    if [[ -n "$cur" && "$cur" != "$prev" ]]; then
                        prev="$cur"
                        last_prog="$now"
                    elif [[ -n "$cur" && $(( now - last_prog )) -ge "$timeout" ]]; then
                        # genuine stall: no CPU progress for $timeout consecutive s
                        kill "$wpid" 2>/dev/null || true
                        wait "$wpid" 2>/dev/null || true
                        rc=124
                        break
                    fi
                    # if we cannot read CPU this tick, keep waiting (never kill a
                    # run whose progress we cannot verify)
                done
                # wait returns the child's exit code; under `set -e` a bare
                # `wait; rc=$?` would abort before rc is captured, so use the
                # `|| rc=$?` idiom (twin of the ps1 Invoke-Run capture).
                if (( rc != 124 )); then
                    wait "$wpid" 2>/dev/null || rc=$?
                fi
            else
                # No CPU source on this host (no /proc, no ps -o): rather than
                # risk killing a healthy long run on a false timer, wait for the
                # worker to exit naturally. The stdin fix already prevents the
                # classic infinite hang.
                wait "$wpid" 2>/dev/null || rc=$?
            fi
            out="$(cat "$outfile" 2>/dev/null || true)"
            if (( rc != 0 )); then
                if (( rc == 124 )); then
                    echo "dispatch: codex exec stalled (no CPU progress for ${timeout}s)" >&2
                else
                    echo "dispatch: codex exec exited $rc" >&2
                fi
                {
                    printf '%s\n' "$out"
                    printf '%s\n' '--- stderr ---'
                    cat "$errfile" 2>/dev/null || true
                } > "$RESULTS_DIR/$id.run-error.log" 2>/dev/null || true
                journal_log "dispatch-failed" "$id" "transport=local-worker exit=$rc"
                exit 2
            fi
            # journal twin of the ps1 local-worker success path
            journal_log "dispatch" "$id" "transport=local-worker"
            local res="$RESULTS_DIR/$id.result.md"
            # memory boundary: a runaway child's stdout is never silently
            # truncated (no silent degradation) -- park it verbatim, refuse.
            if (( ${#out} > MAX_JSON_BYTES )); then
                printf '%s' "$out" > "$RESULTS_DIR/$id.result-oversize.log" 2>/dev/null || true
                journal_log "dispatch-failed" "$id" "transport=local-worker reason=result-oversize"
                die 2 "dispatch: worker result exceeds $MAX_JSON_BYTES bytes; parked at $RESULTS_DIR/$id.result-oversize.log"
            fi
            printf '%s\n' "$out" > "$res"
            local rsha rbytes
            rsha="$(sha256_file "$res")" || die 2 "dispatch: no sha256 tool for result hash"
            rbytes="$(file_bytes "$res")"
            set_packet_props "$id" \
                "state=done" "transport=local-worker" "dispatched_at=$(now_iso)" \
                "result_file=$res" "result_sha256=$rsha" "result_bytes:=$rbytes"
            journal_log "run-done" "$id" "transport=local-worker exit=0"
            echo "done (local-worker): $res"
            ;;
        web-desktop|web-manual)
            local clip="$RESULTS_DIR/$id.to-web.txt"
            # Stage via temp + rename so the final file never appears
            # half-written; register the temp for trap cleanup.
            local clip_part="$clip.part.$$"
            CLEANUP_FILES+=("$clip_part")
            cp "$mdfile" "$clip_part"
            mv -f "$clip_part" "$clip"
            # mv won the race: the trap must no longer unlink the (now
            # final) staged file through the stale $$.part name.
            CLEANUP_FILES=()
            set_packet_props "$id" "state=done" "transport=$transport" "dispatched_at=$(now_iso)"
            journal_log "dispatch" "$id" "transport=$transport"
            echo "$transport staged: $clip"
            echo "Open chatgpt.com with GPT-5.6 Luna Max selected, paste payload, then save reply to:"
            echo "  $RESULTS_DIR/$id.web-result.md"
            ;;
        *) die 1 "dispatch: unknown transport '$transport' (web-desktop|web-manual|local-worker)";;
    esac
}

# ---------------------------------------------------------------------------
cmd_ingest() {
    ensure_dirs
    local id="" result=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --id) [[ $# -ge 2 ]] || die 1 "ingest: --id needs a value"; id="$2"; shift 2;;
        --result) [[ $# -ge 2 ]] || die 1 "ingest: --result needs a value"; result="$2"; shift 2;;
        *) die 1 "ingest: unknown option $1";;
    esac; done
    [[ -n "$id" ]] || die 1 "ingest: missing --id"
    valid_id "$id" || die 1 "ingest: invalid id '$id'"
    [[ -n "$result" ]] || die 1 "ingest: missing --result <path>"
    [[ -f "$result" ]] || die 1 "ingest: result not found: $result"
    # memory boundary: refuse absurd result files before hashing/byte-counting
    # (behavioural twin of the .ps1 $MAX_JSON_BYTES guard).
    (( "$(file_bytes "$result")" <= MAX_JSON_BYTES )) || die 2 "ingest: result larger than $MAX_JSON_BYTES bytes: $result"
    have_sha || die 2 "ingest: need shasum(1) or sha256sum(1) on PATH"

    local pfile; pfile="$(load_packet_file "$id" 'ingest')"
    local st; st="$(json_get "$pfile" state)" || die 2 "ingest: cannot read state for '$id'"
    [[ -n "$st" ]] || die 2 "ingest: packet '$id' corrupt: empty state"
    json_get "$pfile" id >/dev/null 2>&1 || die 2 "ingest: packet '$id' corrupt: id missing"
    [[ "$st" == "done" ]] || die 1 "ingest: packet '$id' in state '$st'; dispatch it first (state 'done' required)."

    local rsha rbytes
    rsha="$(sha256_file "$result")" || die 2 "ingest: no sha256 tool (shasum/sha256sum) on PATH"
    rbytes="$(file_bytes "$result")"
    # Parent binding: dispatch (local-worker) pre-registers the result hash.
    # An ingested file whose hash disagrees was tampered with or belongs to
    # another packet — refuse with exit 3, never overwrite the recorded value.
    local recorded=""
    recorded="$(json_get "$pfile" result_sha256 || true)"
    if [[ -n "$recorded" ]]; then
        # shape guard (twin of the ps1 Test-Sha256Shape check): a garbage
        # recorded hash is packet corruption (exit 2), not a mere mismatch.
        [[ "$recorded" =~ ^[0-9a-fA-F]{64}$ ]] \
            || die 2 "ingest: packet '$id' corrupt: malformed result_sha256"
        if [[ "$recorded" != "$rsha" ]]; then
            journal_log "ingest-refused" "$id" "reason=result-hash-mismatch"
            die 3 "ingest: result hash mismatch for '$id'; recorded at dispatch: $recorded, file: $rsha"
        fi
    fi
    set_packet_props "$id" "state=ingested" "result_file=$result" "result_sha256=$rsha" "result_bytes:=$rbytes"
    journal_log "ingest" "$id" "sha256=$rsha"
    echo "ingested: $id"
    echo "result_sha256: $rsha"
}

# ---------------------------------------------------------------------------
cmd_summary() {
    ensure_dirs
    local id="" text=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --id) [[ $# -ge 2 ]] || die 1 "summary: --id needs a value"; id="$2"; shift 2;;
        --text-file) [[ $# -ge 2 ]] || die 1 "summary: --text-file needs a value"; text="$2"; shift 2;;
        *) die 1 "summary: unknown option $1";;
    esac; done
    [[ -n "$id" ]] || die 1 "summary: missing --id"
    valid_id "$id" || die 1 "summary: invalid id '$id'"
    [[ -n "$text" ]] || die 1 "summary: missing --text-file <path>"
    [[ -f "$text" ]] || die 1 "summary: text file not found: $text"
    # memory boundary, twin of the ingest guard.
    (( "$(file_bytes "$text")" <= MAX_JSON_BYTES )) || die 2 "summary: text larger than $MAX_JSON_BYTES bytes: $text"
    have_sha || die 2 "summary: need shasum(1) or sha256sum(1) on PATH"

    local pfile; pfile="$(load_packet_file "$id" 'summary')"
    local st; st="$(json_get "$pfile" state)" || die 2 "summary: cannot read state for '$id'"
    [[ -n "$st" ]] || die 2 "summary: packet '$id' corrupt: empty state"
    json_get "$pfile" id >/dev/null 2>&1 || die 2 "summary: packet '$id' corrupt: id missing"
    [[ "$st" == "ingested" ]] || die 1 "summary: packet '$id' in state '$st'; ingest a result first."

    local out="$RESULTS_DIR/$id.summary.md"
    cp "$text" "$out"
    local ssha; ssha="$(sha256_file "$text")" || die 2 "summary: no sha256 tool (shasum/sha256sum) on PATH"
    set_packet_props "$id" "state=summarized" "summary_file=$out" "summary_sha256=$ssha"
    journal_log "summary" "$id" "sha256=$ssha"
    echo "summary written: $out"
}

# ---------------------------------------------------------------------------
cmd_status() {
    ensure_dirs
    local id=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --id) [[ $# -ge 2 ]] || die 1 "status: --id needs a value"; id="$2"; shift 2;;
        *) die 1 "status: unknown option $1";;
    esac; done
    local files=()
    if [[ -n "$id" ]]; then
        valid_id "$id" || die 1 "status: invalid id '$id'"
        if [[ -f "$PACKETS_DIR/$id.execution.json" ]]; then
            files=("$PACKETS_DIR/$id.execution.json")
        fi
    else
        shopt -s nullglob
        files=( "$PACKETS_DIR"/*.execution.json )
        shopt -u nullglob
    fi
    if (( ${#files[@]} == 0 )); then
        echo "status: no packets in $PACKETS_DIR"
        return 0
    fi
    local f
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        local sid="" sstate="" strans="" screated=""
        if [[ -n "$id" ]]; then
            # Explicit single-packet query: an unreadable/corrupt packet is an
            # error (exit 2), never a silent empty row (twin of sol-luna.ps1).
            # Bulk listing keeps skipping bad files so one packet cannot blind it.
            sstate="$(json_get "$f" state)" || die 2 "status: cannot read state for '$id' (corrupt execution.json?)"
        else
            # corrupt execution.json in bulk listing: skip, keep the rest visible
            sstate="$(json_get "$f" state || true)"
        fi
        sid="$(json_get "$f" id || true)"
        strans="$(json_get "$f" transport || true)"
        screated="$(json_get "$f" created_at || true)"
        printf '{"id":%s,"state":%s,"transport":%s,"created":%s}\n' \
            "$(qstr "$sid")" "$(qstr "$sstate")" "$(qstr "$strans")" "$(qstr "$screated")"
    done
}

# ------------------------------ command dispatch ---------------------------
main() {
    command -v awk >/dev/null 2>&1 || die 2 "sol-luna: awk is required but not on PATH"
    local cmd="${1:-}"
    [[ $# -gt 0 ]] && shift || true
    case "$cmd" in
        doctor) cmd_doctor;;
        init) cmd_init;;
        new-packet) cmd_new_packet "$@";;
        dispatch) cmd_dispatch "$@";;
        ingest) cmd_ingest "$@";;
        summary) cmd_summary "$@";;
        status) cmd_status "$@";;
        ""|help|-h|--help)
            # sed -n on $0 can no-op when the script is on a mangled PATH
            # entry; always print a real usage line and exit 1 (usage error).
            if [[ -r "$0" ]]; then sed -n '2,24p' "$0" 2>/dev/null || true; fi
            die 1 "usage: sol-luna.sh <doctor|init|new-packet|dispatch|ingest|summary|status>";;
        *) die 1 "unknown command: $cmd";;
    esac
}

# Run only when executed directly; sourcing this file must be side-effect free.
# `|| exit $?` preserves the child's exit code under `set -e` (POSIX trap quirk).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@" || exit $?
fi
