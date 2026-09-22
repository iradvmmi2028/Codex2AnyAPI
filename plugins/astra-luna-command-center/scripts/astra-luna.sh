#!/usr/bin/env bash
#
# astra-luna.sh — GPT-6 Astra command-center plugin (macOS / Linux / ARM).
#
# Workflow:
#   GPT-6 Astra (Codex) --packet--> gpt-5.6-luna workers (max effort) --result--> Astra (summary)
#
# This file is a strict behavioural twin of scripts/astra-luna.ps1 for Windows.
# It never silently degrades transport or model.
#
# Pure POSIX-userland by design: bash + coreutils + awk ONLY.
# No python, no jq, no node — JSON is handled by the flat-object helpers below.
#
# Usage:
#   bash astra-luna.sh doctor
#   bash astra-luna.sh init
#   bash astra-luna.sh new-packet --spec <spec.json>
#   bash astra-luna.sh dispatch --id <id> [--transport web-manual|local-worker|chatgpt-web|diy-openai] [--timeout <sec>]
#   bash astra-luna.sh ingest --id <id> --result <file>
#   bash astra-luna.sh summary --id <id> --text-file <file>
#   bash astra-luna.sh status [--id <id>]
#   bash astra-luna.sh diy-set [--base-url <url>] [--api-key <key>] [--model <id>] [--enabled true|false] [--replace-luna true|false]
#   bash astra-luna.sh diy-show | diy-clear | diy-test | diy-models | diy-schema
#
# Exit codes: 0 ok | 1 usage/validation | 2 runtime | 3 hash mismatch.
# State directory override: ASTRA_LUNA_STATE_DIR (default: <plugin>/.astra-luna-state).
# Codex home override: CODEX_HOME (default ~/.codex). ASTRA_LUNA_CODEX_BIN pins
# the codex CLI when set (explicit path for pinned / non-PATH installs and
# tests); it is used by the doctor config probe and by dispatch. Otherwise
# dispatch resolves `codex` from PATH.
# chatgpt-web transport overrides: ASTRA_LUNA_PYTHON (interpreter),
# ASTRA_LUNA_CHATGPT_BIN (explicit chatgpt-web.py), ASTRA_LUNA_CHATGPT_PROFILE
# (browser profile dir), ASTRA_LUNA_CHATGPT_BROWSER (browser executable).
# DIY (astra-Diy) overrides: ASTRA_DIY_CONFIG (diy.json path), ASTRA_DIY_API_KEY
# (API key override), ASTRA_DIY_BIN (openai-diy.py path). DIY replaces the
# gpt-5.6-luna worker when enabled + replace_luna; Astra remains the tower.
#
# Security notes:
#   - dispatch is SINGLE-READ bound: the payload is copied once into a private
#     mktemp snapshot (0600); the SHA-256 is verified over the snapshot and the
#     snapshot is what reaches the worker / web staging file. The old
#     hash-file-then-reread-file pattern (a TOCTOU swap window) is gone.
#   - summary copies first and hashes the final copy, so summary_sha256 always
#     matches the bytes on disk.
#   - every temp file inside the state dir is created with mktemp (random name,
#     0600); predictable names are a symlink-planting hazard on shared hosts.
#   - the state dir is chmod 700; packet payloads and results stay private.
#   - lock-owner liveness uses `ps -p` (a foreign-user process's EPERM from
#     kill -0 is no longer misread as "owner gone", which could steal a live
#     lock and double-dispatch one packet).
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
STATE_DIR="${ASTRA_LUNA_STATE_DIR:-$PLUGIN_DIR/.astra-luna-state}"
PACKETS_DIR="$STATE_DIR/packets"
RESULTS_DIR="$STATE_DIR/results"
JOURNAL="$STATE_DIR/journal.jsonl"
DEFAULT_MAX_PAYLOAD_BYTES=12000
# memory boundary: execution.json / results are tool-written state; a
# hand-edited or hostile file must never be slurped unbounded (behavioural
# twin of the .ps1 $MAX_JSON_BYTES).
MAX_JSON_BYTES=1048576
ASTRA_MODEL="gpt-6-astra"     # orchestrator (config.toml advisory; never edited here)
ASTRA_EFFORT="high"
LUNA_MODEL="gpt-5.6-luna"     # default worker fleet (replaced by DIY when enabled)
LUNA_EFFORT="max"
MD_BEGIN="astra-luna:begin"
US="$(printf '\037')"     # unit separator for packing multi-line spec fields
LOCK_FILE=""
CLEANUP_FILES=()

# ---- astra-Diy (OpenAI-compatible custom worker) ---------------------------
diy_config_path() {
    if [[ -n "${ASTRA_DIY_CONFIG:-}" ]]; then
        printf '%s' "$ASTRA_DIY_CONFIG"
    else
        printf '%s' "$STATE_DIR/diy.json"
    fi
}
openai_diy_script() {
    if [[ -n "${ASTRA_DIY_BIN:-}" && -f "$ASTRA_DIY_BIN" ]]; then
        printf '%s' "$ASTRA_DIY_BIN"
    elif [[ -f "$PLUGIN_DIR/scripts/openai-diy.py" ]]; then
        printf '%s' "$PLUGIN_DIR/scripts/openai-diy.py"
    else
        printf ''
    fi
}
find_python_bin() {
    if [[ -n "${ASTRA_LUNA_PYTHON:-}" && -f "$ASTRA_LUNA_PYTHON" ]]; then
        printf '%s' "$ASTRA_LUNA_PYTHON"
        return 0
    fi
    local n
    for n in python python3 py; do
        if command -v "$n" >/dev/null 2>&1; then
            command -v "$n"
            return 0
        fi
    done
    return 1
}
# Flat-field probes against diy.json (no jq). DIY transport readiness requires
# enabled=true, a non-empty base_url/model, and an api_key (file or env).
diy_json_field() { # diy_json_field <key>
    local f; f="$(diy_config_path)"
    [[ -f "$f" ]] || return 1
    sed -nE "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$f" | head -n 1
}
diy_json_bool() { # diy_json_bool <key> -> prints true/false/empty
    local f; f="$(diy_config_path)"
    [[ -f "$f" ]] || { printf ''; return 0; }
    local v
    v="$(sed -nE "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*(true|false).*/\1/p" "$f" | head -n 1)"
    printf '%s' "$v"
}
diy_ready() {
    local f; f="$(diy_config_path)"
    [[ -f "$f" ]] || return 1
    local en base model key rl
    en="$(diy_json_bool enabled)"
    base="$(diy_json_field base_url || true)"
    model="$(diy_json_field model || true)"
    key="$(diy_json_field api_key || true)"
    rl="$(diy_json_bool replace_luna)"
    [[ "$en" == "true" ]] || return 1
    [[ -n "$base" ]] || return 1
    [[ -n "$model" ]] || return 1
    if [[ -z "$key" && -z "${ASTRA_DIY_API_KEY:-}" ]]; then return 1; fi
    return 0
}
diy_replaces_luna() {
    diy_ready || return 1
    local rl; rl="$(diy_json_bool replace_luna)"
    # default true when key absent
    if [[ -z "$rl" || "$rl" == "true" ]]; then return 0; fi
    return 1
}
run_openai_diy() { # run_openai_diy <args...>
    local script py
    script="$(openai_diy_script)"
    [[ -n "$script" ]] || die 2 "diy: openai-diy.py not found (set ASTRA_DIY_BIN)"
    py="$(find_python_bin)" || die 2 "diy: python not found; set ASTRA_LUNA_PYTHON"
    "$py" "$script" "$@"
}

log() { printf 'astra-luna: %s\n' "$*" >&2; }
die() { local rc=$1; shift; printf 'astra-luna: %s\n' "$*" >&2; exit "$rc"; }

cleanup() {
    local f
    for f in ${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}; do
        [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
    done
    if [[ -n "$LOCK_FILE" && -e "$LOCK_FILE" ]]; then rm -f "$LOCK_FILE" 2>/dev/null || true; fi
    return 0
}
trap cleanup EXIT

# mktemp wrapper confined to a state subdir: random name + 0600, registered
# for trap cleanup. All intermediate files use this (no predictable names).
new_temp() { # new_temp <dir> <prefix>
    local t
    t="$(mktemp "$1/$2.XXXXXX" 2>/dev/null)" || die 2 "internal: mktemp failed in $1"
    CLEANUP_FILES+=("$t")
    printf '%s' "$t"
}

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

# pid_alive <pid>: 0 = a process with this pid exists.
# `ps -p` is the authority: unlike `kill -0`, it never reports EPERM on a
# foreign-user process as "no such process", so a live lock owned by another
# user can never be stolen (kill -0 stays as the fallback where ps is absent).
pid_alive() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if command -v ps >/dev/null 2>&1; then
        ps -p "$pid" -o pid= >/dev/null 2>&1
        return $?
    fi
    kill -0 "$pid" 2>/dev/null
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
    # Owner-only state dir: packet payloads and results may hold sensitive
    # material; the plugin checkout must never leak them to other local users.
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    if [[ ! -f "$JOURNAL" ]]; then
        ( umask 077; : > "$JOURNAL" )
    fi
    # Migrate pre-1.0 journals (bare event objects) into the current schema.
    if [[ -s "$JOURNAL" ]]; then
        # Migrate probe bounded to a 64 KB head: the journal is append-only
        # and unbounded, and grep must not slurp it on every command (twin of
        # the ps1 Ensure-Dirs head probe). Current-schema lines carry "event"
        # right at the start, so a head miss means "legacy -> migrate once".
        if ! head -c 65536 "$JOURNAL" 2>/dev/null | grep -q '"event"'; then
            local tmp
            tmp="$(new_temp "$STATE_DIR" "journal-migrate")"
            awk '{print "{\"legacy\":" $0 "}"}' "$JOURNAL" > "$tmp" && mv -f "$tmp" "$JOURNAL"
        fi
    fi
}

resolve_home() { printf '%s' "${HOME:-${USERPROFILE:-}}"; }
codex_dir() {
    if [[ -n "${CODEX_HOME:-}" ]]; then printf '%s' "$CODEX_HOME"; return; fi
    printf '%s' "$(resolve_home)/.codex"
}
agents_dir()      { printf '%s' "$(codex_dir)/agents"; }
primary_agent_toml() { printf '%s' "$(agents_dir)/astra-worker.toml"; }
skill_dst()  { printf '%s' "$(codex_dir)/skills/astra-command-center"; }
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

# save_packet: atomic write via RANDOM mktemp temp + mv (never a torn
# execution.json, and no predictable temp name to pre-plant a symlink on).
save_packet() {
    local id="$1" json="$2"
    local file="$PACKETS_DIR/$id.execution.json"
    local tmp; tmp="$(new_temp "$PACKETS_DIR" "tmp-exec")"
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
    # one canonical key set, identical to what astra-luna.ps1 writes.
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
        # re-dispatch for up to an hour. Liveness is decided by pid_alive
        # (ps -p first): a foreign-user owner previously looked "dead" because
        # kill -0 failed with EPERM, which let two dispatchers run one packet.
        # If the lock has no readable pid, fall back to the age rule and never
        # steal what we cannot verify is dead.
        local owner_pid owner_gone
        owner_pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$lock" 2>/dev/null)"
        owner_gone=0
        if [[ -n "$owner_pid" && "$owner_pid" -gt 0 ]] 2>/dev/null; then
            pid_alive "$owner_pid" || owner_gone=1
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
    local toml; toml="$(primary_agent_toml)"
    local agentsd; agentsd="$(agents_dir)"
    local has_toml=no
    [[ -f "$toml" ]] && has_toml=yes
    local installed=0
    if [[ -d "$agentsd" ]]; then
        installed="$(find "$agentsd" -maxdepth 1 -name 'astra-*.toml' -type f 2>/dev/null | wc -l | tr -d ' ')"
    fi
    local model="$LUNA_MODEL" effort="$LUNA_EFFORT"
    if [[ "$has_toml" = yes ]]; then
        local m e
        m="$(sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$toml" | head -n 1)"
        e="$(sed -nE 's/^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$toml" | head -n 1)"
        [[ -n "$m" ]] && model="$m"
        [[ -n "$e" ]] && effort="$e"
    fi
    local cfg; cfg="$(codex_dir)/config.toml"
    local ask=no cfg_model="" cfg_effort=""
    if [[ -f "$cfg" ]]; then
        if grep -Eq 'default_mode_request_user_input[[:space:]]*=[[:space:]]*true' "$cfg"; then
            ask=yes
        fi
        # advisory only: report what the orchestrator is actually set to so a
        # session still running a non-Astra model is visible in the verdict.
        cfg_model="$(sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$cfg" | head -n 1)"
        cfg_effort="$(sed -nE 's/^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$cfg" | head -n 1)"
    fi
    local lw=false at=false ct=false rui=false
    [[ "$has_toml" = yes ]] && at=true
    [[ -f "$cfg" ]] && ct=true
    [[ "$ask" = yes ]] && rui=true

    # codex CLI config-load probe (read-only, twin of the ps1): the #1 silent
    # killer of the local-worker transport is a config.toml the CLI cannot
    # parse - exit 1 ("invalid type: ...", e.g. a nested [features.*] table)
    # BEFORE any model call, while the desktop app itself keeps running, so
    # doctor must ask the CLI itself. `codex login status` loads the full
    # config and never calls the model; "Not logged in" (exit 1) is an AUTH
    # state, not a config failure, and must not be reported as one.
    local codex_bin="" has_cli=false cli_cfg=true cli_err=""
    if [[ -n "${ASTRA_LUNA_CODEX_BIN:-}" ]]; then
        [[ -f "$ASTRA_LUNA_CODEX_BIN" ]] && codex_bin="$ASTRA_LUNA_CODEX_BIN"
    elif command -v codex >/dev/null 2>&1; then
        codex_bin="$(command -v codex)"
    fi
    [[ -n "$codex_bin" ]] && has_cli=true
    if [[ "$has_cli" = true ]]; then
        local pout perr
        pout="$(new_temp "$STATE_DIR" "probe-out")"
        perr="$(new_temp "$STATE_DIR" "probe-err")"
        if ! "$codex_bin" login status </dev/null >"$pout" 2>"$perr"; then
            if cat "$pout" "$perr" 2>/dev/null | grep -Eq 'Error loading configuration|invalid type|failed to load config'; then
                cli_cfg=false
                cli_err="$(cat "$pout" "$perr" 2>/dev/null | grep -Em1 'Error loading configuration|invalid type|failed to load config' | head -c 240 || true)"
            fi
        fi
    fi
    # local_worker availability = agent TOML present AND a codex CLI that can
    # actually load its config (no silent degradation).
    [[ "$has_toml" = yes && "$has_cli" = true && "$cli_cfg" = true ]] && lw=true

    # chatgpt-web environment probe (offline, twin of the ps1
    # Test-ChatGPTWebEnv): python interpreter + playwright import + browser
    # executable + script + profile existence. NEVER opens a browser.
    local py_bin="" py_ok=false pw_ok=false pw_err="" br="" br_ok=false profile_path="" profile_exists=false script_path="" script_exists=false cw_ok=false
    if [[ -n "${ASTRA_LUNA_PYTHON:-}" && -f "$ASTRA_LUNA_PYTHON" ]]; then
        py_bin="$ASTRA_LUNA_PYTHON"
    elif command -v python >/dev/null 2>&1; then
        py_bin="$(command -v python)"
    elif command -v python3 >/dev/null 2>&1; then
        py_bin="$(command -v python3)"
    elif command -v py >/dev/null 2>&1; then
        py_bin="$(command -v py)"
    fi
    [[ -n "$py_bin" ]] && py_ok=true
    if [[ "$py_ok" = true ]]; then
        local wypout wypErr
        wypout="$(new_temp "$STATE_DIR" "cw-probe-out")"
        wypErr="$(new_temp "$STATE_DIR" "cw-probe-err")"
        if "$py_bin" -c 'import playwright; print("ok")' </dev/null >"$wypout" 2>"$wypErr"; then
            pw_ok=true
        else
            pw_err="$(head -c 160 "$wypErr" 2>/dev/null | tr '\n' ' ')"
        fi
    fi
    profile_path="${ASTRA_LUNA_CHATGPT_PROFILE:-$STATE_DIR/chatgpt-web-profile}"
    [[ -d "$profile_path" ]] && profile_exists=true
    if [[ -n "${ASTRA_LUNA_CHATGPT_BROWSER:-}" ]]; then
        [[ -f "$ASTRA_LUNA_CHATGPT_BROWSER" ]] && br="$ASTRA_LUNA_CHATGPT_BROWSER"
    else
        # 用户默认浏览器优先：QQ 浏览器 > Edge > Chrome
        for c in "/Applications/Tencent/QQBrowser/QQBrowser.app/Contents/MacOS/QQBrowser" \
                 "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
                 "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                 "/usr/bin/microsoft-edge" "/usr/bin/google-chrome" "/usr/bin/chromium"; do
            [[ -f "$c" ]] && { br="$c"; break; }
        done
    fi
    if [[ -n "${ASTRA_LUNA_CHATGPT_BIN:-}" ]]; then
        [[ -f "$ASTRA_LUNA_CHATGPT_BIN" ]] && script_path="$ASTRA_LUNA_CHATGPT_BIN"
    elif [[ -f "$PLUGIN_DIR/scripts/chatgpt-web.py" ]]; then
        script_path="$PLUGIN_DIR/scripts/chatgpt-web.py"
    fi
    [[ -n "$script_path" ]] && script_ok=true
    [[ -n "$br" ]] && br_ok=true
    [[ "$py_ok" = true && "$pw_ok" = true && "$br_ok" = true && "$script_ok" = true ]] && cw_ok=true

    # astra-Diy readiness (offline probes only; network tests are diy-test)
    local diy_en=false diy_ready_flag=false diy_rl=false diy_base="" diy_model="" diy_ok=false en rl
    local dpy; dpy="$(find_python_bin || true)"
    local dscript; dscript="$(openai_diy_script || true)"
    if diy_ready; then
        diy_ready_flag=true
        diy_en=true
        diy_base="$(diy_json_field base_url || true)"
        diy_model="$(diy_json_field model || true)"
        if diy_replaces_luna; then diy_rl=true; fi
        if [[ -n "$dpy" && -n "$dscript" ]]; then diy_ok=true; fi
    else
        en="$(diy_json_bool enabled || true)"; [[ "$en" == "true" ]] && diy_en=true
        diy_base="$(diy_json_field base_url || true)"
        diy_model="$(diy_json_field model || true)"
        rl="$(diy_json_bool replace_luna || true)"; [[ -z "$rl" || "$rl" == "true" ]] && diy_rl=true
    fi
    local worker_route="local-worker/gpt-5.6-luna" worker_model="$LUNA_MODEL"
    if [[ "$diy_rl" == true && "$diy_ready_flag" == true ]]; then
        worker_route="diy-openai"
        worker_model="${diy_model:-diy}"
    fi

    printf '%s\n' \
      '{' \
      '  "plugin": "astra-luna-command-center",' \
      "  \"os\": \"posix\"," \
      "  \"plugin_dir\": $(qstr "$PLUGIN_DIR")," \
      "  \"state_dir\": $(qstr "$STATE_DIR")," \
      "  \"size_limit_bytes\": $DEFAULT_MAX_PAYLOAD_BYTES," \
      "  \"astra_model\": $(qstr "$ASTRA_MODEL")," \
      "  \"astra_effort\": $(qstr "$ASTRA_EFFORT")," \
      "  \"config_model\": $(qstr "$cfg_model")," \
      "  \"config_effort\": $(qstr "$cfg_effort")," \
      '  "transports": { "web_manual": true, "local_worker": '"$lw"', "chatgpt_web": '"$cw_ok"', "diy_openai": '"$diy_ok"' },' \
      "  \"worker_model\": $(qstr "$worker_model")," \
      "  \"worker_route\": $(qstr "$worker_route")," \
      "  \"diy\": { \"enabled\": $diy_en, \"ready\": $diy_ready_flag, \"replace_luna\": $diy_rl, \"base_url\": $(qstr "$diy_base"), \"model\": $(qstr "$diy_model"), \"python_ok\": $([[ -n "$dpy" ]] && echo true || echo false), \"client_ok\": $([[ -n "$dscript" ]] && echo true || echo false), \"transport_ok\": $diy_ok, \"config_path\": $(qstr "$(diy_config_path)") }," \
      "  \"agent_toml\": $at," \
      "  \"agent_dir\": $(qstr "$agentsd")," \
      "  \"agents_installed\": $installed," \
      "  \"agent_path\": $(qstr "$toml")," \
      "  \"luna_model\": $(qstr "$model")," \
      "  \"luna_effort\": $(qstr "$effort")," \
      "  \"config_toml\": $ct," \
      "  \"codex_cli\": $has_cli," \
      "  \"codex_cli_path\": $(qstr "$codex_bin")," \
      "  \"codex_cli_config\": $cli_cfg," \
      "  \"codex_cli_error\": $(qstr "$cli_err")," \
      "  \"request_user_input\": $rui," \
      '  "chatgpt_web": {' \
      "    \"python\": $(qstr "$py_bin")," \
      "    \"python_ok\": $py_ok," \
      "    \"playwright\": $pw_ok," \
      "    \"playwright_error\": $(qstr "$pw_err")," \
      "    \"browser\": $(qstr "$br")," \
      "    \"browser_ok\": $br_ok," \
      "    \"script\": $(qstr "$script_path")," \
      "    \"script_ok\": $script_ok," \
      "    \"profile\": $(qstr "$profile_path")," \
      "    \"profile_exists\": $profile_exists," \
      "    \"ok\": $cw_ok" \
      '  },' \
      '  "probe": "chatgpt-web: environment report above; run `python chatgpt-web.py status` (or `... login` for first-time auth) to confirm the ChatGPT browser login state. local-worker: verify the model round-trip works (model answers a known-answer question correctly). The gpt-5.6-* tiers run on a gpt-5 base, so a gpt-5/GPT-5 self-identification is expected and still counts for the gpt-5.6-luna + max route; do not gate dispatch on an exact slug. diy-openai: run diy-test then diy-models; Astra still reviews results. web-manual is verified by the user selecting GPT-5.6 Luna Max in the ChatGPT UI — no local probe required."' \
      '}'
    if [[ "$has_toml" != yes ]]; then
        # First-run guard: surface the exact copy-pasteable fix so the missing
        # step (init) cannot be skipped. %q shell-escapes the path (handles
        # spaces in the checkout dir); CODEX_HOME is honoured by init too, so
        # the same command provisions the agents even with a custom home.
        local initq; initq="$(printf '%q' "$SCRIPT_DIR/astra-luna.sh")"
        log ""
        log "doctor: missing astra_worker agent - the plugin is installed but NOT initialized."
        log "  expected agent file: $toml"
        log "  consequence: the local-worker transport is unavailable and Luna model/effort probes cannot run."
        log "  fix (copy/paste, then re-run doctor):"
        log "    bash $initq init"
        log ""
        exit 2
    fi
    if [[ "$has_cli" = true && "$cli_cfg" = false ]]; then
        # Fatal for the primary transport: every local-worker dispatch will
        # exit 1 before reaching the model. Name the usual culprit (nested
        # [features.*] tables) with the exact offending lines.
        log ""
        log "doctor: the codex CLI cannot load its configuration - EVERY 'codex exec' dispatch fails (exit 1) before reaching the model."
        log "  codex: $codex_bin"
        log "  error: $cli_err"
        if [[ -f "$cfg" ]]; then
            { grep -nE '^[[:space:]]*\[features\.[^]]+\]' "$cfg" 2>/dev/null || true; } | while IFS= read -r bl; do
                log "  offending line: $bl"
            done
        fi
        log "  fix: edit ~/.codex/config.toml so every [features] value is a boolean - remove or flatten nested [features.*] tables (keep a backup)."
        log "       The desktop app tolerates the nested table; the codex CLI does not. Re-run doctor afterwards."
        log ""
        exit 2
    fi
    exit 0
}

# ---------------------------------------------------------------------------
cmd_init() {
    ensure_dirs
    local changed=0
    local agentsd; agentsd="$(agents_dir)"
    mkdir -p "$agentsd"
    # Install every luna role agent (explorer/worker/tester/reviewer/researcher).
    # Existing files are preserved, never overwritten: this plugin coexists
    # with the old sol-luna plugin and with any hand-edited agent config.
    local src dst count=0
    for src in "$PLUGIN_DIR"/agents/*.toml; do
        [[ -f "$src" ]] || continue
        dst="$agentsd/$(basename "$src")"
        if [[ -f "$dst" ]]; then
            echo "init: existing agent preserved: $dst"
        else
            cp "$src" "$dst"
            chmod 600 "$dst" 2>/dev/null || true
            echo "init: wrote $dst"; changed=1
        fi
        count=$((count+1))
    done
    if (( count == 0 )); then
        die 2 "init: no agent TOMLs found in the plugin agents/ directory"
    fi
    local dstskill; dstskill="$(skill_dst)"
    local skill_existed=false
    [[ -d "$dstskill" ]] && skill_existed=true
    mkdir -p "$dstskill"
    # SKILL.md is plugin-owned: refresh on every init so skill updates
    # propagate (agent TOMLs above stay preserve-if-present).
    cp -f "$PLUGIN_DIR/skills/astra-command-center/SKILL.md" "$dstskill/SKILL.md"
    # Clone the launcher runtime next to SKILL.md. The installed skill copy is
    # invoked with CWD = skill dir, so its documented launcher path
    # ('./scripts/astra-luna.sh') must exist HERE - not two levels up in the
    # plugin checkout (the old copy-if-absent skill install left the copy
    # referencing a launcher that did not exist anywhere).
    local d srcdir dstdir
    for d in scripts agents templates config; do
        srcdir="$PLUGIN_DIR/$d"
        [[ -d "$srcdir" ]] || continue
        dstdir="$dstskill/$d"
        mkdir -p "$dstdir"
        srcdir="$(cd "$srcdir" && pwd)"
        dstdir="$(cd "$dstdir" && pwd)"
        [[ "$srcdir" = "$dstdir" ]] && continue   # init from the clone itself
        cp -f "$srcdir"/* "$dstdir"/ 2>/dev/null || true
    done
    if [[ "$skill_existed" = true ]]; then
        echo "init: skill runtime refreshed -> $dstskill"
    else
        echo "init: installed skill (with launcher runtime) -> $dstskill"; changed=1
    fi
    local amd; amd="$(agents_md)"
    [[ -f "$amd" ]] || : > "$amd"
    if grep -q "$MD_BEGIN" "$amd" 2>/dev/null; then
        log "init: AGENTS.md already carries astra-luna rules"
    else
        if [[ "$(file_bytes "$amd")" -gt 1 ]]; then printf '\n\n' >> "$amd"; fi
        cat "$PLUGIN_DIR/templates/AGENTS.md" >> "$amd"
        echo "init: merged rules into $amd"; changed=1
    fi
    log "init: config.toml is never auto-edited. Apply config/config.toml.example yourself (model = \"$ASTRA_MODEL\", model_reasoning_effort = \"$ASTRA_EFFORT\", [agents] default_subagent_model = \"$LUNA_MODEL\", default_subagent_reasoning_effort = \"$LUNA_EFFORT\")."
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
        local bomless; bomless="$(new_temp "$PACKETS_DIR" "tmp-spec")"
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

    local tmp_payload; tmp_payload="$(new_temp "$PACKETS_DIR" "tmp-payload")"
    {
        printf '# Execution packet (gpt-5.6-luna worker - bounded executor)\n\n## Goal\n%s\n\n' "$goal"
        printf '## Symptom\n%s\n\n' "$symptom"
        printf '## Root cause (from GPT-6 Astra command center)\n%s\n\n' "$rootcause"
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
    chmod 600 "$tmp_payload" 2>/dev/null || true
    mv -f "$tmp_payload" "$PACKETS_DIR/$id.payload.md"
    ( umask 077; cp "$spec" "$PACKETS_DIR/$id.spec.json" ) || die 2 "new-packet: cannot archive spec"
    save_packet "$id" "$(printf '{"state":"new","id":%s,"created_at":%s,"model":"%s","effort":"%s","transport":"","payload_sha256":%s,"payload_bytes":%s,"dispatched_at":"","result_file":"","result_sha256":"","result_bytes":0,"summary_file":"","summary_sha256":""}' \
        "$(qstr "$id")" "$(qstr "$(now_iso)")" "$LUNA_MODEL" "$LUNA_EFFORT" "$(qstr "$psha")" "$(qnum "$size")")"
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
    local id="" transport="" timeout="900"
    while [[ $# -gt 0 ]]; do case "$1" in
        --id) [[ $# -ge 2 ]] || die 1 "dispatch: --id needs a value"; id="$2"; shift 2;;
        --transport) [[ $# -ge 2 ]] || die 1 "dispatch: --transport needs a value"; transport="$2"; shift 2;;
        --timeout) [[ $# -ge 2 ]] || die 1 "dispatch: --timeout needs a value"; timeout="$2"; shift 2;;
        *) die 1 "dispatch: unknown option $1";;
    esac; done
    [[ -n "$id" ]] || die 1 "dispatch: missing --id"
    valid_id "$id" || die 1 "dispatch: invalid id '$id' (allowed: A-Za-z0-9._-)"
    if [[ -z "$transport" ]]; then
        if diy_replaces_luna; then transport="diy-openai"; else transport="local-worker"; fi
    fi
    case "$transport" in
        web-manual|local-worker|chatgpt-web|diy-openai) ;;
        *) die 1 "dispatch: unknown transport '$transport' (web-manual|local-worker|chatgpt-web|diy-openai)";;
    esac
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
    # SINGLE-READ binding: snapshot the payload once into a private 0600 mktemp
    # copy; the SHA-256 below is verified over the snapshot and the snapshot is
    # what actually reaches the worker / staging file. Re-reading the original
    # after the check (the old pattern) left a swap window in which tampered
    # content could be dispatched under a verified hash.
    local snap; snap="$(new_temp "$PACKETS_DIR" "tmp-snap")"
    cp "$mdfile" "$snap"
    local expected actual
    expected="$(json_get "$pfile" payload_sha256)" || die 2 "dispatch: cannot read payload_sha256 for '$id'"
    actual="$(sha256_file "$snap")" || die 2 "dispatch: no sha256 tool (shasum/sha256sum) on PATH"
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
            # ASTRA_LUNA_CODEX_BIN pins the CLI explicitly (pinned / non-PATH
            # installs), twin of the ps1 resolver; otherwise `codex` from PATH.
            # POSIX never routes argv through cmd.exe, so the BatBadBut .exe
            # requirement is a Windows-only concern and does not apply here.
            if [[ -n "${ASTRA_LUNA_CODEX_BIN:-}" ]]; then
                [[ -f "$ASTRA_LUNA_CODEX_BIN" ]] || die 2 "dispatch: local-worker: ASTRA_LUNA_CODEX_BIN not found: $ASTRA_LUNA_CODEX_BIN"
                runner="$ASTRA_LUNA_CODEX_BIN"
            else
                runner="$(command -v codex || true)"
                [[ -n "$runner" ]] || die 2 "dispatch: local-worker: \`codex\` not on PATH; enable Codex CLI or use web-manual"
            fi
            local prompt
            # Current codex-cli (>=0.148 alpha): `exec` takes the prompt as a
            # POSITIONAL arg; the agent's model/effort come from config
            # overrides, NOT the removed `-t <agent>` / `-p <prompt>` flags.
            prompt="$(printf "You are the bounded astra_worker execution agent reporting to GPT-6 Astra. Complete only the assigned subtask in the execution packet (%s). Stay strictly in scope and file boundaries. Do not spawn agents or change architecture. Verify when practical. Return a result with: (1) exact result, (2) files changed/inspected, (3) checks run, (4) verification, (5) remaining risks.\n\n" "$id"; cat "$snap")"
            # stdout is captured as the result; stderr goes to its own file so
            # runner UI noise never pollutes or truncates the captured result.
            # codex exec reads extra input from stdin and blocks until EOF; the
            # shell never closes the inherited stdin, so it would hang forever.
            # Redirect from /dev/null so the prompt (passed as an arg) is the only
            # input. (twin of the ps1 stdin fix)
            local outfile; outfile="$(new_temp "$RESULTS_DIR" "tmp-stdout")"
            local errfile; errfile="$(new_temp "$RESULTS_DIR" "tmp-stderr")"
            # stdout cannot be captured by command-substitution while also
            # polling the live PID, so park it in a file and read it on exit.
            "$runner" exec --skip-git-repo-check --model "$LUNA_MODEL" -c "model_reasoning_effort=\"$LUNA_EFFORT\"" "$prompt" < /dev/null >"$outfile" 2>"$errfile" &
            local wpid=$!
            # Inactivity watchdog, NOT a wall-clock kill. codex exec buffers its
            # stdout (a redirected file stays 0 bytes until the process exits), so
            # output growth cannot signal liveness; the worker's CPU time advances
            # steadily while it generates, so that is what we probe. A healthy
            # 30-minute audit is never cut mid-stream: we only kill when the worker
            # makes NO CPU progress for $timeout consecutive seconds (a real hang).
            # Completion is only the process exiting and returning its data.
            local rc=0
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
            if (( rc != 0 )); then
                if (( rc == 124 )); then
                    echo "dispatch: codex exec stalled (no CPU progress for ${timeout}s)" >&2
                else
                    echo "dispatch: codex exec exited $rc" >&2
                fi
                {
                    cat "$outfile" 2>/dev/null || true
                    printf '%s\n' '--- stderr ---'
                    cat "$errfile" 2>/dev/null || true
                } > "$RESULTS_DIR/$id.run-error.log" 2>/dev/null || true
                chmod 600 "$RESULTS_DIR/$id.run-error.log" 2>/dev/null || true
                journal_log "dispatch-failed" "$id" "transport=local-worker exit=$rc"
                exit 2
            fi
            # memory boundary: a runaway child's stdout is never silently
            # truncated (no silent degradation) -- park it verbatim, refuse.
            # Measured in BYTES on the captured file (never ${#out}, which
            # counts chars under multibyte locales).
            if (( "$(file_bytes "$outfile")" > MAX_JSON_BYTES )); then
                cp "$outfile" "$RESULTS_DIR/$id.result-oversize.log" 2>/dev/null || true
                chmod 600 "$RESULTS_DIR/$id.result-oversize.log" 2>/dev/null || true
                journal_log "dispatch-failed" "$id" "transport=local-worker reason=result-oversize"
                die 2 "dispatch: worker result exceeds $MAX_JSON_BYTES bytes; parked at $RESULTS_DIR/$id.result-oversize.log"
            fi
            # journal twin of the ps1 local-worker success path
            journal_log "dispatch" "$id" "transport=local-worker"
            local res="$RESULTS_DIR/$id.result.md"
            # verbatim stdout bytes (twin of the ps1 Write-TextNoBom capture);
            # 0600 so a worker result that quotes sensitive material stays private
            ( umask 077; cat "$outfile" > "$res" ) || die 2 "dispatch: cannot write result file"
            local rsha rbytes
            rsha="$(sha256_file "$res")" || die 2 "dispatch: no sha256 tool for result hash"
            rbytes="$(file_bytes "$res")"
            set_packet_props "$id" \
                "state=done" "transport=local-worker" "dispatched_at=$(now_iso)" \
                "result_file=$res" "result_sha256=$rsha" "result_bytes:=$rbytes"
            journal_log "run-done" "$id" "transport=local-worker exit=0"
            echo "done (local-worker): $res"
            ;;
        chatgpt-web)
            # ChatGPT Web 自动化 transport（twin of the .sh chatgpt-web）：
            # 浏览器里人工选好 GPT-5.6 Luna (max)，send 负责送 payload 并等待
            # 回复自动写回。绝无静默降级：脚本/解释器缺失、未登录、提交失败、
            # 超时都显式报错。run.py 内部另有壁钟超时（仅作最后防线，正常完成
            # 不受影响）。
            local py_bin=""
            if [[ -n "${ASTRA_LUNA_PYTHON:-}" && -x "$ASTRA_LUNA_PYTHON" ]]; then
                py_bin="$ASTRA_LUNA_PYTHON"
            elif command -v python >/dev/null 2>&1; then
                py_bin="$(command -v python)"
            elif command -v python3 >/dev/null 2>&1; then
                py_bin="$(command -v python3)"
            elif command -v py >/dev/null 2>&1; then
                py_bin="$(command -v py)"
            fi
            [[ -n "$py_bin" ]] || die 2 "dispatch: chatgpt-web: python not found; run init or set ASTRA_LUNA_PYTHON"
            local cw_script="" profile_dir=""
            if [[ -n "${ASTRA_LUNA_CHATGPT_BIN:-}" && -f "$ASTRA_LUNA_CHATGPT_BIN" ]]; then
                cw_script="$ASTRA_LUNA_CHATGPT_BIN"
            elif [[ -f "$PLUGIN_DIR/scripts/chatgpt-web.py" ]]; then
                cw_script="$PLUGIN_DIR/scripts/chatgpt-web.py"
            fi
            [[ -n "$cw_script" ]] || die 2 "dispatch: chatgpt-web: automation script not found (missing install)"
            profile_dir="${ASTRA_LUNA_CHATGPT_PROFILE:-$STATE_DIR/chatgpt-web-profile}"
            local res="$RESULTS_DIR/$id.result.md"
            # wall-clock watchdog: 浏览器驱动进程会主动 sleep 等待页面，CPU
            # 不活动不代表卡死；这里用 --timeout 做总壁钟上限（twin of the
            # ps1 Invoke-WebRun）。错误映射双胞胎于 ps1：2=env 3=未登录
            # 4=提交 5=超时 6=提取。
            local rc=0
            "$py_bin" "$cw_script" send --timeout "$timeout" --profile "$profile_dir" \
                --payload-file "$snap" --result-file "$res" </dev/null >"$RESULTS_DIR/$id.cw-stdout.log" 2>"$RESULTS_DIR/$id.cw-stderr.log" &
            local wp=$!
            local start_s=$(( $(date +%s) ))
            while kill -0 "$wp" 2>/dev/null; do
                local now_s; now_s="$(date +%s)"
                if (( now_s - start_s > timeout )); then
                    kill "$wp" 2>/dev/null || true
                    wait "$wp" 2>/dev/null || true
                    rc=124
                    break
                fi
                sleep 1
            done
            if (( rc == 0 )); then
                wait "$wp" 2>/dev/null || rc=$?
            fi
            if (( rc == 124 )); then
                echo "dispatch: chatgpt-web timed out after ${timeout}s (browser still open?)" >&2
                journal_log "dispatch-failed" "$id" "transport=chatgpt-web reason=timeout exit=124"
                exit 2
            fi
            if (( rc != 0 )); then
                local why
                case "$rc" in
                    2) why='environment error (python/playwright/browser/payload)' ;;
                    3) why='not logged in - run `python chatgpt-web.py login` once' ;;
                    4) why='composer submit failed (page changed?)' ;;
                    5) why="generation timed out after $timeout s" ;;
                    6) why='no assistant reply extracted (page changed?)' ;;
                    *) why="unexpected exit $rc" ;;
                esac
                {
                    cat "$RESULTS_DIR/$id.cw-stderr.log" 2>/dev/null || true
                } >&2
                echo "dispatch: chatgpt-web failed: $why" >&2
                journal_log "dispatch-failed" "$id" "transport=chatgpt-web exit=$rc reason=$why"
                exit 2
            fi
            if [[ ! -f "$res" ]]; then
                echo "dispatch: chatgpt-web exited 0 but wrote no result file: $res" >&2
                journal_log "dispatch-failed" "$id" "transport=chatgpt-web reason=result-missing"
                exit 2
            fi
            local rsha2 rbytes2
            rsha2="$(sha256_file "$res")" || die 2 "dispatch: no sha256 tool for result hash"
            rbytes2="$(file_bytes "$res")"
            set_packet_props "$id" \
                "state=done" "transport=chatgpt-web" "dispatched_at=$(now_iso)" \
                "result_file=$res" "result_sha256=$rsha2" "result_bytes:=$rbytes2"
            journal_log "run-done" "$id" "transport=chatgpt-web exit=0"
            echo "done (chatgpt-web): $res"
            ;;
        web-manual)
            local clip="$RESULTS_DIR/$id.to-web.txt"
            # Stage the VERIFIED snapshot via temp + rename so the final file
            # never appears half-written; mktemp names cannot be pre-planted.
            local clip_part; clip_part="$(new_temp "$RESULTS_DIR" "tmp-to-web")"
            cp "$snap" "$clip_part"
            mv -f "$clip_part" "$clip"
            set_packet_props "$id" "state=done" "transport=$transport" "dispatched_at=$(now_iso)"
            journal_log "dispatch" "$id" "transport=$transport"
            echo "$transport staged: $clip"
            echo "Open chatgpt.com with GPT-5.6 Luna Max selected, paste payload, then save reply to:"
            echo "  $RESULTS_DIR/$id.web-result.md"
            ;;
        diy-openai)
            # astra-Diy: OpenAI-compatible custom worker (replaces gpt-5.6-luna
            # only). Astra still plans/reviews. No silent fallback to luna.
            local f; f="$(diy_config_path)"
            [[ -f "$f" ]] || die 2 "dispatch: diy-openai: DIY config missing at $f (run /astra-Diy or diy-set)"
            diy_ready || die 3 "dispatch: diy-openai: DIY config incomplete (need enabled+base_url+api_key+model)"
            local diy_script py_bin
            diy_script="$(openai_diy_script)"
            [[ -n "$diy_script" ]] || die 2 "dispatch: diy-openai: openai-diy.py not found"
            py_bin="$(find_python_bin)" || die 2 "dispatch: diy-openai: python not found; set ASTRA_LUNA_PYTHON"
            local res="$RESULTS_DIR/$id.result.md"
            local rc=0
            "$py_bin" "$diy_script" run --payload "$snap" --output "$res" --packet-id "$id" \
                </dev/null >"$RESULTS_DIR/$id.diy-stdout.log" 2>"$RESULTS_DIR/$id.diy-stderr.log" || rc=$?
            if (( rc != 0 )); then
                cat "$RESULTS_DIR/$id.diy-stderr.log" >&2 2>/dev/null || true
                journal_log "dispatch-failed" "$id" "transport=diy-openai exit=$rc"
                echo "dispatch: diy-openai exited $rc" >&2
                exit 2
            fi
            [[ -f "$res" ]] || { journal_log "dispatch-failed" "$id" "transport=diy-openai reason=result-missing"; die 2 "dispatch: diy-openai wrote no result file: $res"; }
            (( "$(file_bytes "$res")" <= MAX_JSON_BYTES )) || { journal_log "dispatch-failed" "$id" "transport=diy-openai reason=result-oversize"; die 2 "dispatch: diy-openai result exceeds $MAX_JSON_BYTES bytes"; }
            local rsha rbytes dmodel
            rsha="$(sha256_file "$res")" || die 2 "dispatch: no sha256 tool for diy result"
            rbytes="$(file_bytes "$res")"
            dmodel="$(diy_json_field model || true)"
            set_packet_props "$id" \
                "state=done" "transport=diy-openai" "dispatched_at=$(now_iso)" \
                "result_file=$res" "result_sha256=$rsha" "result_bytes:=$rbytes"
            journal_log "run-done" "$id" "transport=diy-openai exit=0 model=$dmodel"
            echo "done (diy-openai model=${dmodel:-unknown}): $res"
            echo "Astra review required: inspect the result against acceptance before summary."
            ;;
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
# astra-Diy commands (OpenAI-compatible custom worker config)
cmd_diy_set() {
    ensure_dirs
    local -a argv=(set)
    while [[ $# -gt 0 ]]; do case "$1" in
        --base-url) [[ $# -ge 2 ]] || die 1 "diy-set: --base-url needs a value"; argv+=(--base-url "$2"); shift 2;;
        --api-key) [[ $# -ge 2 ]] || die 1 "diy-set: --api-key needs a value"; argv+=(--api-key "$2"); shift 2;;
        --model) [[ $# -ge 2 ]] || die 1 "diy-set: --model needs a value"; argv+=(--model "$2"); shift 2;;
        --enabled) [[ $# -ge 2 ]] || die 1 "diy-set: --enabled needs a value"; argv+=(--enabled "$2"); shift 2;;
        --replace-luna) [[ $# -ge 2 ]] || die 1 "diy-set: --replace-luna needs a value"; argv+=(--replace-luna "$2"); shift 2;;
        --temperature) [[ $# -ge 2 ]] || die 1 "diy-set: --temperature needs a value"; argv+=(--temperature "$2"); shift 2;;
        --timeout-sec) [[ $# -ge 2 ]] || die 1 "diy-set: --timeout-sec needs a value"; argv+=(--timeout-sec "$2"); shift 2;;
        *) die 1 "diy-set: unknown option $1";;
    esac; done
    (( ${#argv[@]} > 1 )) || die 1 "diy-set: provide at least one of --base-url --api-key --model --enabled --replace-luna --temperature --timeout-sec"
    run_openai_diy "${argv[@]}"
    journal_log "diy-set" "-" ""
}
cmd_diy_passthrough() { # cmd_diy_passthrough <subcommand>
    ensure_dirs
    run_openai_diy "$1"
}
cmd_diy_settings() {
    ensure_dirs
    if [[ "$(uname -s 2>/dev/null)" == MINGW* || "$(uname -s 2>/dev/null)" == MSYS* || "$(uname -s 2>/dev/null)" == CYGWIN* ]]; then
        local dlg="$PLUGIN_DIR/scripts/diy-settings.ps1"
        [[ -f "$dlg" ]] || die 2 "diy-settings: scripts/diy-settings.ps1 not found"
        local -a extra=()
        [[ "${1:-}" == "--cli-only" ]] && extra+=(-CliOnly)
        powershell -NoProfile -ExecutionPolicy Bypass -File "$dlg" ${extra[@]+"${extra[@]}"}
        return $?
    fi
    run_openai_diy schema
    echo "On non-Windows hosts use: bash astra-luna.sh diy-set --base-url ... --api-key ... --model ... --enabled true --replace-luna true"
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

    # Copy FIRST (atomic tmp+mv), then hash the final copy: the recorded
    # summary_sha256 always describes the bytes actually stored, even if the
    # source file is modified (or swapped) between the copy and the hash.
    local out="$RESULTS_DIR/$id.summary.md"
    local tmpout; tmpout="$(new_temp "$RESULTS_DIR" "tmp-summary")"
    cp "$text" "$tmpout"
    mv -f "$tmpout" "$out"
    local ssha; ssha="$(sha256_file "$out")" || die 2 "summary: no sha256 tool (shasum/sha256sum) on PATH"
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
            # error (exit 2), never a silent empty row (twin of astra-luna.ps1).
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
    command -v awk >/dev/null 2>&1 || die 2 "astra-luna: awk is required but not on PATH"
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
        diy-set) cmd_diy_set "$@";;
        diy-show) cmd_diy_passthrough show;;
        diy-clear) cmd_diy_passthrough clear;;
        diy-test) cmd_diy_passthrough test;;
        diy-models) cmd_diy_passthrough models;;
        diy-schema) cmd_diy_passthrough schema;;
        diy-settings) cmd_diy_settings "$@";;
        ""|help|-h|--help)
            # sed -n on $0 can no-op when the script is on a mangled PATH
            # entry; always print a real usage line and exit 1 (usage error).
            if [[ -r "$0" ]]; then sed -n '2,30p' "$0" 2>/dev/null || true; fi
            die 1 "usage: astra-luna.sh <doctor|init|new-packet|dispatch|ingest|summary|status|diy-set|diy-show|diy-clear|diy-test|diy-models|diy-schema|diy-settings>";;
        *) die 1 "unknown command: $cmd";;
    esac
}

# Run only when executed directly; sourcing this file must be side-effect free.
# `|| exit $?` preserves the child's exit code under `set -e` (POSIX trap quirk).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@" || exit $?
fi
