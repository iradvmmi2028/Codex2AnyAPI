# sol-luna integration tests (Windows: run via powershell -File tests\run-tests.ps1)
#
# Verifies the sol-luna.ps1 state machine, hash binding, and hard-misuse refusals
# WITHOUT touching ~/.codex or the real config. A disposable CODEX_HOME is used.
#
# Coverage:
#   1. doctor on a fresh (no agent) CODEX_HOME -> exit 2
#   2. init writes agent + skill + AGENTS.md rules (never config.toml)
#   3. new-packet: missing spec/goal -> exit 1; valid spec -> packet built
#   4. dispatch: payload hash mismatch -> exit 3
#   5. dispatch: non-'new' state rejected -> exit 1
#   6. web-manual dispatch -> exit 0; re-dispatch of non-new packet -> exit 1
#   7. ingest before dispatch -> exit 1; happy path ingest -> exit 0
#   7b. ingest parent-binding mismatch (hash pre-registered at dispatch) -> exit 3
#   8. summary -> exit 0
#   9. status lists the summarized packet -> exit 0
#  10. invalid id (path traversal attempt) -> exit 1 on status/ingest/dispatch
#  11. journal.jsonl stays BOM-free (byte-compatible with the POSIX twin)
#  3b. spec document 'null' -> exit 1 (clean usage error, no StrictMode crash)
#  3c. unknown option / stray positional -> exit 1 (parse-time whitelist)
#  3d. whitespace-only goal -> exit 1
#  3e. case-mismatched command name -> exit 1 (case-sensitive dispatch)
#  3f. non-JSON garbage spec -> exit 1 (ConvertFrom-Json refusal)
#  4f. absurd -TimeoutSec bounded -> exit 1; non-ASCII digits refused -> exit 1
#  4h. misspelled -TimeOutSec refused at parse time (timeout guard survives)
#  4i. short alias -t refused -> exit 1 (full-name options only)
#  7c. malformed recorded result_sha256 -> exit 2 (corruption, not mismatch)
# 14b. summary text over the read cap -> exit 2 (before state check)
#  13. over-long id (>60 chars) -> exit 1 on every id-bearing command
#  14. result file over the read cap -> ingest refuses (exit 2)
# 10e. directory posing as spec/result file -> exit 1 (-PathType Leaf guards)
#  5. dispatch with codex off PATH (PATH sandboxed, so the result is the same on
#     a machine that has a real codex.exe) -> exit 2, never a silent degrade
#  5b. dispatch with a .cmd `codex` shim on PATH -> the native codex.exe behind
#      it is resolved and executed (BatBadBut guard satisfied, not bypassed)
#  5c. dispatch with a shim that has NO native codex.exe behind it -> exit 2
#  5d. SOL_LUNA_CODEX_BIN pins the CLI for dispatch (a native .exe, and a
#      pinned shim is resolved rather than executed)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path          # ...\tests
$Plugin = Split-Path -Parent $Root                                 # plugin root
$Script = Join-Path $Plugin 'scripts\sol-luna.ps1'
$tmp = Join-Path $env:TEMP ("sol-luna-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Use a sandboxed Codex home AND a sandboxed state dir so nothing touches the
# real user profile or the plugin checkout.
$env:CODEX_HOME = Join-Path $tmp '.codex-home'
$env:SOL_LUNA_STATE_DIR = Join-Path $tmp 'state'
New-Item -ItemType Directory -Force -Path $env:CODEX_HOME, $env:SOL_LUNA_STATE_DIR | Out-Null

$pass = 0; $fail = 0
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# Byte-exact UTF-8 (no BOM) write helper: Set-Content would re-encode (ASCII in
# PS5.1, BOM'd UTF-8 elsewhere) and break the payload hash round-trip.
function Write-Exact([string]$path,[string]$text){ [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom) }
function Assert-True([bool]$c,[string]$msg){ if($c){$script:pass++} else {$script:fail++; Write-Host "  [FAIL] $msg" -ForegroundColor Red} }
function Run([string[]]$ArgList,[switch]$allowErr) {
    # Build a command line handed verbatim to powershell.exe via Start-Process.
    # Start-Process -ArgumentList joins with spaces and strips quoting, so every
    # element that may contain a space (paths) or that is a flag (-Id) must be
    # wrapped in embedded double quotes to survive the round-trip.
    $parts = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $Script + '"'))
    foreach ($a in $ArgList) {
        if ($a -match '\s' -or $a -match '^-') { $parts += '"' + $a.Replace('"','\"') + '"' }
        else                                  { $parts += $a }
    }
    $argLine = $parts -join ' '
    $outFile = Join-Path $tmp 'out.txt'
    $errFile = Join-Path $tmp 'err.txt'
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $o = Get-Content $outFile -Raw
    $e = Get-Content $errFile -Raw
    return [pscustomobject]@{ Exit=$p.ExitCode; Out=$o; Err=$e }
}

# 1. doctor on empty config -> exit 2
$r = Run @('doctor')
Write-Host "doctor(empty) exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "doctor on empty CODEX_HOME should exit 2"
# 1b. first-run guard: the fix must name the init command so the missing step
#     cannot be skipped (regression for the copy-pasteable remedy)
Assert-True ($r.Err -match 'sol-luna\.ps1.* init') "doctor prints the init fix command"

# 2. init installs
$r = Run @('init')
Write-Host "init exit=$($r.Exit)"
Assert-True ($r.Exit -eq 0) "init should succeed"
Assert-True (Test-Path (Join-Path $env:CODEX_HOME 'agents\luna-worker.toml')) "init writes agent TOML"
Assert-True (Test-Path (Join-Path $env:CODEX_HOME 'skills\sol-command-center\SKILL.md')) "init installs skill"
Assert-True (-not (Test-Path (Join-Path $env:CODEX_HOME 'config.toml'))) "init never writes config.toml"

# 2c. init refreshes the installed skill WITH the launcher runtime clone
#     (regression: the old copy-if-absent install copied only SKILL.md, so the
#     installed copy's documented '..\..\scripts\' path resolved to
#     ~/.codex/scripts/, which is never created - the launcher existed nowhere)
$skillHome = Join-Path $env:CODEX_HOME 'skills\sol-command-center'
Assert-True (Test-Path (Join-Path $skillHome 'scripts\sol-luna.ps1')) "init clones the launcher ps1 into the installed skill"
Assert-True (Test-Path (Join-Path $skillHome 'scripts\sol-luna.sh')) "init clones the launcher sh into the installed skill"
Assert-True (Test-Path (Join-Path $skillHome 'config\config.toml.example')) "init clones config/ into the installed skill"
Assert-True (Test-Path (Join-Path $skillHome 'agents\luna-worker.toml')) "init clones agents/ into the installed skill"
Assert-True (Test-Path (Join-Path $skillHome 'templates\AGENTS.md')) "init clones templates/ into the installed skill"

# 2d. re-init refreshes (not skips) the installed skill: SKILL.md is
#     plugin-owned state, so a stale installed copy must be overwritten.
$staleBody = "# stale installed skill`r`n"
[System.IO.File]::WriteAllText((Join-Path $skillHome 'SKILL.md'), $staleBody, $Utf8NoBom)
$r = Run @('init')
Assert-True ($r.Exit -eq 0) "re-init should succeed"
$refreshed = [System.IO.File]::ReadAllText((Join-Path $skillHome 'SKILL.md'))
Assert-True ($refreshed -ne $staleBody) "re-init refreshes a stale installed SKILL.md"
Assert-True ($r.Out -match 'skill runtime refreshed') "re-init reports the skill runtime refresh"

# doctor now sees the agent -> exits 0
$r = Run @('doctor')
Assert-True ($r.Exit -eq 0) "doctor exits 0 after init"
Assert-True ($r.Out -match 'gpt-5.6-luna') "doctor reports luna model"

# 3. new-packet requires a spec
$r = Run @('new-packet')
Assert-True ($r.Exit -eq 1) "new-packet without spec -> exit 1"

# 3b. a bare JSON 'null' document must be a clean usage error, not a
#     StrictMode null-reference crash (twin: .sh dies 1 "spec.goal required")
$nullSpec = Join-Path $tmp 'null-spec.json'
Write-Exact $nullSpec 'null'
$r = Run @('new-packet','-SpecFile',$nullSpec)
Write-Host "new-packet null-spec exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "spec document 'null' -> exit 1 (invalid spec JSON)"

# 3c. unknown options / stray positionals are refused at parse time, never
#     silently dropped (twin of the .sh per-command case whitelist)
$r = Run @('status','-Bogus')
Write-Host "status unknown-option exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "unknown option -> exit 1"
$r = Run @('status','extra')
Write-Host "status stray-positional exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "stray positional -> exit 1"

# 3e. command names are case-sensitive (twin of the .sh byte-exact dispatch)
$r = Run @('Doctor')
Write-Host "case-mismatched command exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "case-mismatched command -> exit 1"

# 3d. whitespace-only goal is empty -> exit 1 (twin of the .sh guard)
$wsSpec = Join-Path $tmp 'ws-spec.json'
Write-Exact $wsSpec '{"goal":"   "}'
$r = Run @('new-packet','-SpecFile',$wsSpec)
Write-Host "new-packet whitespace-goal exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "whitespace-only goal -> exit 1"

# 3f. non-JSON garbage is a clean usage error (twin of the .sh structural
#     brace gate) -- never a crash and never a silently created packet
$garbageSpec = Join-Path $tmp 'garbage-spec.json'
Write-Exact $garbageSpec 'this is not json at all'
$r = Run @('new-packet','-SpecFile',$garbageSpec)
Write-Host "new-packet garbage-spec exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "non-JSON spec garbage -> exit 1"

$spec = Join-Path $tmp 'spec.json'
Set-Content $spec (@'
{ "goal":"Fix http reset","symptom":["502 on idle"],
  "root_cause":["pool keep-alive too long"],"scope":["src/db"],
  "inputs":["a"],"acceptance":["test passes"],"constraints":["no new deps"] }
'@)

$r = Run @('new-packet','-SpecFile',$spec)
Write-Host "new-packet exit=$($r.Exit)"
Assert-True ($r.Exit -eq 0) "new-packet succeeds"

# parse created id
$id=$null
if ($r.Out -match '^created: (\S+)') { $id = $Matches[1] }
Assert-True (-not [string]::IsNullOrWhiteSpace($id)) "new-packet emits an id"

# 4. corrupt payload -> dispatch must refuse with 3
$payloadFile = Join-Path (Join-Path $env:SOL_LUNA_STATE_DIR 'packets') "$id.payload.md"
$origPayload = [System.IO.File]::ReadAllText($payloadFile, $Utf8NoBom)
Write-Exact $payloadFile ($origPayload + "`r`n// tampered")
$r = Run @('dispatch','-Id',$id,'-Transport','local-worker')
Write-Host "dispatch tampered exit=$($r.Exit)"
Assert-True ($r.Exit -eq 3) "dispatch on tampered payload -> exit 3"

# 4b. -TimeoutSec without -Transport must not alias-collapse into the transport
#     slot (regression: '900' was parsed as the transport name). The hash check
#     fires first, so this stays exit 3 and never spawns codex.
$r = Run @('dispatch','-Id',$id,'-TimeoutSec','900')
Write-Host "dispatch timeout-only exit=$($r.Exit)"
Assert-True ($r.Exit -eq 3) "dispatch with -TimeoutSec only still enforces hash -> exit 3"
# 4c. negative -TimeoutSec parses as a VALUE (not a flag) -> digits check -> exit 1
$r = Run @('dispatch','-Id',$id,'-TimeoutSec','-1')
Write-Host "dispatch negative-timeout exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "dispatch with -TimeoutSec -1 -> exit 1 (usage)"
# 4d. leading-zero value: [int] parses base-10, so the (still tampered) hash
#     check fires -> exit 3 (twin of the .sh `--timeout 08` case)
$r = Run @('dispatch','-Id',$id,'-TimeoutSec','08')
Write-Host "dispatch leading-zero timeout exit=$($r.Exit)"
Assert-True ($r.Exit -eq 3) "dispatch with -TimeoutSec 08 still enforces hash -> exit 3"
# 4e. flag without a value never silently falls back to the default -> exit 1
$r = Run @('dispatch','-Id',$id,'-Transport')
Write-Host "dispatch transport-no-value exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "dispatch with -Transport and no value -> exit 1"
# 4f. absurd values are bounded before the [int] cast -> exit 1 (no overflow)
$r = Run @('dispatch','-Id',$id,'-TimeoutSec','99999999999')
Write-Host "dispatch huge-timeout exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "dispatch with -TimeoutSec 99999999999 -> exit 1 (bounded)"
# 4g. Unicode digits: .NET \d would accept U+0665 as 5; the ASCII class refuses
$r = Run @('dispatch','-Id',$id,'-TimeoutSec',[char]0x0665)
Write-Host "dispatch unicode-digit timeout exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "dispatch with non-ASCII digit -TimeoutSec -> exit 1"
# 4h. a misspelled flag dies at parse time (Parse-Args whitelist) instead of
#     silently dropping the timeout guard and running unbounded
$r = Run @('dispatch','-Id',$id,'-TimeOutSec','5')
Write-Host "dispatch misspelled-flag exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "misspelled -TimeOutSec -> exit 1"
# 4i. short aliases are not accepted (twin of the .sh full-name-only options);
#     '-t' would collide with '-TimeoutSec' slot semantics
$r = Run @('dispatch','-Id',$id,'-t','web-manual')
Write-Host "dispatch short-alias exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "short alias -t refused -> exit 1"

# restore exact original bytes so later hash checks pass
Write-Exact $payloadFile $origPayload

# 5. dispatch a brand-new (payload intact, state new) packet with codex made
#    invisible on PATH -> should exit 2 (runtime), i.e. NOT silently degrade.
#    PATH is sandboxed for this one invocation so the test is deterministic
#    even on machines that DO have a real codex.exe installed.
$pathSave = $env:PATH
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
try {
    $r = Run @('dispatch','-Id',$id,'-Transport','local-worker')
} finally {
    $env:PATH = $pathSave
}
Write-Host "dispatch no-codex exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "dispatch without codex binary -> exit 2"

# 5b. a `.cmd` shim on PATH must NOT block local-worker: the BatBadBut guard is
#     SATISFIED, not bypassed -- the native codex.exe behind the npm-style shim
#     is resolved and executed. The shim's JS entrypoint is deliberately broken
#     (process.exit(9)), so a run that actually went through the shim could not
#     reach the worker at all.
$shimRoot   = Join-Path $tmp 'npm-shim'
$shimPkg    = Join-Path $shimRoot 'node_modules\@openai\codex'
$shimTriple = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$shimVendor = Join-Path $shimPkg ('node_modules\@openai\codex-win32-x64\vendor\' + $shimTriple + '\bin')
New-Item -ItemType Directory -Force -Path (Join-Path $shimPkg 'bin'), $shimVendor | Out-Null
Set-Content -Path (Join-Path $shimPkg 'bin\codex.js') -Value 'process.exit(9);'
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\hostname.exe') -Destination (Join-Path $shimVendor 'codex.exe') -Force
Set-Content -Path (Join-Path $shimRoot 'codex.cmd') -Value @(
    '@ECHO off',
    'SETLOCAL',
    'CALL :find_dp0',
    'node "%dp0%\node_modules\@openai\codex\bin\codex.js" %*'
)
$r = Run @('new-packet','-SpecFile',$spec)
$idShim = $null
if ($r.Out -match '^created: (\S+)') { $idShim = $Matches[1] }
Assert-True (-not [string]::IsNullOrWhiteSpace($idShim)) "shim fixture packet created"
$env:PATH = "$shimRoot;$env:SystemRoot\System32;$env:SystemRoot"
try { $r = Run @('dispatch','-Id',$idShim,'-Transport','local-worker') } finally { $env:PATH = $pathSave }
Write-Host "dispatch shim-resolved exit=$($r.Exit)"
Assert-True ($r.Err -match 'resolved native codex\.exe') "a .cmd shim on PATH is resolved to the native codex.exe behind it"
Assert-True ($r.Err -match [regex]::Escape((Join-Path $shimVendor 'codex.exe'))) "the resolved binary is the fixture vendor codex.exe"
Assert-True ($r.Err -notmatch 'BatBadBut') "resolving the shim does not trip the BatBadBut refusal"
Assert-True (($r.Exit -eq 0) -or ($r.Err -match 'codex exec exited')) "the resolved native codex.exe is what actually ran"

# 5c. a shim with NO native codex.exe behind it is still refused (exit 2): the
#     guard is satisfied by resolution, never removed.
$bareRoot = Join-Path $tmp 'npm-bare'
New-Item -ItemType Directory -Force -Path $bareRoot | Out-Null
Set-Content -Path (Join-Path $bareRoot 'codex.cmd') -Value @(
    '@ECHO off',
    'node "%dp0%\missing\codex.js" %*'
)
$r = Run @('new-packet','-SpecFile',$spec)
$idBare = $null
if ($r.Out -match '^created: (\S+)') { $idBare = $Matches[1] }
$env:PATH = "$bareRoot;$env:SystemRoot\System32;$env:SystemRoot"
try { $r = Run @('dispatch','-Id',$idBare,'-Transport','local-worker') } finally { $env:PATH = $pathSave }
Write-Host "dispatch bare-shim exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "shim with no native codex.exe behind it -> exit 2"
Assert-True ($r.Err -match 'BatBadBut') "the BatBadBut refusal still fires when nothing native exists"

# 5d. SOL_LUNA_CODEX_BIN pins the CLI for dispatch too. codex is taken OFF PATH
#     for both cases, so only the pin can make the run succeed.
$r = Run @('new-packet','-SpecFile',$spec)
$idPinExe = $null
if ($r.Out -match '^created: (\S+)') { $idPinExe = $Matches[1] }
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$env:SOL_LUNA_CODEX_BIN = (Join-Path $shimVendor 'codex.exe')
try { $r = Run @('dispatch','-Id',$idPinExe,'-Transport','local-worker') } finally { $env:PATH = $pathSave; Remove-Item Env:SOL_LUNA_CODEX_BIN }
Write-Host "dispatch pinned-exe exit=$($r.Exit)"
Assert-True ($r.Err -notmatch 'not on PATH') "SOL_LUNA_CODEX_BIN is honoured by dispatch with codex off PATH"
Assert-True (($r.Exit -eq 0) -or ($r.Err -match 'codex exec exited')) "the pinned native .exe is executed"

$r = Run @('new-packet','-SpecFile',$spec)
$idPinShim = $null
if ($r.Out -match '^created: (\S+)') { $idPinShim = $Matches[1] }
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$env:SOL_LUNA_CODEX_BIN = (Join-Path $shimRoot 'codex.cmd')
try { $r = Run @('dispatch','-Id',$idPinShim,'-Transport','local-worker') } finally { $env:PATH = $pathSave; Remove-Item Env:SOL_LUNA_CODEX_BIN }
Write-Host "dispatch pinned-shim exit=$($r.Exit)"
Assert-True ($r.Err -match 'resolved native codex\.exe') "a shim pinned via SOL_LUNA_CODEX_BIN is resolved, not executed"
Assert-True (($r.Exit -eq 0) -or ($r.Err -match 'codex exec exited')) "the native .exe behind the pinned shim is executed"

# redirect to web-manual (no binary needed), then ingest on wrong state flow
$r = Run @('dispatch','-Id',$id,'-Transport','web-manual')
Write-Host "dispatch web-manual exit=$($r.Exit)"
Assert-True ($r.Exit -eq 0) "web-manual dispatch succeeds"

# second dispatch of non-new packet refused
$r = Run @('dispatch','-Id',$id,'-Transport','web-manual')
Write-Host "re-dispatch exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "second dispatch of dispatched packet -> exit 1"

# 6b. ingest before dispatch on a fresh (state=new) packet -> exit 1
$r = Run @('new-packet','-SpecFile',$spec)
$id2=$null
if ($r.Out -match '^created: (\S+)') { $id2 = $Matches[1] }
Assert-True (-not [string]::IsNullOrWhiteSpace($id2)) "second new-packet emits an id"
$nope = Join-Path $tmp 'nope.md'
Write-Exact $nope 'nope'
$r = Run @('ingest','-Id',$id2,'-ResultFile',$nope)
Write-Host "ingest(new state) exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "ingest before dispatch -> exit 1"

# 7. ingest with parent binding: simulate the local-worker pre-registration by
#    writing the correct result hash into the packet, then prove a foreign file
#    is refused (exit 3) and the matching file ingests cleanly.
$res = Join-Path $tmp 'result.md'
Set-Content -Path $res -Value 'applied the patch; tests pass'
$rsha = (Get-FileHash -LiteralPath $res -Algorithm SHA256).Hash.ToLowerInvariant()
$pk = Join-Path (Join-Path $env:SOL_LUNA_STATE_DIR 'packets') "$id.execution.json"
# web-* dispatch does not pre-register a result hash, so inject it the way a
# local-worker dispatch would. Add-Member because the key may be absent
# entirely (ps1 only serializes properties that were set).
$pkObj = [System.IO.File]::ReadAllText($pk, $Utf8NoBom) | ConvertFrom-Json
Add-Member -InputObject $pkObj -NotePropertyName 'result_sha256' -NotePropertyValue $rsha -Force
[System.IO.File]::WriteAllText($pk, ($pkObj | ConvertTo-Json -Depth 10), $Utf8NoBom)
$badRes = Join-Path $tmp 'result-bad.md'
Write-Exact $badRes 'TAMPERED RESULT'
$r = Run @('ingest','-Id',$id,'-ResultFile',$badRes)
Write-Host "ingest tampered exit=$($r.Exit)"
Assert-True ($r.Exit -eq 3) "ingest with mismatched result hash -> exit 3"
# 7c. a MALFORMED recorded hash is corruption (exit 2), not a mismatch (exit 3)
$pkObj = [System.IO.File]::ReadAllText($pk, $Utf8NoBom) | ConvertFrom-Json
$pkObj.result_sha256 = 'not-a-hash'
[System.IO.File]::WriteAllText($pk, ($pkObj | ConvertTo-Json -Depth 10), $Utf8NoBom)
$r = Run @('ingest','-Id',$id,'-ResultFile',$res)
Write-Host "ingest malformed-recorded-sha exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "ingest with malformed recorded result_sha256 -> exit 2"
# restore the correct hash so the clean ingest below still passes
$pkObj = [System.IO.File]::ReadAllText($pk, $Utf8NoBom) | ConvertFrom-Json
$pkObj.result_sha256 = $rsha
[System.IO.File]::WriteAllText($pk, ($pkObj | ConvertTo-Json -Depth 10), $Utf8NoBom)
$r = Run @('ingest','-Id',$id,'-ResultFile',$res)
Write-Host "ingest exit=$($r.Exit)"
Assert-True ($r.Exit -eq 0) "ingest succeeds"

# 8. summary
$sum = Join-Path $tmp 'summary.md'
Set-Content -Path $sum -Value 'done'
$r = Run @('summary','-Id',$id,'-TextFile',$sum)
Write-Host "summary exit=$($r.Exit)"
Assert-True ($r.Exit -eq 0) "summary succeeds"

# 9. status shows summarized state
$r = Run @('status')
Write-Host "status exit=$($r.Exit)"
Assert-True ($r.Exit -eq 0) "status exit"
Assert-True ($r.Out -match 'summarized') "status reflects summarized state"

# 10. invalid id (path traversal shape) refused on every id-bearing command
$trav = '..%2F..%2Fetc%2Fpasswd'
$r = Run @('status','-Id','..\..\windows\win.ini')
Write-Host "status bad-id exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "status with traversal id -> exit 1"
$r = Run @('ingest','-Id','x/y','-ResultFile',$res)
Assert-True ($r.Exit -eq 1) "ingest with traversal id -> exit 1"
$r = Run @('dispatch','-Id',$trav)
Assert-True ($r.Exit -eq 1) "dispatch with encoded traversal id -> exit 1"

# 12. unknown option must be a usage error, never silently ignored
#     (regression: a typo'd flag used to be dropped and the command ran with
#     defaults -- the sh twin refuses, so must the ps1)
$r = Run @('dispatch','-Id',$id,'-BogusFlag','x')
Write-Host "dispatch unknown-option exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "dispatch with unknown option -> exit 1"
$r = Run @('status','-BogusFlag')
Assert-True ($r.Exit -eq 1) "status with unknown option -> exit 1"

# 13. over-long id (>60 chars): refused before any path is derived from it
#     (twin of the sh 60-char id cap)
$longId = ('a' * 61)
$r = Run @('status','-Id',$longId)
Assert-True ($r.Exit -eq 1) "status with over-long id -> exit 1"
$r = Run @('dispatch','-Id',$longId)
Assert-True ($r.Exit -eq 1) "dispatch with over-long id -> exit 1"
$r = Run @('ingest','-Id',$longId,'-ResultFile',$res)
Assert-True ($r.Exit -eq 1) "ingest with over-long id -> exit 1"

# 14. result file over the read cap: ingest refuses before hashing it
#     (twin of the sh MAX_JSON_BYTES guard; 1 MB + 1 byte). $id2 is state
#     'new', but the size cap fires before the state check, so exit 2.
$bigRes = Join-Path $tmp 'big-result.md'
Write-Exact $bigRes ('x' * (1MB + 1))
$r = Run @('ingest','-Id',$id2,'-ResultFile',$bigRes)
Write-Host "ingest oversize-result exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "ingest with oversize result -> exit 2"

# 14b. summary text over the read cap is refused before hashing it
#      (twin of the sh MAX_JSON_BYTES guard; same $id2 'new'-state reasoning
#      as above: the size cap fires before the state check, so exit 2).
$bigSum = Join-Path $tmp 'big-summary.md'
Write-Exact $bigSum ('x' * (1MB + 1))
$r = Run @('summary','-Id',$id2,'-TextFile',$bigSum)
Write-Host "summary oversize-text exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "summary with oversize text -> exit 2"

# 10b. corrupt packet: explicit status -> exit 2 (loud), bulk listing -> 0 (skip)
$badId = 'corrupttest1'
$badPk = Join-Path $env:SOL_LUNA_STATE_DIR "packets\$badId.execution.json"
Write-Exact $badPk '{ this is not json'
$r = Run @('status','-Id',$badId)
Write-Host "status corrupt exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "explicit status on corrupt packet -> exit 2"
$r = Run @('status')
Assert-True ($r.Exit -eq 0) "bulk status skips corrupt packet"
Remove-Item -LiteralPath $badPk -Force

# 10c. corrupt execution.json on the state-machine path -> exit 2
$badPk2 = Join-Path $env:SOL_LUNA_STATE_DIR 'packets\corrupttest2.execution.json'
Write-Exact $badPk2 '{ this is not json'
$r = Run @('dispatch','-Id','corrupttest2')
Write-Host "dispatch corrupt exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "dispatch on corrupt packet json -> exit 2"
Remove-Item -LiteralPath $badPk2 -Force

# 10d. payload over the 12000-byte hard limit -> exit 2 (no truncation, no pass)
$bigSpec = Join-Path $tmp 'big-spec.json'
Write-Exact $bigSpec ('{"goal":"' + ('x' * 13000) + '"}')
$r = Run @('new-packet','-SpecFile',$bigSpec)
Write-Host "new-packet oversize exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "oversize payload -> exit 2"

# 10e. a directory posing as an input file is a clean usage error (exit 1),
#      not a raw Get-FileHash failure (twin of the .sh -f guards)
$packetsDir = Join-Path $env:SOL_LUNA_STATE_DIR 'packets'
$r = Run @('ingest','-Id',$id,'-ResultFile',$packetsDir)
Write-Host "ingest dir-as-result exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "ingest with directory as result -> exit 1"
$r = Run @('new-packet','-SpecFile',$packetsDir)
Write-Host "new-packet spec-dir exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "new-packet with directory as spec -> exit 1"

# 11. journal.jsonl stays BOM-free (byte-compatible with the POSIX twin)
$journal = Join-Path $env:SOL_LUNA_STATE_DIR 'journal.jsonl'
$firstBytes = [System.IO.File]::ReadAllBytes($journal)[0..2]
Assert-True (-not ($firstBytes[0] -eq 0xEF -and $firstBytes[1] -eq 0xBB -and $firstBytes[2] -eq 0xBF)) "journal.jsonl has no UTF-8 BOM"

Write-Host ''
Write-Host "PASS=$pass FAIL=$fail"
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 } else { exit 0 }