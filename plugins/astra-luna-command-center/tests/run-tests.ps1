# astra-luna integration tests (Windows: run via powershell -File tests\run-tests.ps1)
#
# Verifies the astra-luna.ps1 state machine, hash binding, and hard-misuse
# refusals WITHOUT touching ~/.codex or the real config. A disposable
# CODEX_HOME is used.
#
# Coverage:
#   1. doctor on a fresh (no agent) CODEX_HOME -> exit 2
#   2. init writes the five luna role agents + skill + AGENTS.md rules (never config.toml)
#   2b. init is idempotent and NEVER overwrites an existing agent file
#       (coexistence with the old sol-luna plugin / hand-edited configs)
#   3. new-packet: missing spec/goal -> exit 1; valid spec -> packet built
#   4. dispatch: payload hash mismatch -> exit 3
#   5. dispatch: non-'new' state rejected -> exit 1
#   6. web-manual dispatch -> exit 0; re-dispatch of non-new packet -> exit 1
#   7. ingest before dispatch -> exit 1; happy path ingest -> exit 0
#   7b. ingest parent-binding mismatch (hash pre-registered at dispatch) -> exit 3
#   8. summary -> exit 0 (summary_sha256 matches the stored copy)
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
#  13. over-long id (>60 chars) -> exit 1 on every id-bearing command
#  14. oversize result file (> read cap) -> exit 2 (before state check)
# 14b. summary text over the read cap -> exit 2 (before state check)
# 10e. directory posing as spec/result file -> exit 1 (-PathType Leaf guards)
#  5b. dispatch with a .cmd `codex` shim on PATH -> the native codex.exe behind
#      it is resolved and executed (BatBadBut guard satisfied, not bypassed)
#  5c. dispatch with a shim that has NO native codex.exe behind it -> exit 2
#  5d. ASTRA_LUNA_CODEX_BIN pins the CLI for dispatch (a native .exe, and a
#      pinned shim is resolved rather than executed)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path          # ...\tests
$Plugin = Split-Path -Parent $Root                                 # plugin root
$Script = Join-Path $Plugin 'scripts\astra-luna.ps1'
$tmp = Join-Path $env:TEMP ("astra-luna-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Use a sandboxed Codex home AND a sandboxed state dir so nothing touches the
# real user profile or the plugin checkout.
$env:CODEX_HOME = Join-Path $tmp '.codex-home'
$env:ASTRA_LUNA_STATE_DIR = Join-Path $tmp 'state'
New-Item -ItemType Directory -Force -Path $env:CODEX_HOME, $env:ASTRA_LUNA_STATE_DIR | Out-Null

$pass = 0; $fail = 0
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# Byte-exact UTF-8 (no BOM) write helper: Set-Content would re-encode (ASCII in
# PS5.1, BOM'd UTF-8 elsewhere) and break the payload hash round-trip.
function Write-Exact([string]$path,[string]$text){ [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom) }
function Assert-True([bool]$c,[string]$msg){ if($c){$script:pass++} else {$script:fail++; Write-Host "  [FAIL] $msg" -ForegroundColor Red} }
function As-Bool($v) {
    if ($v -is [bool]) { return $v }
    if ($null -eq $v) { return $false }
    if ($v -is [System.Array]) { return (@($v).Count -gt 0) }
    return [bool]$v
}
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
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argLine -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $o = Get-Content $outFile -Raw
    $e = Get-Content $errFile -Raw
    return [pscustomobject]@{ Exit=$p.ExitCode; Out=$o; Err=$e }
}

# 1. doctor on empty config -> exit 2
$r = Run @('doctor')
Write-Host "doctor(empty) exit=$($r.Exit)"
Assert-True (As-Bool ($r.Exit -eq 2)) "doctor on empty CODEX_HOME should exit 2"
# 1b. first-run guard: the fix must name the init command so the missing step
#     cannot be skipped (regression for the copy-pasteable remedy)
Assert-True (As-Bool ($r.Err -match 'astra-luna\.ps1.* init')) "doctor prints the init fix command"

# 2. init installs
$r = Run @('init')
Write-Host "init exit=$($r.Exit)"
Assert-True ($r.Exit -eq 0) "init should succeed"
foreach ($agent in 'astra-explorer.toml','astra-worker.toml','astra-tester.toml','astra-reviewer.toml','astra-researcher.toml') {
    Assert-True (Test-Path (Join-Path (Join-Path $env:CODEX_HOME 'agents') $agent)) "init writes agent TOML $agent"
}
Assert-True (Test-Path (Join-Path $env:CODEX_HOME 'skills\astra-command-center\SKILL.md')) "init installs skill"
Assert-True (-not (Test-Path (Join-Path $env:CODEX_HOME 'config.toml'))) "init never writes config.toml"

# 2b. init is idempotent and never overwrites an existing agent file
#     (coexistence contract: the old sol-luna plugin's installs and any
#     hand-edited astra_*.toml must survive a re-init untouched)
$sentinel = Join-Path $env:CODEX_HOME 'agents\astra-worker.toml'
$sentinelBody = 'name = "astra_worker_customized"  # hand-edited, must survive'
Write-Exact $sentinel $sentinelBody
$r = Run @('init')
Assert-True ($r.Exit -eq 0) "re-init should succeed"
Assert-True (([System.IO.File]::ReadAllText($sentinel, $Utf8NoBom)) -eq $sentinelBody) "re-init preserves an existing agent TOML verbatim"
Assert-True ($r.Out -match 'existing agent preserved') "re-init reports preserved agents"

# doctor now sees the agent -> exits 0, and reports BOTH model bindings
$r = Run @('doctor')
Assert-True (As-Bool ($r.Exit -eq 0)) "doctor exits 0 after init"
Assert-True (As-Bool ($r.Out -match 'gpt-5\.6-luna')) "doctor reports luna worker model"
Assert-True (As-Bool ($r.Out -match 'gpt-6-astra')) "doctor reports astra orchestrator model"
Assert-True (As-Bool ($r.Out -match '"luna_effort":\s*"max"')) "doctor reports luna max effort"

# 15. doctor exposes the codex CLI config probe (regression for the incident
#     where doctor reported healthy while EVERY codex exec died on a config
#     parse error before ever reaching the model)
$r = Run @('doctor')
Assert-True ($r.Out -match '"codex_cli_config"') "doctor reports codex_cli_config"

# 15b. broken codex config.toml -> doctor exits 2 and names the culprit.
#      The real-world failure: a nested table under [features] (e.g.
#      [features.context_management]) makes the CLI fail with 'invalid type:
#      map, expected a boolean' on EVERY codex exec while the desktop app
#      keeps working. A fake codex binary via ASTRA_LUNA_CODEX_BIN (the probe
#      only passes fixed args) keeps the test deterministic.
$fakeBin = Join-Path $tmp 'fake-codex.cmd'
$fakeLines = @(
    '@echo off',
    'if exist "%CODEX_HOME%\config.toml" (',
    '  findstr /b /c:"[features." "%CODEX_HOME%\config.toml" >nul 2>&1',
    '  if not errorlevel 1 (',
    '    echo Error loading configuration: config.toml: invalid type: map, expected a boolean 1>&2',
    '    exit /b 1',
    '  )',
    ')',
    'echo Not logged in 1>&2',
    'exit /b 1'
)
[System.IO.File]::WriteAllText($fakeBin, (($fakeLines -join "`r`n") + "`r`n"), $Utf8NoBom)
$env:ASTRA_LUNA_CODEX_BIN = $fakeBin
$cfgSandbox = Join-Path $env:CODEX_HOME 'config.toml'
Write-Exact $cfgSandbox "model = `"gpt-6-astra`"`r`n[features]`r`nfast_mode = true`r`n[features.context_management]`r`nexperimental_mode = true`r`n"
$r = Run @('doctor')
Write-Host "doctor broken-config exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "doctor on broken codex config -> exit 2"
Assert-True ($r.Err -match 'features\.context_management') "doctor names the offending [features.*] table"
Assert-True ($r.Out -match '"codex_cli_config":\s*false') "doctor verdict codex_cli_config=false"
# repaired config (all-boolean [features]) -> healthy again
Write-Exact $cfgSandbox "model = `"gpt-6-astra`"`r`n[features]`r`nfast_mode = true`r`n"
$r = Run @('doctor')
Assert-True ($r.Exit -eq 0) "doctor on repaired codex config exits 0"
Remove-Item Env:ASTRA_LUNA_CODEX_BIN
Remove-Item -LiteralPath $cfgSandbox -Force

# 15c. init refreshes the installed skill WITH the launcher runtime clone
#      (regression: the installed skill copy referenced ..\..\scripts\ which
#      does not exist under ~/.codex/skills)
$skillHome = Join-Path $env:CODEX_HOME 'skills\astra-command-center'
Assert-True (Test-Path (Join-Path $skillHome 'scripts\astra-luna.ps1')) "init clones the launcher ps1 into the installed skill"
Assert-True (Test-Path (Join-Path $skillHome 'scripts\astra-luna.sh')) "init clones the launcher sh into the installed skill"
Assert-True (Test-Path (Join-Path $skillHome 'config\config.toml.example')) "init clones config/ into the installed skill"

# 15d. chatgpt-web transport: doctor reports the environment probe verdict
#      and the transport list contains the chatgpt-web key
$r = Run @('doctor')
Assert-True ($r.Out -match '"chatgpt_web"') "doctor reports chatgpt_web probe"
Assert-True ($r.Out -match '"transports":\s*\{[^}]*"chatgpt_web"') "transports map contains the chatgpt_web key"
# 15e. chatgpt-web dispatch on a FRESH packet with NO interpreter on PATH
#      (python/python3/py all absent: System32 only) and NO ASTRA_LUNA_PYTHON
#      -> exit 2 with a python-missing message (no silent degradation; a
#      reused 'done' packet would fail the state check first)
$cwSpec = Join-Path $tmp 'cw-spec.json'
Set-Content $cwSpec (@'
{ "goal":"chatgpt-web transport smoke test","scope":["none"],
  "acceptance":["no python needed"],"constraints":["test only"] }
'@)
$r = Run @('new-packet','-SpecFile',$cwSpec)
$id3=$null
if ($r.Out -match '^created: (\S+)') { $id3 = $Matches[1] }
Assert-True (-not [string]::IsNullOrWhiteSpace($id3)) "fresh packet for chatgpt-web tests"
$pythonSave = $env:ASTRA_LUNA_PYTHON
Remove-Item Env:ASTRA_LUNA_PYTHON -ErrorAction SilentlyContinue
$pathSave2 = $env:PATH
# System32 ONLY (no C:\Windows): py.exe lives in C:\Windows on hosts with the
# Python launcher installed, so including SystemRoot would make "no python"
# false there (py resolves and the test would run the REAL browser bridge).
# Pure System32 is deterministic everywhere: python/python3/py all absent.
$env:PATH = "$env:SystemRoot\System32"
try {
    $r = Run @('dispatch','-Id',$id3,'-Transport','chatgpt-web')
} finally {
    $env:PATH = $pathSave2
    if ($pythonSave) { $env:ASTRA_LUNA_PYTHON = $pythonSave }
}
Write-Host "chatgpt-web no-python exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "chatgpt-web dispatch without python -> exit 2"
Assert-True ([bool]($r.Err -match 'python')) "chatgpt-web no-python error names python"
# 15f. chatgpt-web dispatch with a FAKE python that fails with exit 2 (py
#     checker) is reported as an environment failure -> exit 2
$fakePy = Join-Path $tmp 'fake-py.cmd'
[System.IO.File]::WriteAllText($fakePy, "@echo off`r`nexit /b 2`r`n", $Utf8NoBom)
$env:ASTRA_LUNA_PYTHON = $fakePy
try {
    $r = Run @('dispatch','-Id',$id3,'-Transport','chatgpt-web')
} finally {
    Remove-Item Env:ASTRA_LUNA_PYTHON
}
Write-Host "chatgpt-web fake-py exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "chatgpt-web fake-py env failure -> exit 2"
Assert-True ($r.Err -match 'chatgpt-web failed') "chatgpt-web failure message present"

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

# the packet pins the luna worker model pair
$pkFile = Join-Path (Join-Path $env:ASTRA_LUNA_STATE_DIR 'packets') "$id.execution.json"
$pkObj = [System.IO.File]::ReadAllText($pkFile, $Utf8NoBom) | ConvertFrom-Json
Assert-True ($pkObj.model -eq 'gpt-5.6-luna') "packet pins gpt-5.6-luna"
Assert-True ($pkObj.effort -eq 'max') "packet pins max effort"

# 4. corrupt payload -> dispatch must refuse with 3
$payloadFile = Join-Path (Join-Path $env:ASTRA_LUNA_STATE_DIR 'packets') "$id.payload.md"
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

# 5d. ASTRA_LUNA_CODEX_BIN pins the CLI for dispatch too. codex is taken OFF
#     PATH for both cases, so only the pin can make the run succeed.
$r = Run @('new-packet','-SpecFile',$spec)
$idPinExe = $null
if ($r.Out -match '^created: (\S+)') { $idPinExe = $Matches[1] }
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$env:ASTRA_LUNA_CODEX_BIN = (Join-Path $shimVendor 'codex.exe')
try { $r = Run @('dispatch','-Id',$idPinExe,'-Transport','local-worker') } finally { $env:PATH = $pathSave; Remove-Item Env:ASTRA_LUNA_CODEX_BIN }
Write-Host "dispatch pinned-exe exit=$($r.Exit)"
Assert-True ($r.Err -notmatch 'not on PATH') "ASTRA_LUNA_CODEX_BIN is honoured by dispatch with codex off PATH"
Assert-True (($r.Exit -eq 0) -or ($r.Err -match 'codex exec exited')) "the pinned native .exe is executed"

$r = Run @('new-packet','-SpecFile',$spec)
$idPinShim = $null
if ($r.Out -match '^created: (\S+)') { $idPinShim = $Matches[1] }
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$env:ASTRA_LUNA_CODEX_BIN = (Join-Path $shimRoot 'codex.cmd')
try { $r = Run @('dispatch','-Id',$idPinShim,'-Transport','local-worker') } finally { $env:PATH = $pathSave; Remove-Item Env:ASTRA_LUNA_CODEX_BIN }
Write-Host "dispatch pinned-shim exit=$($r.Exit)"
Assert-True ($r.Err -match 'resolved native codex\.exe') "a shim pinned via ASTRA_LUNA_CODEX_BIN is resolved, not executed"
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
$pk = $pkFile
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

# 8. summary — and prove summary_sha256 describes the STORED copy
$sum = Join-Path $tmp 'summary.md'
Set-Content -Path $sum -Value 'done'
$r = Run @('summary','-Id',$id,'-TextFile',$sum)
Write-Host "summary exit=$($r.Exit)"
Assert-True ($r.Exit -eq 0) "summary succeeds"
$pkObj = [System.IO.File]::ReadAllText($pk, $Utf8NoBom) | ConvertFrom-Json
$storedSha = (Get-FileHash -LiteralPath $pkObj.summary_file -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($pkObj.summary_sha256 -eq $storedSha) "summary_sha256 matches the stored copy"

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
$badPk = Join-Path $env:ASTRA_LUNA_STATE_DIR "packets\$badId.execution.json"
Write-Exact $badPk '{ this is not json'
$r = Run @('status','-Id',$badId)
Write-Host "status corrupt exit=$($r.Exit)"
Assert-True ($r.Exit -eq 2) "explicit status on corrupt packet -> exit 2"
$r = Run @('status')
Assert-True ($r.Exit -eq 0) "bulk status skips corrupt packet"
Remove-Item -LiteralPath $badPk -Force

# 10c. corrupt execution.json on the state-machine path -> exit 2
$badPk2 = Join-Path $env:ASTRA_LUNA_STATE_DIR 'packets\corrupttest2.execution.json'
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
$packetsDir = Join-Path $env:ASTRA_LUNA_STATE_DIR 'packets'
$r = Run @('ingest','-Id',$id,'-ResultFile',$packetsDir)
Write-Host "ingest dir-as-result exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "ingest with directory as result -> exit 1"
$r = Run @('new-packet','-SpecFile',$packetsDir)
Write-Host "new-packet spec-dir exit=$($r.Exit)"
Assert-True ($r.Exit -eq 1) "new-packet with directory as spec -> exit 1"

# 11. journal.jsonl stays BOM-free (byte-compatible with the POSIX twin)
$journal = Join-Path $env:ASTRA_LUNA_STATE_DIR 'journal.jsonl'
if ((Test-Path $journal) -and ((Get-Item $journal).Length -ge 3)) {
    $firstBytes = [System.IO.File]::ReadAllBytes($journal)[0..2]
    Assert-True (As-Bool (-not ($firstBytes[0] -eq 0xEF -and $firstBytes[1] -eq 0xBB -and $firstBytes[2] -eq 0xBF))) "journal.jsonl has no UTF-8 BOM"
} else {
    Assert-True $true "journal.jsonl exists (or empty-safe skip BOM check)"
}

# ---------------- astra-Diy (OpenAI-compatible custom worker) ----------------
# Offline only: no network. Verifies diy-set/show, incomplete-config refusal,
# and that diy-openai dispatch fails closed without falling back to luna.

# 20. diy-schema prints field schema
$r = Run @('diy-schema')
Write-Host "diy-schema exit=$($r.Exit)"
Assert-True (As-Bool ($r.Exit -eq 0)) "diy-schema exit 0"
Assert-True (As-Bool ($r.Out -match 'base_url')) "diy-schema lists base_url"
Assert-True (As-Bool ($r.Out -match 'api_key')) "diy-schema lists api_key"
Assert-True (As-Bool ($r.Out -match 'model')) "diy-schema lists model"

# 21. diy-set writes config; diy-show reports readiness (short HTTP timeout)
$r = Run @('diy-set','-BaseUrl','http://127.0.0.1:9/v1','-ApiKey','sk-test-key','-Model','custom-worker-x','-Enabled','true','-ReplaceLuna','true','-TimeoutSec','5')
Write-Host "diy-set exit=$($r.Exit)"
Assert-True (As-Bool ($r.Exit -eq 0)) "diy-set succeeds"
$diyFile = Join-Path $env:ASTRA_LUNA_STATE_DIR 'diy.json'
Assert-True (Test-Path $diyFile) "diy.json written under state dir"
$r = Run @('diy-show')
Write-Host "diy-show exit=$($r.Exit)"
Assert-True (As-Bool ($r.Exit -eq 0)) "diy-show exit 0"
Assert-True (As-Bool ($r.Out -match 'custom-worker-x')) "diy-show reports custom model"
Assert-True (As-Bool ($r.Out -match 'ready')) "diy-show includes ready field"
Assert-True (As-Bool ($r.Out -notmatch 'sk-test-key')) "diy-show masks api key"

# 22. diy-openai dispatch with unreachable provider fails closed (exit 2),
#     packet stays 'new' — no silent luna fallback, no state advance.
$specDiy = Join-Path $tmp 'diy-spec.json'
Write-Exact $specDiy '{"goal":"DIY offline transport refusal probe","scope":["src/x.py"],"acceptance":["dispatch must fail closed"],"inputs":["provider unreachable"],"constraints":["no network in tests"],"files":["src/x.py"],"symptom":["n/a"],"root_cause":["n/a"],"evidence":["unit test"]}'
$r = Run @('new-packet','-SpecFile',$specDiy)
Assert-True (As-Bool ($r.Exit -eq 0)) "diy new-packet ok"
$diyId = ($r.Out -split "`n" | Where-Object { $_ -match '^created: ' } | ForEach-Object { $_.Replace('created: ','').Trim() } | Select-Object -First 1)
Assert-True ([bool]$diyId) "diy packet id captured"
$r = Run @('dispatch','-Id',$diyId,'-Transport','diy-openai','-TimeoutSec','20')
Write-Host "diy-openai dispatch exit=$($r.Exit) (expect fail-closed)"
Assert-True (As-Bool ($r.Exit -in @(2,3))) "diy-openai against dead provider fails closed (2 or 3)"
$r = Run @('status','-Id',$diyId)
Assert-True (As-Bool ($r.Out -match '"state"\s*:\s*"new"')) "failed diy dispatch leaves packet state=new"

# 23. diy-clear disables DIY; show reports enabled=false
$r = Run @('diy-clear')
Write-Host "diy-clear exit=$($r.Exit)"
Assert-True (As-Bool ($r.Exit -eq 0)) "diy-clear exit 0"
$r = Run @('diy-show')
Assert-True (As-Bool ($r.Out -match '"enabled"\s*:\s*false')) "diy-show after clear reports enabled=false"

# 24. incomplete diy config + diy-openai dispatch -> exit 3 (fail closed, no luna)
$r = Run @('diy-set','-BaseUrl','http://127.0.0.1:9/v1','-Model','m1','-Enabled','true','-ReplaceLuna','true','-TimeoutSec','5')
Assert-True (As-Bool ($r.Exit -eq 0)) "diy-set without key succeeds"
$r = Run @('dispatch','-Id',$diyId,'-Transport','diy-openai')
Write-Host "diy incomplete dispatch exit=$($r.Exit)"
Assert-True (As-Bool ($r.Exit -eq 3)) "incomplete diy config dispatch -> exit 3"

Write-Host ''
Write-Host "PASS=$pass FAIL=$fail"
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 } else { exit 0 }
