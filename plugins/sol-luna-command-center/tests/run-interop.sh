#!/usr/bin/env bash
# sol-luna cross-platform interop test (run via bash tests/run-interop.sh)
#
# Proves both implementations share one state directory safely: the
# execution.json that sol-luna.ps1 writes is readable by sol-luna.sh and vice
# versa (flat JSON, identical canonical key set, same SHA-256 binding). This
# is the contract that makes SOL_LUNA_STATE_DIR portable across a
# Windows / POSIX (WSL, macOS) boundary.
#
# Scenarios (each in a disposable SOL_LUNA_STATE_DIR + CODEX_HOME):
#   A. ps1 new-packet -> sh status -> sh dispatch(web-manual) -> sh ingest
#      -> sh summary  -> ps1 status (must report summarized)
#   B. ps1 new-packet -> ps1 dispatch(web-manual) -> sh status -> sh ingest
#      -> ps1 status
#   C. sh  new-packet -> ps1 status -> ps1 dispatch(web-manual) -> sh status
#      -> sh ingest   -> ps1 status
#   + keyset check: after every dispatch the packet carries the full flat
#     canonical key set and no nested "result" object (both writers).
#
# Needs powershell on PATH (Windows PowerShell 5.1+). On a pure POSIX host
# without it the script skips; the .sh side alone is covered by run-tests.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
SH="$PLUGIN_DIR/scripts/sol-luna.sh"
PS1S="$PLUGIN_DIR/scripts/sol-luna.ps1"

PS_BIN=""
if command -v powershell >/dev/null 2>&1; then PS_BIN=powershell
elif command -v powershell.exe >/dev/null 2>&1; then PS_BIN=powershell.exe
fi
if [[ -z "$PS_BIN" ]]; then
    echo "SKIP: powershell not found; ps1<->sh interop needs Windows (run-tests.sh still covers the sh side)."
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sol-luna-interop-XXXXXX")"
WINTMP="$TMP"
if command -v cygpath >/dev/null 2>&1; then WINTMP="$(cygpath -m "$TMP")"; fi
# Windows-form path so both implementations accept it as an env override.
export SOL_LUNA_STATE_DIR="$WINTMP/state"
export CODEX_HOME="$WINTMP/codex-home"
mkdir -p "$SOL_LUNA_STATE_DIR" "$CODEX_HOME"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert() { # assert <desc> <expected-rc> <actual-rc>
    if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected exit $2, got $3"; fi
}
sh_run() { "$SH" "$@" >"$TMP/out.txt" 2>"$TMP/err.txt"; echo $?; }
ps_run() { "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PS1S" "$@" >"$TMP/out.txt" 2>"$TMP/err.txt"; echo $?; }
last_id() { tr -d '\r' < "$TMP/out.txt" | sed -n 's/^created: //p'; }

CANON_KEYS='state id created_at model effort transport payload_sha256 payload_bytes dispatched_at result_file result_sha256 result_bytes summary_file summary_sha256'
keys_ok() { # flat canonical keyset, no nested "result" object
    local f="$1" k
    if [[ ! -f "$f" ]]; then bad "keyset: $f missing"; return 1; fi
    for k in $CANON_KEYS; do
        grep -q "\"$k\":" "$f" || { bad "keyset: '$k' missing in $f"; return 1; }
    done
    if grep -q '"result":{' "$f"; then bad "keyset: nested result object in $f"; return 1; fi
    return 0
}

SPEC="$TMP/spec.json"
cat > "$SPEC" <<'JSON'
{ "goal":"Interop round-trip","symptom":["criss-cross state dir"],
  "root_cause":["two writers one format"],"scope":["state"],
  "inputs":[],"acceptance":["both readers agree"],"constraints":[] }
JSON

# sandbox installs (agent + skill for web-manual staging in both impls)
rc=$(sh_run init);  echo "sh init rc=$rc";  assert "sh init" 0 "$rc"
rc=$(ps_run init);  echo "ps1 init rc=$rc"; assert "ps1 init" 0 "$rc"

echo "== A: ps1 new -> sh status -> sh dispatch -> sh ingest -> sh summary -> ps1 status =="
rc=$(ps_run new-packet -SpecFile "$SPEC"); echo "A ps1 new-packet rc=$rc"
assert "A ps1 new-packet" 0 "$rc"
ID_A="$(last_id)"
if [[ -n "$ID_A" ]]; then ok; else bad "A: id not parsed from ps1 output"; fi
rc=$(sh_run status --id "$ID_A"); echo "A sh status(new) rc=$rc"
assert "A sh reads ps1-written json (status)" 0 "$rc"
rc=$(sh_run dispatch --id "$ID_A" --transport web-manual); echo "A sh dispatch rc=$rc"
assert "A sh dispatch of ps1-created packet" 0 "$rc"
if keys_ok "$SOL_LUNA_STATE_DIR/packets/$ID_A.execution.json"; then ok; fi
printf 'interop result A' > "$TMP/resA.md"
rc=$(sh_run ingest --id "$ID_A" --result "$TMP/resA.md"); echo "A sh ingest rc=$rc"
assert "A sh ingest" 0 "$rc"
printf 'interop summary A' > "$TMP/sumA.md"
rc=$(sh_run summary --id "$ID_A" --text-file "$TMP/sumA.md"); echo "A sh summary rc=$rc"
assert "A sh summary" 0 "$rc"
rc=$(ps_run status -Id "$ID_A"); echo "A ps1 status rc=$rc"
assert "A ps1 status on sh-written json" 0 "$rc"
tr -d '\r' < "$TMP/out.txt" | grep -q 'summarized' && ok || bad "A ps1 status shows summarized"

echo "== B: ps1 new -> ps1 dispatch -> sh status -> sh ingest -> ps1 status =="
rc=$(ps_run new-packet -SpecFile "$SPEC"); echo "B ps1 new-packet rc=$rc"
assert "B ps1 new-packet" 0 "$rc"
ID_B="$(last_id)"
if [[ -n "$ID_B" ]]; then ok; else bad "B: id not parsed"; fi
rc=$(ps_run dispatch -Id "$ID_B" -Transport web-manual); echo "B ps1 dispatch rc=$rc"
assert "B ps1 dispatch" 0 "$rc"
if keys_ok "$SOL_LUNA_STATE_DIR/packets/$ID_B.execution.json"; then ok; fi
rc=$(sh_run status --id "$ID_B"); echo "B sh status rc=$rc"
assert "B sh reads ps1 multiline json" 0 "$rc"
printf 'interop result B' > "$TMP/resB.md"
rc=$(sh_run ingest --id "$ID_B" --result "$TMP/resB.md"); echo "B sh ingest rc=$rc"
assert "B sh ingest" 0 "$rc"
rc=$(ps_run status -Id "$ID_B"); echo "B ps1 status rc=$rc"
assert "B ps1 status on sh-written json" 0 "$rc"

echo "== C: sh new -> ps1 status -> ps1 dispatch -> sh status -> sh ingest -> ps1 status =="
rc=$(sh_run new-packet --spec "$SPEC"); echo "C sh new-packet rc=$rc"
assert "C sh new-packet" 0 "$rc"
ID_C="$(last_id)"
if [[ -n "$ID_C" ]]; then ok; else bad "C: id not parsed"; fi
rc=$(ps_run status -Id "$ID_C"); echo "C ps1 status rc=$rc"
assert "C ps1 reads sh-written json" 0 "$rc"
rc=$(ps_run dispatch -Id "$ID_C" -Transport web-manual); echo "C ps1 dispatch rc=$rc"
assert "C ps1 dispatch cross-checks sh payload hash" 0 "$rc"
if keys_ok "$SOL_LUNA_STATE_DIR/packets/$ID_C.execution.json"; then ok; fi
rc=$(sh_run status --id "$ID_C"); echo "C sh status rc=$rc"
assert "C sh status on ps1-rewritten json" 0 "$rc"
printf 'interop result C' > "$TMP/resC.md"
rc=$(sh_run ingest --id "$ID_C" --result "$TMP/resC.md"); echo "C sh ingest rc=$rc"
assert "C sh ingest" 0 "$rc"
rc=$(ps_run status -Id "$ID_C"); echo "C ps1 status rc=$rc"
assert "C ps1 status" 0 "$rc"

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
rm -rf "$TMP"
if (( FAIL > 0 )); then exit 1; fi
exit 0
