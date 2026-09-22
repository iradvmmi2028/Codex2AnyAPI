#!/usr/bin/env bash
# sol-luna integration tests (POSIX: run via bash tests/run-tests.sh)
#
# Behavioural twin of tests/run-tests.ps1. Verifies the sol-luna.sh state
# machine, hash binding, and hard-misuse refusals WITHOUT touching ~/.codex
# or the real config: a disposable CODEX_HOME and a disposable
# SOL_LUNA_STATE_DIR are used (no writes into the plugin checkout).
#
# Coverage:
#   1. doctor on a fresh (no agent) CODEX_HOME -> exit 2
#   2. init writes agent + skill + AGENTS.md rules (never config.toml)
#      and doctor exits 0 afterwards
#   2c. init clones the launcher runtime (scripts/agents/templates/config) into
#       the installed skill so its documented ./scripts/ path actually resolves
#   2d. re-init refreshes a stale installed SKILL.md (plugin-owned, not skipped)
#   3. new-packet: missing spec -> exit 1; valid spec -> packet built
#   4. dispatch: payload hash mismatch -> exit 3
#   5. dispatch: no codex on PATH -> exit 2 (no silent degradation)
#   6. web-manual dispatch -> exit 0; re-dispatch of non-new packet -> exit 1
#   7. ingest before dispatch -> exit 1; happy path ingest -> exit 0
#   8. summary -> exit 0
#   9. status lists the summarized packet -> exit 0
#  10. invalid id (path traversal attempt) -> exit 1
#  11. ingest parent-binding mismatch (hash pre-registered at dispatch) -> exit 3
#  3b. spec document 'null' -> exit 1; absurd / non-ASCII-digit --timeout -> exit 1
#  3c. whitespace-only goal -> exit 1; unknown option / stray arg -> exit 1
#  3e. case-mismatched command name -> exit 1 (byte-exact dispatch)
#  3f. non-JSON garbage spec -> exit 1 (structural brace gate)
#  4f. short alias -t refused -> exit 1 (full-name options only)
#  7c. malformed recorded result_sha256 -> exit 2 (corruption, not mismatch)
# 14. result file over the read cap -> exit 2 (size guard precedes state check)
# 14b. summary text over the read cap -> exit 2 (size guard precedes state check)
# 10e. directory posing as spec/result file -> exit 1 (strict -f guards)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
S="$PLUGIN_DIR/scripts/sol-luna.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sol-luna-test-XXXXXX")"
export CODEX_HOME="$TMP/codex-home"
export SOL_LUNA_STATE_DIR="$TMP/state"
mkdir -p "$CODEX_HOME" "$SOL_LUNA_STATE_DIR"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert() { # assert <desc> <expected-rc> <actual-rc>
    if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected exit $2, got $3"; fi
}
run() { "$S" "$@" >"$TMP/out.txt" 2>"$TMP/err.txt"; echo $?; }

# 1. doctor on empty CODEX_HOME -> 2
rc=$(run doctor); echo "doctor(empty) rc=$rc"
assert "doctor on empty CODEX_HOME" 2 "$rc"
# 1b. first-run guard: the fix must name the init command so the missing step
#     cannot be skipped (regression for the copy-pasteable remedy)
grep -Eq 'sol-luna\.sh.* init' "$TMP/err.txt" && ok || bad "doctor prints the init fix command"

# 2. init installs
rc=$(run init); echo "init rc=$rc"
assert "init" 0 "$rc"
[[ -f "$CODEX_HOME/agents/luna-worker.toml" ]] && ok || bad "init writes agent TOML"
[[ -f "$CODEX_HOME/skills/sol-command-center/SKILL.md" ]] && ok || bad "init installs skill"
[[ ! -f "$CODEX_HOME/config.toml" ]] && ok || bad "init never writes config.toml"

# 2c. init refreshed the installed skill WITH the launcher runtime clone
#     (regression: the old copy-if-absent install copied only SKILL.md, so the
#     installed copy's documented '../../scripts/' path resolved to
#     ~/.codex/scripts/, which is never created - the launcher existed nowhere)
SK="$CODEX_HOME/skills/sol-command-center"
[[ -f "$SK/scripts/sol-luna.sh" ]] && ok || bad "init clones the launcher sh into the installed skill"
[[ -f "$SK/scripts/sol-luna.ps1" ]] && ok || bad "init clones the launcher ps1 into the installed skill"
[[ -f "$SK/config/config.toml.example" ]] && ok || bad "init clones config/ into the installed skill"
[[ -f "$SK/agents/luna-worker.toml" ]] && ok || bad "init clones agents/ into the installed skill"
[[ -f "$SK/templates/AGENTS.md" ]] && ok || bad "init clones templates/ into the installed skill"

# 2d. re-init refreshes (not skips) a stale installed SKILL.md: SKILL.md is
#     plugin-owned state, so a stale installed copy must be overwritten.
printf '# stale installed skill\n' > "$SK/SKILL.md"
rc=$(run init); echo "re-init rc=$rc"
assert "re-init" 0 "$rc"
if grep -q 'stale installed skill' "$SK/SKILL.md"; then
    bad "re-init refreshes a stale installed SKILL.md"
else
    ok
fi

rc=$(run doctor); echo "doctor(after init) rc=$rc"
assert "doctor exits 0 after init" 0 "$rc"
grep -q 'gpt-5.6-luna' "$TMP/out.txt" && ok || bad "doctor reports luna model"

# 3. new-packet requires a spec
rc=$(run new-packet); echo "new-packet(no spec) rc=$rc"
assert "new-packet without spec -> exit 1" 1 "$rc"

# 3b. a bare JSON 'null' document falls through to the goal check -> exit 1
#     (twin of the ps1 null-spec guard)
# 10e. empty-state packet: state-machine commands must refuse (exit 2)
#      rather than fall through checks on "" (twin of the ps1 refusal)
# 10f. malformed payload_sha256 in execution.json: dispatch refuses (exit 2)
#      instead of an empty/empty hash compare silently passing
# 10g. spec over the read cap: exit 1 before any unbounded parse
rc=$(run new-packet --spec "$TMP/null-spec.json"); echo "new-packet(null spec) rc=$rc"
assert "spec document 'null' -> exit 1" 1 "$rc"

# 3c. whitespace-only goal counts as empty (twin of the ps1 .Trim() check)
printf '{"goal":"   "}' > "$TMP/ws-spec.json"
rc=$(run new-packet --spec "$TMP/ws-spec.json"); echo "new-packet whitespace-goal rc=$rc"
assert "whitespace-only goal -> exit 1" 1 "$rc"

# 3d. unknown option / stray positional refused (native here; parity with the
#     new ps1 parse-time whitelist)
rc=$(run status --bogus); echo "status unknown-option rc=$rc"
assert "unknown option -> exit 1" 1 "$rc"
rc=$(run status extra); echo "status stray-positional rc=$rc"
assert "stray positional -> exit 1" 1 "$rc"

# 3e. command names are byte-exact (twin of the ps1 -CaseSensitive switch)
rc=$(run Doctor); echo "case-mismatched command rc=$rc"
assert "case-mismatched command -> exit 1" 1 "$rc"

# 3f. non-JSON garbage is refused by the structural brace gate (exit-code
#     twin of the ps1 ConvertFrom-Json refusal) instead of sliding into a
#     misleading "spec.goal required"
printf 'this is not json at all' > "$TMP/garbage-spec.json"
rc=$(run new-packet --spec "$TMP/garbage-spec.json"); echo "new-packet garbage-spec rc=$rc"
assert "non-JSON spec garbage -> exit 1" 1 "$rc"

SPEC="$TMP/spec.json"
cat > "$SPEC" <<'JSON'
{ "goal":"Fix http reset","symptom":["502 on idle"],
  "root_cause":["pool keep-alive too long"],"scope":["src/db"],
  "inputs":["a"],"acceptance":["test passes"],"constraints":["no new deps"] }
JSON
rc=$(run new-packet --spec "$SPEC"); echo "new-packet rc=$rc"
assert "new-packet succeeds" 0 "$rc"
ID="$(sed -n 's/^created: //p' "$TMP/out.txt")"
[[ -n "$ID" ]] && ok || bad "new-packet emits an id"

# 4. tamper payload -> dispatch refuses with 3
PACKETS="$SOL_LUNA_STATE_DIR/packets"
printf '%s\n' '// tampered' >> "$PACKETS/$ID.payload.md"
rc=$(run dispatch --id "$ID" --transport local-worker); echo "dispatch tampered rc=$rc"
assert "dispatch on tampered payload -> exit 3" 3 "$rc"
# 4b. --timeout alone must not collide with any other flag slot (twin of the
#     ps1 regression probe); the hash check fires first -> exit 3, no codex spawn.
rc=$(run dispatch --id "$ID" --timeout 900); echo "dispatch timeout-only rc=$rc"
assert "dispatch with --timeout only still enforces hash -> exit 3" 3 "$rc"
# 4c. negative timeout is a usage error (exit 1); a leading-zero value parses
#     base-10 and flows into the (still tampered) hash check -> exit 3.
rc=$(run dispatch --id "$ID" --timeout -1); echo "dispatch negative-timeout rc=$rc"
assert "dispatch with --timeout -1 -> exit 1" 1 "$rc"
rc=$(run dispatch --id "$ID" --timeout 08); echo "dispatch leading-zero timeout rc=$rc"
assert "dispatch with --timeout 08 still enforces hash -> exit 3" 3 "$rc"
# 4d. absurd length is bounded before the base-10 arithmetic; non-ASCII digits
#     are refused by the '[!0-9]' byte class (twin of the ps1 ASCII-only guard)
rc=$(run dispatch --id "$ID" --timeout 99999999999); echo "dispatch huge-timeout rc=$rc"
assert "dispatch with absurd --timeout -> exit 1 (bounded)" 1 "$rc"
rc=$(run dispatch --id "$ID" --timeout '٥'); echo "dispatch unicode-digit timeout rc=$rc"
assert "dispatch with non-ASCII digit --timeout -> exit 1" 1 "$rc"
# 4e. a misspelled flag dies at the case whitelist instead of silently
#     dropping the timeout guard (parity with the ps1 parse-time whitelist)
rc=$(run dispatch --id "$ID" --TimeOutSec 5); echo "dispatch misspelled-flag rc=$rc"
assert "misspelled --TimeOutSec -> exit 1" 1 "$rc"
# 4f. short aliases are gone (twin of the ps1 full-name-only parser): '-t'
#     is undocumented on both sides, so it dies like any unknown option
rc=$(run dispatch --id "$ID" -t web-manual); echo "dispatch short-alias rc=$rc"
assert "short alias -t refused -> exit 1" 1 "$rc"
# restore exact bytes: drop the appended line again
awk '!/^\/\/ tampered$/' "$PACKETS/$ID.payload.md" > "$PACKETS/$ID.payload.md.x" \
    && mv -f "$PACKETS/$ID.payload.md.x" "$PACKETS/$ID.payload.md"

# 5. dispatch without codex on PATH -> 2 (no silent degrade)
PATH_SAVE="$PATH"
PATH="/usr/bin:/bin"
rc=$(run dispatch --id "$ID" --transport local-worker); echo "dispatch no-codex rc=$rc"
assert "dispatch without codex binary -> exit 2" 2 "$rc"
export PATH="$PATH_SAVE"

# 5b. macOS tier: gtimeout(1) satisfies the timeout requirement, so the next
#     refusal must be the missing codex binary (not the timeout check).
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexec "${@:2}"\n' > "$TMP/bin/gtimeout"
chmod +x "$TMP/bin/gtimeout"
PATH="$TMP/bin:/usr/bin:/bin"
rc=$(run dispatch --id "$ID" --transport local-worker); echo "dispatch gtimeout-no-codex rc=$rc"
export PATH="$PATH_SAVE"
assert "gtimeout tier passes timeout check -> dies on missing codex (exit 2)" 2 "$rc"
grep -q 'codex' "$TMP/err.txt" && ok || bad "gtimeout error should mention codex"

# 5c. INACTIVITY WATCHDOG, not a wall-clock kill (regression for the bug where
#     a long streaming audit was killed mid-run purely on wall-clock).
#     codex exec buffers its stdout (0 bytes until exit), so the worker is
#     "alive" iff its CPU time keeps advancing. A worker that still burns CPU
#     well past --timeout must NOT be killed; a worker that goes silent (sleep)
#     for --timeout consecutive seconds must be killed as a genuine stall.
mkdir -p "$TMP/bin"
# (a) CPU-burning fake codex that runs ~6s (far longer than --timeout 2)
printf '#!/usr/bin/env bash\nend=$(( $(date +%s) + 6 ))\nwhile (( $(date +%s) < end )); do :; done\necho WATCHDOG-ALIVE\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
rc=$(run new-packet --spec "$SPEC")   # fresh packet (state=new)
IDW="$(sed -n 's/^created: //p' "$TMP/out.txt")"
[[ -n "$IDW" ]] && ok || bad "watchdog test emits a fresh id"
PATH="$TMP/bin:$PATH_SAVE"
rc=$(run dispatch --id "$IDW" --transport local-worker --timeout 2); echo "dispatch watchdog-alive rc=$rc"
export PATH="$PATH_SAVE"
assert "watchdog lets a CPU-active worker run past --timeout (rc 0, not killed)" 0 "$rc"
# the worker's real output lands in the packet result file, not dispatch stdout
if grep -q 'WATCHDOG-ALIVE' "$SOL_LUNA_STATE_DIR/results/$IDW.result.md" 2>/dev/null; then ok; else bad "CPU-active worker result not captured"; fi
# (b) stalled fake codex: sleeps (zero CPU) for 60s, --timeout 2 -> killed as a stall
printf '#!/usr/bin/env bash\nsleep 60 2>/dev/null || true\necho SHOULD-NOT-APPEAR\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
rc=$(run new-packet --spec "$SPEC")
IDW2="$(sed -n 's/^created: //p' "$TMP/out.txt")"
PATH="$TMP/bin:$PATH_SAVE"
rc=$(run dispatch --id "$IDW2" --transport local-worker --timeout 2); echo "dispatch watchdog-stall rc=$rc"
export PATH="$PATH_SAVE"
assert "watchdog kills a CPU-silent worker after --timeout (exit 2)" 2 "$rc"
grep -q 'stalled' "$TMP/err.txt" && ok || bad "stalled worker error mentions 'stalled'"
grep -q 'SHOULD-NOT-APPEAR' "$TMP/out.txt" && bad "stalled worker result should not be captured" || ok

# 6. web-manual dispatch, then re-dispatch refusal
rc=$(run dispatch --id "$ID" --transport web-manual); echo "dispatch web-manual rc=$rc"
assert "web-manual dispatch succeeds" 0 "$rc"
rc=$(run dispatch --id "$ID" --transport web-manual); echo "re-dispatch rc=$rc"
assert "second dispatch of dispatched packet -> exit 1" 1 "$rc"

# 7. ingest: out-of-order refusal on a fresh (state=new) packet, then happy path
rc=$(run new-packet --spec "$SPEC")
ID2="$(sed -n 's/^created: //p' "$TMP/out.txt")"
[[ -n "$ID2" ]] && ok || bad "second new-packet emits an id"
printf 'nope' > "$TMP/res.md"
rc=$(run ingest --id "$ID2" --result "$TMP/res.md"); echo "ingest(new state) rc=$rc"
assert "ingest before dispatch -> exit 1" 1 "$rc"
# 7b. parent binding: simulate the local-worker pre-registration by writing
#     the correct result hash into the packet, then prove a foreign file is
#     refused (exit 3) and the matching file ingests cleanly.
sha_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else sha256sum "$1" | awk '{print $1}'; fi
}
printf 'applied the patch; tests pass' > "$TMP/result.md"
RS="$(sha_of "$TMP/result.md")"
sed "s/\"result_sha256\":\"\"/\"result_sha256\":\"$RS\"/" \
    "$PACKETS/$ID.execution.json" > "$PACKETS/$ID.execution.json.x" \
    && mv -f "$PACKETS/$ID.execution.json.x" "$PACKETS/$ID.execution.json"
printf 'TAMPERED RESULT' > "$TMP/result-bad.md"
rc=$(run ingest --id "$ID" --result "$TMP/result-bad.md"); echo "ingest tampered rc=$rc"
assert "ingest with mismatched result hash -> exit 3" 3 "$rc"
# 7c. a MALFORMED recorded hash is corruption (exit 2), not a mismatch (exit 3)
sed "s/\"result_sha256\":\"$RS\"/\"result_sha256\":\"not-a-hash\"/" \
    "$PACKETS/$ID.execution.json" > "$PACKETS/$ID.execution.json.x" \
    && mv -f "$PACKETS/$ID.execution.json.x" "$PACKETS/$ID.execution.json"
rc=$(run ingest --id "$ID" --result "$TMP/result.md"); echo "ingest malformed-recorded-sha rc=$rc"
assert "ingest with malformed recorded result_sha256 -> exit 2" 2 "$rc"
sed "s/\"result_sha256\":\"not-a-hash\"/\"result_sha256\":\"$RS\"/" \
    "$PACKETS/$ID.execution.json" > "$PACKETS/$ID.execution.json.x" \
    && mv -f "$PACKETS/$ID.execution.json.x" "$PACKETS/$ID.execution.json"
rc=$(run ingest --id "$ID" --result "$TMP/result.md"); echo "ingest rc=$rc"
assert "ingest succeeds" 0 "$rc"

# 14. result file over the read cap is refused before hashing/state (exit 2);
#     twin of the ps1 MAX_JSON_BYTES ingest guard (1 MB + 1 byte)
head -c 1048577 /dev/zero | tr '\0' 'x' > "$TMP/big-result.md"
rc=$(run ingest --id "$ID" --result "$TMP/big-result.md"); echo "ingest oversize-result rc=$rc"
assert "ingest with oversize result -> exit 2" 2 "$rc"

# 14b. summary text over the read cap: refused before hashing (exit 2);
#      twin of the ps1 MAX_JSON_BYTES summary guard (1 MB + 1 byte)
head -c 1048577 /dev/zero | tr '\0' 'x' > "$TMP/big-summary.md"
rc=$(run summary --id "$ID" --text-file "$TMP/big-summary.md"); echo "summary oversize-text rc=$rc"
assert "summary with oversize text -> exit 2" 2 "$rc"

# 8. summary
printf 'done' > "$TMP/summary.md"
rc=$(run summary --id "$ID" --text-file "$TMP/summary.md"); echo "summary rc=$rc"
assert "summary succeeds" 0 "$rc"

# 9. status shows summarized
rc=$(run status); echo "status rc=$rc"
assert "status exit" 0 "$rc"
grep -q 'summarized' "$TMP/out.txt" && ok || bad "status reflects summarized state"

# 10. invalid id refused (path traversal attempt)
rc=$(run status --id "../../etc/passwd"); echo "status bad-id rc=$rc"
assert "status with traversal id -> exit 1" 1 "$rc"
rc=$(run ingest --id "x/y" --result "$TMP/result.md"); echo "ingest bad-id rc=$rc"
assert "ingest with traversal id -> exit 1" 1 "$rc"

# 10h. over-long id (61 chars) refused (twin of the ps1 60-char cap)
LONGID="$(printf 'a%.0s' $(seq 1 61))"
rc=$(run status --id "$LONGID"); echo "status long-id rc=$rc"
assert "status with over-long id -> exit 1" 1 "$rc"
rc=$(run dispatch --id "$LONGID"); echo "dispatch long-id rc=$rc"
assert "dispatch with over-long id -> exit 1" 1 "$rc"

# 10b. corrupt packet: explicit status -> exit 2 (loud), bulk listing -> 0 (skip)
printf '{ this is not json' > "$PACKETS/corrupttest1.execution.json"
rc=$(run status --id corrupttest1); echo "status corrupt rc=$rc"
assert "explicit status on corrupt packet -> exit 2" 2 "$rc"
rc=$(run status); echo "bulk status rc=$rc"
assert "bulk status skips corrupt packet" 0 "$rc"
rm -f "$PACKETS/corrupttest1.execution.json"

# 10e. execution.json with an EMPTY state value must be refused on the
#      state-machine path (exit 2, loud), never fall through checks
printf '{"state":"","id":"emptytest"}' > "$PACKETS/emptytest.execution.json"
rc=$(run dispatch --id emptytest); echo "dispatch empty-state rc=$rc"
assert "dispatch on empty-state packet -> exit 2" 2 "$rc"
rc=$(run ingest --id emptytest --result "$TMP/result.md"); echo "ingest empty-state rc=$rc"
assert "ingest on empty-state packet -> exit 2" 2 "$rc"
rm -f "$PACKETS/emptytest.execution.json"

# 10f. malformed (too-short) payload_sha256 must never pass a ''==''-style
#      comparison: dispatch refuses with exit 2
printf '{"state":"new","id":"badsha","payload_sha256":"abc123"}' > "$PACKETS/badsha.execution.json"
printf 'payload' > "$PACKETS/badsha.payload.md"
rc=$(run dispatch --id badsha); echo "dispatch malformed-sha rc=$rc"
assert "dispatch with malformed payload_sha256 -> exit 2" 2 "$rc"
rm -f "$PACKETS/badsha.execution.json" "$PACKETS/badsha.payload.md"

# 10g. spec larger than the read cap is refused before parsing (exit 1)
head -c 1100000 /dev/zero | tr '\0' 'x' > "$TMP/huge.json"
rc=$(run new-packet --spec "$TMP/huge.json"); echo "new-packet huge-spec rc=$rc"
assert "spec over read cap -> exit 1" 1 "$rc"

# 10c. corrupt execution.json on the state-machine path -> exit 2
printf '{ this is not json' > "$PACKETS/corrupttest2.execution.json"
rc=$(run dispatch --id corrupttest2); echo "dispatch corrupt rc=$rc"
assert "dispatch on corrupt packet json -> exit 2" 2 "$rc"
rm -f "$PACKETS/corrupttest2.execution.json"

# 10d. payload over the 12000-byte hard limit -> exit 2 (no truncation, no pass)
BIGGOAL="$(head -c 13000 /dev/zero | tr '\0' 'x')"
printf '{"goal":"%s"}' "$BIGGOAL" > "$TMP/big-spec.json"
rc=$(run new-packet --spec "$TMP/big-spec.json"); echo "new-packet oversize rc=$rc"
assert "oversize payload -> exit 2" 2 "$rc"

# 10e. a directory posing as an input file is a clean usage error (exit 1),
#      not a raw tool failure (twin of the ps1 -PathType Leaf guards)
rc=$(run ingest --id "$ID" --result "$PACKETS"); echo "ingest dir-as-result rc=$rc"
assert "ingest with directory as result -> exit 1" 1 "$rc"
rc=$(run new-packet --spec "$PACKETS"); echo "new-packet spec-dir rc=$rc"
assert "new-packet with directory as spec -> exit 1" 1 "$rc"

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
rm -rf "$TMP"
if (( FAIL > 0 )); then exit 1; fi
exit 0
