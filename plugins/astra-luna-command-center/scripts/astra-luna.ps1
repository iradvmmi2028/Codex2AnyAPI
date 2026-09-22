#Requires -Version 5.1
<#
  astra-luna.ps1 -- GPT-6 Astra command-center plugin (Windows transport).

  Workflow:
    GPT-6 Astra (Codex) --packet--> gpt-5.6-luna workers (max effort) --result--> Astra (summary)

  Subcommands:
    doctor       Ready checks (transport, agent TOMLs, size limit) -> JSON verdict
    init         Idempotent install: luna role agent TOMLs, skill, AGENTS.md rules.
                 NEVER edits config.toml (only reports the recommendation).
                 NEVER overwrites an existing agent/skill file (coexists with
                 the old sol-luna plugin's installs).
    new-packet   -SpecFile <json>       build an execution packet + payload.md
    dispatch     -Id <id> [-Transport web-manual|local-worker|chatgpt-web|diy-openai] [-TimeoutSec <n>]
    ingest       -Id <id> -ResultFile <file>
    summary      -Id <id> -TextFile <file>
    status       [-Id <id>] : list packet states
    diy-set      [-BaseUrl <url>] [-ApiKey <key>] [-Model <id>] [-Enabled true|false]
                 [-ReplaceLuna true|false] [-Temperature <n>] [-TimeoutSec <n>]
    diy-show     DIY status JSON (api key masked)
    diy-clear    disable DIY and clear the stored API key
    diy-test     connection/auth probe against the OpenAI-compatible provider
    diy-models   list model ids from the provider
    diy-settings open the Windows settings dialog (textboxes for baseurl/key/model)
    diy-schema   print the DIY settings field schema

  DIY (astra-Diy): when enabled + replace_luna, worker execution is sent to a
  user-configured OpenAI-compatible API instead of gpt-5.6-luna. GPT-6 Astra
  remains the control tower (plan, packet, review, summary).

  Exit: 0 ok | 1 usage/validation | 2 runtime | 3 hash mismatch
  This tool NEVER silently degrades transport or model.

  Environment:
    ASTRA_LUNA_STATE_DIR  state directory override (default <plugin>\.astra-luna-state)
    CODEX_HOME            Codex home override (default %USERPROFILE%\.codex)
    ASTRA_LUNA_CODEX_BIN  explicit codex CLI path (pinned/non-PATH installs and
                          tests). Used by the doctor config probe and by
                          dispatch; dispatch accepts a native .exe (a shim is
                          resolved to the native codex.exe behind it)
    ASTRA_LUNA_CHATGPT_BIN  explicit chatgpt-web.py path for the chatgpt-web
                            transport (tests/installations outside the plugin)
    ASTRA_LUNA_PYTHON       explicit Python interpreter (default: python on PATH)
    ASTRA_LUNA_CHATGPT_PROFILE  persistent ChatGPT browser profile directory
                            (default: <state_dir>\chatgpt-web-profile)
    ASTRA_LUNA_CHATGPT_BROWSER  explicit browser executable (default: QQ > Edge > Chrome)
    ASTRA_LUNA_PYTHON       also used by the diy-openai transport and diy-settings
    ASTRA_DIY_CONFIG        DIY config path override (default: <state_dir>\diy.json)
    ASTRA_DIY_API_KEY       DIY API key override (wins over the key stored in diy.json)

  Security notes:
    - packet ids are strictly validated (^[A-Za-z0-9][A-Za-z0-9._-]{0,59}$);
      path metacharacters never reach the filesystem.
    - the per-packet dispatch lock is created atomically (FileMode CreateNew);
      a lock whose recorded owner process is gone, or one older than 1h, is
      stale: removed once, then retried.
    - hashes are computed over raw bytes (SHA-256), never re-encoded text.
    - dispatch is SINGLE-READ bound: the payload is read from disk exactly
      once into a byte array; the hash is verified over those bytes and those
      same bytes are what reach the worker / web staging file. The old
      hash-file-then-reread-file pattern (a TOCTOU swap window) is gone.
    - summary copies first and hashes the final copy, so summary_sha256 always
      matches the bytes on disk.
    - every temp file inside the state dir carries a random GUID suffix
      (predictable names are a symlink-planting hazard on shared hosts).
    - local-worker only ever CreateProcess's a NATIVE codex.exe. A .cmd/.bat
      `codex` shim is never executed (it would hand the payload to cmd.exe's
      re-parsing: BatBadBut); the native binary behind the shim is resolved and
      used instead, and when none can be proven to exist dispatch refuses.
    - child process output is drained asynchronously (no pipe deadlock) and
      every argv element is quoted with MSVCRT rules before CreateProcess;
      the worker stdout size cap is measured in UTF-8 BYTES, not chars.
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('doctor','init','new-packet','dispatch','ingest','summary','status','diy-set','diy-show','diy-clear','diy-test','diy-models','diy-settings','diy-schema')]
    [string]$Command,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RawArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PLUGIN_DIR  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$STATE_DIR   = if ($env:ASTRA_LUNA_STATE_DIR) { [System.IO.Path]::GetFullPath($env:ASTRA_LUNA_STATE_DIR) }
               else { Join-Path $PLUGIN_DIR '.astra-luna-state' }
$PACKETS_DIR = Join-Path $STATE_DIR 'packets'
$RESULTS_DIR = Join-Path $STATE_DIR 'results'
$JOURNAL     = Join-Path $STATE_DIR 'journal.jsonl'
$DEFAULT_MAX_PAYLOAD_BYTES = 12000
$MAX_JSON_BYTES            = 1MB      # read cap for spec / execution.json (memory boundary)
$MAX_TIMEOUT_SECONDS       = 86400    # upper-bound twin of the .sh dispatch guard (24h);
                                      # keeps Invoke-Run's millisecond math inside int32
$LOCK_STALE_SECONDS        = 3600
$ASTRA_MODEL = 'gpt-6-astra'          # orchestrator (this Codex session); configured
$ASTRA_EFFORT = 'high'                # in config.toml -- this tool never edits it
$LUNA_MODEL  = 'gpt-5.6-luna'         # default worker fleet (replaced by DIY when enabled)
$LUNA_EFFORT = 'max'
$MD_BEGIN    = 'astra-luna:begin'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:EXIT = 0
$script:OwnedLock = $null

function Get-DiyConfigPath {
    if ($env:ASTRA_DIY_CONFIG) { return [System.IO.Path]::GetFullPath($env:ASTRA_DIY_CONFIG) }
    return (Join-Path $STATE_DIR 'diy.json')
}
function Get-OpenAiDiyScript {
    if ($env:ASTRA_DIY_BIN) {
        if (Test-Path -LiteralPath $env:ASTRA_DIY_BIN -PathType Leaf) { return $env:ASTRA_DIY_BIN }
        return $null
    }
    $p = Join-Path $PLUGIN_DIR 'scripts\openai-diy.py'
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    return $null
}
function Get-DiySettingsScript {
    $p = Join-Path $PLUGIN_DIR 'scripts\diy-settings.ps1'
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    return $null
}
function Read-DiyConfig {
    # Returns an ordered hashtable with diy fields; empty when missing/unreadable.
    $path = Get-DiyConfigPath
    $out = [ordered]@{
        path = $path
        exists = (Test-Path -LiteralPath $path)
        enabled = $false
        replace_luna = $true
        base_url = ''
        model = ''
        has_api_key = $false
        api_key_env = [bool]($env:ASTRA_DIY_API_KEY)
        temperature = 0.2
        timeout_sec = 900
        ready = $false
        parse_error = ''
    }
    if (-not $out.exists) { return $out }
    try {
        if ((Get-Item -LiteralPath $path).Length -gt $MAX_JSON_BYTES) {
            $out.parse_error = 'diy.json larger than read cap'
            return $out
        }
        $raw = [System.IO.File]::ReadAllText($path)
        $j = $raw | ConvertFrom-Json
        $out.enabled = [bool](Get-Field $j 'enabled')
        $rl = Get-Field $j 'replace_luna'
        if ($null -ne $rl) { $out.replace_luna = [bool]$rl } else { $out.replace_luna = $true }
        $out.base_url = [string](Get-Field $j 'base_url')
        $out.model = [string](Get-Field $j 'model')
        $key = [string](Get-Field $j 'api_key')
        $out.has_api_key = [bool]$key -or $out.api_key_env
        $t = Get-Field $j 'temperature'
        if ($null -ne $t) { try { $out.temperature = [double]$t } catch {} }
        $ts = Get-Field $j 'timeout_sec'
        if ($null -ne $ts) { try { $out.timeout_sec = [int]$ts } catch {} }
        $out.ready = ($out.enabled -and $out.base_url -and $out.model -and ($out.has_api_key -or $out.api_key_env))
    } catch {
        $out.parse_error = [string]$_.Exception.Message
    }
    return $out
}
function Test-DiyReplacesLuna {
    # True when DIY is fully configured AND the user asked it to replace luna-max.
    $d = Read-DiyConfig
    return ($d.ready -and $d.replace_luna)
}
function Invoke-OpenAiDiy {
    # Thin wrapper around scripts/openai-diy.py. Returns the process result object.
    param([string[]]$ArgList,[int]$TimeoutSec = 60)
    $scriptPath = Get-OpenAiDiyScript
    if (-not $scriptPath) { Die 2 'diy: openai-diy.py not found (install complete or set ASTRA_DIY_BIN)' }
    $py = Get-PythonCommand
    if (-not $py) { Die 2 'diy: python not found; set ASTRA_LUNA_PYTHON or put python on PATH' }
    return Invoke-Run $py (@($scriptPath) + $ArgList) $TimeoutSec
}

function Write-Err([string]$m){ [Console]::Error.WriteLine('astra-luna: ' + $m) }
function Die([int]$c,[string]$m){ if($m){Write-Err $m}; exit $c }
function New-RandomTag { return [guid]::NewGuid().ToString('N') }

function Parse-Args([string]$cmd,[string[]]$allowed) {
    # Strict option parsing, twin of the .sh per-command `case` whitelist.
    # Unknown options and stray positional tokens are usage errors (exit 1)
    # at parse time, never silently dropped: a typo'd flag (-TimeOutSec) used
    # to remove its own guard rail (the timeout) and run unbounded.
    # Option matching is case-sensitive (-cnotcontains) so -ID is refused
    # exactly like the .sh refuses --ID.
    $map = @{}
    $n = if ($null -eq $RawArgs) { 0 } else { @($RawArgs).Count }
    $i = 0
    while ($i -lt $n) {
        $k = [string]$RawArgs[$i]
        if ($k.Length -gt 1 -and $k[0] -eq '-') {
            $key = $k.TrimStart('-')
            if ($allowed -cnotcontains $key) { Die 1 "${cmd}: unknown option $k" }
            $i++
            $next = if ($i -lt $n) { [string]$RawArgs[$i] } else { $null }
            # a token like '-1' is a negative-number VALUE, not a flag
            # (ASCII digits only, twin of the .sh '[!0-9]' byte class)
            if ($null -ne $next -and ($next -notlike '-*' -or $next -match '^-[0-9]+$')) { $map[$key] = $next; $i++ }
            else { $map[$key] = $true }
        } else {
            Die 1 "${cmd}: unexpected argument '$k'"
        }
    }
    return $map
}
function Get-ArgVal($m,[string]$name,[object]$def,[string]$cmd) {
    # Full option name only; a flag seen WITHOUT a value ('-Transport' at end
    # of argv) never falls back silently to the default: that is a usage
    # error (exit 1), twin of the .sh "<option> needs a value" path.
    if (-not $m.ContainsKey($name)) { return $def }
    $v = $m[$name]
    if ($v -is [bool]) { Die 1 "${cmd}: -$name needs a value" }
    return [string]$v
}
function Test-ValidId([string]$id) { return ($id -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,59}$') }

function Ensure-Dirs {
    New-Item -ItemType Directory -Force -Path $PACKETS_DIR, $RESULTS_DIR | Out-Null
    if (-not (Test-Path -LiteralPath $JOURNAL)) {
        [System.IO.File]::WriteAllText($JOURNAL, '', $script:Utf8NoBom)
        return
    }
    # Legacy migration (twin of the .sh ensure_dirs): pre-1.0 journals carried
    # bare objects without the "event" key; re-wrap them once, atomically.
    if ((Get-Item -LiteralPath $JOURNAL).Length -gt 0) {
        # Memory boundary: the journal is append-only and unbounded, so probe a
        # bounded 64 KB head for the "event" marker instead of slurping the
        # whole file on every command. Every line this tool writes carries
        # "event" right at the start; a never-migrated legacy journal has it
        # nowhere, so a head miss means "migrate once" (full read, one time).
        $needMigration = $false
        try {
            $fs = [System.IO.File]::OpenRead($JOURNAL)
            try {
                $bufLen = [int][Math]::Min(65536L, $fs.Length)
                $buf = New-Object byte[] $bufLen
                $read = 0
                while ($read -lt $bufLen) {
                    $n = $fs.Read($buf, $read, $bufLen - $read)
                    if ($n -le 0) { break }
                    $read += $n
                }
                $needMigration = ([Text.Encoding]::UTF8.GetString($buf, 0, $read) -notmatch '"event"')
            } finally { $fs.Dispose() }
        } catch { $needMigration = $false }
        if ($needMigration) {
            $lines = @([System.IO.File]::ReadAllLines($JOURNAL, $script:Utf8NoBom) |
                       Where-Object { $_.Trim() -ne '' })
            if ($lines.Count -gt 0) {
                $mig = "$JOURNAL.migrate.$(New-RandomTag)"
                $body = ($lines | ForEach-Object { '{"legacy":' + $_ + '}' }) -join [Environment]::NewLine
                [System.IO.File]::WriteAllText($mig, $body + [Environment]::NewLine, $script:Utf8NoBom)
                Move-Item -LiteralPath $mig -Destination $JOURNAL -Force
            }
        }
    }
}
function Get-Home {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    if ($env:HOME) { return $env:HOME }
    return [Environment]::GetFolderPath('UserProfile')
}
function Get-CodexDir {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return (Join-Path (Get-Home) '.codex')
}
function Get-AgentsDir { Join-Path (Get-CodexDir) 'agents' }
function Get-PrimaryAgentToml { Join-Path (Get-AgentsDir) 'astra-worker.toml' }
function Get-SkillDst  { Join-Path (Get-CodexDir) 'skills\astra-command-center' }
function Get-AgentsMd  { Join-Path $PWD.Path 'AGENTS.md' }
function Get-Now { try { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { (Get-Date).ToString('s') } }

function Get-Sha256Bytes([byte[]]$bytes) {
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($bytes)
            $sb = New-Object System.Text.StringBuilder 64
            foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2')) }
            return $sb.ToString()
        } finally { $sha.Dispose() }
    } catch {
        Die 2 ("sha256: cannot hash byte payload: " + $_.Exception.Message)
    }
}
function Get-Sha256File([string]$path) {
    # Defense in depth: callers normally Test-Path -PathType Leaf first; a
    # missing file or a directory here would surface as a raw exception, so
    # fail with a clean verdict instead.
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Die 2 "sha256: file not found: $path" }
    # Pure .NET hash: the Get-FileHash cmdlet is a Microsoft.PowerShell.Utility
    # cmdlet that is NOT loaded in some host/constrained-language shells (the
    # in-session worker threw "Get-FileHash is not recognized"). SHA256.Create
    # + ComputeHash works on every PowerShell/.NET version and needs no module
    # autoload, so hashing never depends on the host's cmdlet set.
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $fs = [System.IO.File]::OpenRead($path)
            try {
                $bytes = $sha.ComputeHash($fs)
                $sb = New-Object System.Text.StringBuilder 64
                foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
                return $sb.ToString()
            } finally { $fs.Dispose() }
        } finally { $sha.Dispose() }
    } catch {
        Die 2 ("sha256: cannot hash '" + $path + "': " + $_.Exception.Message)
    }
}
function Test-Sha256Shape([string]$h) { return ($h -match '^[0-9a-fA-F]{64}$') }
function Write-TextNoBom([string]$path,[string]$text) {
    [System.IO.File]::WriteAllText($path, $text, $script:Utf8NoBom)
}
function Journal-Log($obj) {
    Ensure-Dirs
    $o = [ordered]@{ stamp = Get-Now }
    foreach ($k in $obj.Keys) { $o[$k] = $obj[$k] }
    # AppendAllText + UTF8-no-BOM: deterministic bytes regardless of PS version
    # (Add-Content -Encoding UTF8 emits a BOM when it implicitly creates the file).
    [System.IO.File]::AppendAllText($JOURNAL, (($o | ConvertTo-Json -Compress -Depth 10)) + [Environment]::NewLine, $script:Utf8NoBom)
}
function Load-Packet([string]$id, [string]$what) {
    if (-not (Test-ValidId $id)) { Die 1 "${what}: invalid id '$id' (allowed: A-Za-z0-9._-)" }
    $p = Join-Path $PACKETS_DIR "$id.execution.json"
    if (-not (Test-Path -LiteralPath $p)) { Die 2 "${what}: packet '$id' not found at $p" }
    # memory boundary: a hand-edited/garbage execution.json must never be
    # slurped unbounded (behavioural twin of the .sh load_packet_file guard).
    if ((Get-Item -LiteralPath $p).Length -gt $MAX_JSON_BYTES) { Die 2 "${what}: execution.json for '$id' exceeds $MAX_JSON_BYTES bytes; refusing unbounded read." }
    # corrupt / mangled execution.json is a runtime-state problem -> exit 2
    # (behavioural twin: the .sh dies 2 when json_get cannot read state/id).
    # -Encoding UTF8: these files are written UTF-8 without BOM; PS5.1 would
    # otherwise decode them with the ANSI code page (GBK etc.) and mojibake
    # any non-ASCII value on read.
    try { $obj = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | ConvertFrom-Json } catch { Die 2 "${what}: corrupt json for '$id'" }
    if (-not $obj -or -not (Get-Field $obj 'id')) { Die 2 "${what}: packet '$id' corrupt: id missing" }
    return $obj
}
function Save-Packet($packet,[string]$id) {
    # atomic write: RANDOM temp + move -> never a torn execution.json, and no
    # predictable temp name for a symlink-planting attacker to pre-create.
    $p   = Join-Path $PACKETS_DIR "$id.execution.json"
    $tmp = "$p.tmp.$(New-RandomTag)"
    Write-TextNoBom $tmp ($packet | ConvertTo-Json -Depth 30)
    Move-Item -LiteralPath $tmp -Destination $p -Force
}
function Set-PacketProp($packet,[string]$name,$value) {
    $packet | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
}
function Field([object]$v) {
    # scalar | array -> newline-joined text (behavioural twin of the .sh extract)
    if ($null -eq $v) { return '' }
    if ($v -is [System.Array]) { return (@($v) | ForEach-Object { [string]$_ }) -join "`n" }
    return [string]$v
}
function Get-Field($obj,[string]$name) {
    # StrictMode-safe property read: packets may be hand-edited or truncated,
    # and Set-StrictMode -Version Latest turns missing properties into errors.
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# ---------------- per-packet dispatch lock (atomic CreateNew) ----------------
function Acquire-Lock([string]$id) {
    if (-not (Test-ValidId $id)) { Die 1 "lock: invalid id '$id' (allowed: A-Za-z0-9._-)" }
    $lock = Join-Path $STATE_DIR ("lock-" + $id + ".json")
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew,
                                         [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $bytes = [Text.Encoding]::UTF8.GetBytes(('{"pid":' + $PID + ',"created":"' + (Get-Now) + '"}'))
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Dispose()
            $script:OwnedLock = $lock
            return $true
        } catch [System.IO.IOException] {
            # lock file already exists -> stale check below
        }
        if (Test-Path -LiteralPath $lock) {
            $age = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $lock).LastWriteTimeUtc).TotalSeconds
            # Reclaim a lock whose recorded owner process is gone, even if it is
            # younger than LOCK_STALE_SECONDS: a hard-killed dispatch (e.g. a
            # user Stop, or a crash) otherwise blocks re-dispatch for up to an
            # hour. If the lock cannot be read or has no pid, fall back to the
            # age-based rule and never steal what we cannot verify is dead.
            $ownerGone = $false
            try {
                $raw = [System.IO.File]::ReadAllText($lock)
                $m = [regex]::Match($raw, '"pid"\s*:\s*(\d+)')
                if ($m.Success) {
                    $ownerPid = [int]$m.Groups[1].Value
                    if ($ownerPid -gt 0) {
                        try { $null = [System.Diagnostics.Process]::GetProcessById($ownerPid) }
                        catch { $ownerGone = $true }
                    } else { $ownerGone = $true }
                }
            } catch { $ownerGone = $false }   # unreadable / locked -> aged out only
            if ($ownerGone -or $age -gt $LOCK_STALE_SECONDS) {
                try {
                    Remove-Item -LiteralPath $lock -Force -ErrorAction Stop
                    Write-Err ("dispatch: removed stale lock for '" + $id + "' (owner-gone=" + $ownerGone + ", " + [int]$age + "s old); retrying")
                    continue
                } catch { return $false }   # someone else reclaimed it first
            }
        }
        return $false
    }
    return $false
}
function Release-Lock {
    if ($script:OwnedLock -and (Test-Path -LiteralPath $script:OwnedLock)) {
        Remove-Item -LiteralPath $script:OwnedLock -Force -ErrorAction SilentlyContinue
    }
    $script:OwnedLock = $null
}

# ---------------- child process plumbing ----------------
function Quote-Crt([string]$s) {
    # Quote one argv element with MSVCRT rules so CreateProcess receives it verbatim.
    if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backs = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '\') { $backs++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\' * ($backs * 2 + 1)); [void]$sb.Append('"'); $backs = 0
        } else {
            if ($backs -gt 0) { [void]$sb.Append('\' * $backs); $backs = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backs -gt 0) { [void]$sb.Append('\' * ($backs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function Invoke-Run([string]$cmd,[string[]]$argArray,[int]$timeoutSec) {
    # Overflow guard: WaitForExit takes milliseconds, so timeoutSec * 1000
    # must stay inside [int] range (2,147,483 s). Callers cap at 86 400 s,
    # but this helper must stay safe on its own.
    if ($timeoutSec -gt 2147483) { throw "timeout too large: $timeoutSec s" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd
    $psi.Arguments = (($argArray | ForEach-Object { Quote-Crt $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    # codex exec reads extra input from stdin and waits for EOF; without EOF it
    # hangs forever. Redirect stdin and close it so the prompt (an argv element)
    # is the only input and the call returns promptly. (twin of the .sh < /dev/null)
    $psi.RedirectStandardInput  = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    # close stdin immediately -> EOF; the child must not block waiting on us
    try { $proc.StandardInput.Close() } catch {}
    # async drain: prevents the classic deadlock when the child fills one pipe
    # while the parent blocks reading the other.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    # Inactivity watchdog, NOT a wall-clock kill. codex exec buffers its stdout
    # (the redirected pipe/file stays 0 bytes until the process exits), so output
    # growth is useless as a liveness signal. Its CPU time advances steadily while
    # the model generates, so THAT is the reliable "still alive and working"
    # indicator. A healthy 30-minute audit is never cut mid-stream: we only declare
    # a stall when the process makes NO CPU progress for $timeoutSec consecutive
    # seconds (a genuine hang / deadlock). Completion is ONLY the process exiting
    # and returning its data.
    $stall = $false
    $prevCpu = [TimeSpan]::MinValue
    $lastProgress = [DateTime]::UtcNow
    while (-not $proc.HasExited) {
        $curCpu = [TimeSpan]::MinValue
        try { $proc.Refresh(); $curCpu = $proc.TotalProcessorTime } catch {}
        if ($curCpu -gt $prevCpu) {
            $prevCpu = $curCpu
            $lastProgress = [DateTime]::UtcNow
        } elseif (([DateTime]::UtcNow - $lastProgress).TotalSeconds -ge $timeoutSec) {
            $stall = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if ($stall -or (-not $proc.HasExited)) {
        # Kill the whole tree (codex may spawn children); /T covers the process group.
        try {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($proc.Id) /T /F" -WindowStyle Hidden -Wait
        } catch {}
        if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
        try { $proc.WaitForExit(5000) | Out-Null } catch {}
        throw "codex exec stalled (no CPU progress for $timeoutSec s): $cmd"
    }
    $stdout = if ($outTask.Wait(3000)) { $outTask.Result } else { '' }
    $stderr = if ($errTask.Wait(3000)) { $errTask.Result } else { '' }
    return [pscustomobject]@{ exit=$proc.ExitCode; stdout=$stdout; stderr=$stderr }
}

function Invoke-WebRun([string]$cmd,[string[]]$argArray,[int]$timeoutSec) {
    # Wall-clock wrapper for interactive browser automation (chatgpt-web).
    # Unlike codex exec (CPU-bound), the python driver deliberately SLEEPS
    # while waiting on the browser; a CPU-inactivity watchdog (Invoke-Run)
    # would falsely declare a healthy idle wait a stall and kill the run.
    # Here the only bound is a hard wall-clock timeout, after which the whole
    # tree is killed. Twin of the .sh chatgpt-web wall-clock watchdog.
    if ($timeoutSec -gt 2147483) { throw "timeout too large: $timeoutSec s" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd
    $psi.Arguments = (($argArray | ForEach-Object { Quote-Crt $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    try { $proc.StandardInput.Close() } catch {}
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($timeoutSec * 1000)) {
        # Kill the whole tree (the driver and the browser it spawned).
        try {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($proc.Id) /T /F" -WindowStyle Hidden -Wait
        } catch {}
        if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
        try { $proc.WaitForExit(5000) | Out-Null } catch {}
        throw "chatgpt-web did not finish within $timeoutSec s; the run was killed."
    }
    $stdout = if ($outTask.Wait(3000)) { $outTask.Result } else { '' }
    $stderr = if ($errTask.Wait(3000)) { $errTask.Result } else { '' }
    return [pscustomobject]@{ exit=$proc.ExitCode; stdout=$stdout; stderr=$stderr }
}

function Get-CodexPathCandidates {
    # Every `codex` application reachable from PATH. Get-Command is the primary
    # source; the manual directory probe is the fallback for a host whose
    # PATHEXT has been trimmed (a shell that only knows .CPL would otherwise
    # report "codex not on PATH" while codex.cmd sits right there on PATH).
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(Get-Command -Name codex -All -CommandType Application -ErrorAction SilentlyContinue)) {
        foreach ($pn in 'Source','Path','Definition') {
            try { $v = $c.$pn; if ($v) { $list.Add([string]$v); break } } catch {}
        }
    }
    foreach ($dir in @([string]$env:PATH -split ';')) {
        $d = $dir.Trim().Trim('"')
        if (-not $d) { continue }
        foreach ($ext in '.exe','.cmd','.bat','.com') {
            $p = Join-Path $d ('codex' + $ext)
            if (Test-Path -LiteralPath $p -PathType Leaf) { $list.Add($p) }
        }
    }
    # Plain `return $list` (NOT `,$list`): the caller wraps the call in @(), and a
    # nested single-element array would make every candidate coerce to a
    # space-joined string, silently breaking both the .exe test and the shim
    # resolution. Emitting the elements keeps the result a flat string array.
    return $list
}

function Get-NativeCodexFromShim([string]$shimPath) {
    # A .cmd/.bat/.ps1 `codex` is a LAUNCHER, not the CLI. The npm/pnpm
    # @openai/codex shim ends up exec'ing the native binary at
    #   <pkg>\node_modules\@openai\codex-win32-<arch>\vendor\<triple>\bin\codex.exe
    # (npm) or <pkg>\vendor\<triple>\bin\codex.exe (pnpm). Recover THAT file so
    # the payload reaches a real .exe and is never re-parsed by cmd.exe
    # (BatBadBut). Returns $null when nothing native can be PROVEN to exist --
    # the caller then refuses loudly instead of running the shim.
    if (-not $shimPath -or -not (Test-Path -LiteralPath $shimPath -PathType Leaf)) { return $null }
    $triple = if ([string]$env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'aarch64-pc-windows-msvc' }
              else { 'x86_64-pc-windows-msvc' }
    $shimDir = Split-Path -Parent $shimPath
    $roots = New-Object System.Collections.Generic.List[string]
    # (a) npm-global layout: the package sits next to the shim itself
    if ($shimDir) { $roots.Add((Join-Path $shimDir 'node_modules\@openai\codex')) }
    # (b) whatever entrypoint the shim names (codex.js) -> its package root
    try {
        $text = [System.IO.File]::ReadAllText($shimPath)
        foreach ($m in [regex]::Matches($text, '(?i)[^\s"'']*codex\.js')) {
            $js = $m.Value
            if ($shimDir) {
                # %~dp0 / %dp0% expand to the shim's own directory
                $js = $js.Replace('%~dp0', $shimDir).Replace('%dp0%', $shimDir).Replace('%dp0', $shimDir)
                if ($js -notmatch '^[A-Za-z]:' -and $js -notmatch '^\\\\') { $js = Join-Path $shimDir $js }
            }
            try { $js = [System.IO.Path]::GetFullPath($js) } catch { continue }
            $jsDir = Split-Path -Parent $js
            if (-not $jsDir) { continue }
            $roots.Add($(if ((Split-Path -Leaf $jsDir) -ieq 'bin') { Split-Path -Parent $jsDir } else { $jsDir }))
        }
    } catch {}
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $cands = New-Object System.Collections.Generic.List[string]
        $cands.Add((Join-Path $root ("vendor\" + $triple + "\bin\codex.exe")))
        $nm = Join-Path $root 'node_modules\@openai'
        if (Test-Path -LiteralPath $nm -PathType Container) {
            foreach ($d in @(Get-ChildItem -LiteralPath $nm -Directory -Filter 'codex-win32-*' -ErrorAction SilentlyContinue)) {
                $cands.Add((Join-Path $d.FullName ("vendor\" + $triple + "\bin\codex.exe")))
            }
        }
        foreach ($c in $cands) {
            if (Test-Path -LiteralPath $c -PathType Leaf) {
                try { return (Resolve-Path -LiteralPath $c).Path } catch { return $c }
            }
        }
    }
    return $null
}

function Resolve-CodexCommand {
    # Only a native .exe may receive the payload: a .cmd/.bat shim re-parses the
    # whole command line through cmd.exe (BatBadBut), so a payload containing
    # quotes could break out of its argument slot. This guard is SATISFIED,
    # never bypassed -- when `codex` on PATH is only a shim, the native CLI the
    # shim would launch is resolved and used directly; when no native binary can
    # be proven to exist, dispatch refuses (exit 2) rather than silently running
    # a shim. ASTRA_LUNA_CODEX_BIN pins the CLI explicitly and is held to the
    # same rule (a pinned shim is resolved, never executed).
    if ($env:ASTRA_LUNA_CODEX_BIN) {
        $pin = [string]$env:ASTRA_LUNA_CODEX_BIN
        if (-not (Test-Path -LiteralPath $pin -PathType Leaf)) {
            Die 2 "dispatch: local-worker: ASTRA_LUNA_CODEX_BIN not found: $pin"
        }
        if ([System.IO.Path]::GetExtension($pin) -eq '.exe') { return $pin }
        $native = Get-NativeCodexFromShim $pin
        if ($native) {
            # Never a silent substitution: a shim pinned via
            # ASTRA_LUNA_CODEX_BIN is resolved to the native codex.exe behind
            # it, never executed. Name the shim and what it resolved to
            # (twin of the PATH-resolution branch below).
            Write-Err ("dispatch: local-worker: ASTRA_LUNA_CODEX_BIN pins the shim '" + $pin + "'; resolved native codex.exe -> " + $native)
            return $native
        }
        Die 2 ("dispatch: local-worker: ASTRA_LUNA_CODEX_BIN='" + $pin + "' is not a native .exe and no native codex.exe exists behind it; " +
               "point it at codex.exe (passing payload text through cmd.exe would be unsafe: BatBadBut).")
    }
    $cands = @(Get-CodexPathCandidates)
    if ($cands.Count -eq 0) { Die 2 'dispatch: local-worker: `codex` not on PATH; enable Codex CLI or use web-manual' }
    foreach ($c in $cands) {
        if ([System.IO.Path]::GetExtension($c) -eq '.exe') { return $c }
    }
    foreach ($c in $cands) {
        $native = Get-NativeCodexFromShim $c
        if ($native) {
            # Never a silent substitution: name the shim and what it resolved to.
            Write-Err ("dispatch: local-worker: `codex` is the shim '" + $c + "'; resolved native codex.exe -> " + $native)
            return $native
        }
    }
    Die 2 ("dispatch: local-worker: codex resolves to a shim script '" + [string]$cands[0] + "' and no native codex.exe could be resolved behind it; " +
           "install the native codex.exe (or point ASTRA_LUNA_CODEX_BIN at codex.exe); passing payload text through cmd.exe would be unsafe (BatBadBut).")
}

function Find-CodexCli {
    # Soft resolver for the doctor config probe (read-only `login status`).
    # ASTRA_LUNA_CODEX_BIN wins (pinned CLI / non-PATH installs / tests), then
    # any `codex` application on PATH. Unlike Resolve-CodexCommand this MAY
    # return a .cmd shim: the probe passes only fixed arguments, so the
    # BatBadBut re-parsing hazard does not apply; dispatch still requires a
    # native .exe.
    if ($env:ASTRA_LUNA_CODEX_BIN) {
        if (Test-Path -LiteralPath $env:ASTRA_LUNA_CODEX_BIN -PathType Leaf) { return $env:ASTRA_LUNA_CODEX_BIN }
        return $null
    }
    $cands = @(Get-Command -Name codex -All -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($c in $cands) {
        $src = $null
        foreach ($pn in 'Source','Path','Definition') {
            try { $v = $c.$pn; if ($v) { $src = [string]$v; break } } catch {}
        }
        if ($src) { return $src }
    }
    return $null
}

function Get-PythonCommand {
    # Soft resolver for the chatgpt-web transport. ASTRA_LUNA_PYTHON wins
    # (pinned interpreter / tests), then `python` on PATH, then `python3`,
    # then the `py` launcher (common Windows-only setup: the Store python is
    # on PATH but python.exe is not, while C:\Windows\py.exe is).
    if ($env:ASTRA_LUNA_PYTHON) {
        if (Test-Path -LiteralPath $env:ASTRA_LUNA_PYTHON -PathType Leaf) { return $env:ASTRA_LUNA_PYTHON }
        return $null
    }
    foreach ($name in 'python','python3','py') {
        $c = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $c) {
            foreach ($pn in 'Source','Path','Definition') {
                try { $v = $c.$pn; if ($v) { return [string]$v } } catch {}
            }
        }
    }
    return $null
}

function Find-ChatGPTWebScript {
    # Explicitly pinned script wins (tests / installs outside the plugin);
    # otherwise the launcher's sibling scripts\chatgpt-web.py.
    if ($env:ASTRA_LUNA_CHATGPT_BIN) {
        if (Test-Path -LiteralPath $env:ASTRA_LUNA_CHATGPT_BIN -PathType Leaf) { return $env:ASTRA_LUNA_CHATGPT_BIN }
        return $null
    }
    $p = Join-Path $PLUGIN_DIR 'scripts\chatgpt-web.py'
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    return $null
}

# chatgpt-web doctor/environment probe: python + playwright import + browser
# executable + script + profile existence. Kept offline: it NEVER opens a
# browser or touches the network, so doctor stays fast and side-effect free.
function Test-ChatGPTWebEnv {
    $py   = Get-PythonCommand
    $script = Find-ChatGPTWebScript
    $profile = if ($env:ASTRA_LUNA_CHATGPT_PROFILE) { $env:ASTRA_LUNA_CHATGPT_PROFILE }
               else { Join-Path $STATE_DIR 'chatgpt-web-profile' }
    $hasPy = $null -ne $py
    $pw = $false; $pwVer = ''
    $browserPath = ''
    if ($env:ASTRA_LUNA_CHATGPT_BROWSER) {
        if (Test-Path -LiteralPath $env:ASTRA_LUNA_CHATGPT_BROWSER -PathType Leaf) { $browserPath = $env:ASTRA_LUNA_CHATGPT_BROWSER }
    } else {
        # Null-safe candidate paths: a missing ProgramFiles(x86)/LOCALAPPDATA
        # must not abort doctor (Join-Path rejects a null parent).
        $cands = New-Object System.Collections.Generic.List[string]
        $pairs = @(
            @($env:ProgramFiles, 'Tencent\QQBrowser\QQBrowser.exe'),
            @(${env:ProgramFiles(x86)}, 'Tencent\QQBrowser\QQBrowser.exe'),
            @($env:LOCALAPPDATA, 'Tencent\QQBrowser\QQBrowser.exe'),
            @(${env:ProgramFiles(x86)}, 'Microsoft\Edge\Application\msedge.exe'),
            @($env:ProgramFiles, 'Microsoft\Edge\Application\msedge.exe'),
            @($env:LOCALAPPDATA, 'Microsoft\Edge\Application\msedge.exe'),
            @($env:ProgramFiles, 'Google\Chrome\Application\chrome.exe')
        )
        foreach ($pair in $pairs) {
            $parent = [string]$pair[0]
            if (-not $parent) { continue }
            $cands.Add((Join-Path $parent $pair[1]))
        }
        foreach ($cand in $cands) {
            if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) { $browserPath = $cand; break }
        }
    }
    if ($hasPy) {
        try {
            $probe = Invoke-Run $py @('-c','import playwright,sys;print("ok")') 30
            $pw = ($probe.exit -eq 0) -and ($probe.stdout -match 'ok')
            if (-not $pw) { $pwVer = ([string]$probe.stderr).Trim() }
        } catch { $pw = $false; $pwVer = 'probe failed' }
    }
    return [ordered]@{
        python = $(if ($py) { $py } else { '' })
        python_ok = $hasPy
        playwright = $pw
        playwright_error = $pwVer
        browser = $browserPath
        browser_ok = ($browserPath.Length -gt 0)
        script = $(if ($script) { $script } else { '' })
        script_ok = ($null -ne $script)
        profile = $profile
        profile_exists = (Test-Path -LiteralPath $profile -PathType Container)
        ok = ($hasPy -and $pw -and ($browserPath.Length -gt 0) -and ($null -ne $script))
    }
}

# ---------------- doctor ----------------
function Cmd-Doctor {
    Ensure-Dirs
    $agentsDir = Get-AgentsDir
    $primaryToml = Get-PrimaryAgentToml
    $hasToml = Test-Path -LiteralPath $primaryToml
    $agentsInstalled = 0
    if (Test-Path -LiteralPath $agentsDir) {
        $agentsInstalled = @(Get-ChildItem -LiteralPath $agentsDir -Filter 'astra-*.toml' -ErrorAction SilentlyContinue).Count
    }
    $model=$LUNA_MODEL; $effort=$LUNA_EFFORT
    if ($hasToml) {
        try {
            $c = [System.IO.File]::ReadAllText($primaryToml)
            $m=[regex]::Match($c,'(?im)^\s*model\s*=\s*"([^"]+)"'); if($m.Success){$model=$m.Groups[1].Value}
            $e=[regex]::Match($c,'(?im)^\s*model_reasoning_effort\s*=\s*"([^"]+)"'); if($e.Success){$effort=$e.Groups[1].Value}
        } catch {}
    }
    $cfgPath = Join-Path (Get-CodexDir) 'config.toml'
    $ask=$false; $cfgModel=''; $cfgEffort=''
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = [System.IO.File]::ReadAllText($cfgPath)
            $ask = ($cfg -match 'default_mode_request_user_input\s*=\s*true')
            # advisory only: report what the orchestrator is actually set to so a
            # session still running a non-Astra model is visible in the verdict.
            $cm=[regex]::Match($cfg,'(?im)^\s*model\s*=\s*"([^"]+)"'); if($cm.Success){$cfgModel=$cm.Groups[1].Value}
            $ce=[regex]::Match($cfg,'(?im)^\s*model_reasoning_effort\s*=\s*"([^"]+)"'); if($ce.Success){$cfgEffort=$ce.Groups[1].Value}
        } catch {}
    }
    # codex CLI config-load probe (read-only): the #1 silent killer of the
    # local-worker transport is a config.toml the CLI cannot parse - it fails
    # with exit 1 ("invalid type: ...", e.g. a nested [features.*] table)
    # BEFORE any model call, while the desktop app itself keeps running, so
    # doctor must ask the CLI itself. `codex login status` loads the full
    # config and never calls the model; "Not logged in" (exit 1) is an AUTH
    # state, not a config failure, and must not be reported as one.
    $codexCli = Find-CodexCli
    $hasCli = $null -ne $codexCli
    $cliCfgOk = $true
    $cliCfgErr = ''
    if ($hasCli) {
        try {
            $probe = Invoke-Run $codexCli @('login','status') 30
            $probeText = [string]$probe.stdout + "`n" + [string]$probe.stderr
            if ($probeText -match 'Error loading configuration|invalid type|failed to load config') {
                $cliCfgOk = $false
                $errLine = @($probeText -split "`r?`n" | Where-Object { $_ -match 'Error loading configuration|invalid type|failed to load config' } | Select-Object -First 1)
                if ($errLine.Count -gt 0) { $cliCfgErr = ([string]$errLine[0]).Trim() }
                if ($cliCfgErr.Length -gt 240) { $cliCfgErr = $cliCfgErr.Substring(0,240) + '...' }
            }
        } catch {
            # probe could not even spawn (AV / policy): keep going, but make
            # the limitation visible in the verdict instead of guessing.
            $cliCfgErr = 'probe failed to run: ' + $_.Exception.Message
        }
    }
    # local_worker availability = agent TOML present AND a codex CLI that can
    # actually load its config. Hashing is pure .NET; codex.exe is resolved at
    # dispatch time and reported loudly if missing (no silent degradation).
    $localWorker = ($hasToml -and $hasCli -and $cliCfgOk)

    $cw = Test-ChatGPTWebEnv
    $diy = Read-DiyConfig
    $diyTransportOk = $false
    $diyPy = Get-OpenAiDiyScript
    $pythonOk = $false
    try { $pythonOk = $null -ne (Get-PythonCommand) } catch { $pythonOk = $false }
    $diyTransportOk = ($diy.ready -and $pythonOk -and ($null -ne $diyPy))
    $workerModel = $LUNA_MODEL
    $workerEffort = $LUNA_EFFORT
    if (Test-DiyReplacesLuna) {
        $workerModel = $diy.model
        $workerEffort = 'diy:' + $diy.temperature
    }

    $verdict = [ordered]@{
        os = 'windows'
        plugin = 'astra-luna-command-center'
        plugin_dir = $PLUGIN_DIR
        state_dir = $STATE_DIR
        size_limit_bytes = $DEFAULT_MAX_PAYLOAD_BYTES
        astra_model = $ASTRA_MODEL
        astra_effort = $ASTRA_EFFORT
        config_model = $cfgModel
        config_effort = $cfgEffort
        transports = [ordered]@{ web_manual=$true; local_worker=$localWorker; chatgpt_web=$cw.ok; diy_openai=$diyTransportOk }
        agent_toml = $hasToml
        agent_dir = $agentsDir
        agents_installed = $agentsInstalled
        agent_path = $primaryToml
        luna_model = $model
        luna_effort = $effort
        worker_model = $workerModel
        worker_route = $(if (Test-DiyReplacesLuna) { 'diy-openai' } else { 'local-worker/gpt-5.6-luna' })
        diy = [ordered]@{
            enabled = $diy.enabled
            ready = $diy.ready
            replace_luna = $diy.replace_luna
            base_url = $diy.base_url
            model = $diy.model
            has_api_key = $diy.has_api_key
            api_key_from_env = $diy.api_key_env
            config_path = $diy.path
            config_exists = $diy.exists
            python_ok = $pythonOk
            client_ok = ($null -ne $diyPy)
            transport_ok = $diyTransportOk
            parse_error = $diy.parse_error
        }
        config_toml = (Test-Path -LiteralPath $cfgPath)
        codex_cli = $hasCli
        codex_cli_path = $(if ($codexCli) { $codexCli } else { '' })
        codex_cli_config = $cliCfgOk
        codex_cli_error = $cliCfgErr
        request_user_input = $ask
        chatgpt_web = $cw
        probe = 'chatgpt-web: environment report above; run `python chatgpt-web.py status` (or `... login` for first-time auth) to confirm the ChatGPT browser login state. local-worker: verify the model round-trip works (model answers a known-answer question correctly). The gpt-5.6-* tiers run on a gpt-5 base, so a gpt-5/GPT-5 self-identification is expected and still counts for the gpt-5.6-luna + max route; do not gate dispatch on an exact slug. diy-openai: run `astra-luna.ps1 diy-test` then `diy-models` against your OpenAI-compatible provider; Astra still reviews results. web-manual is verified by the user selecting GPT-5.6 Luna Max in the ChatGPT UI - no local probe required.'
    }
    Write-Output ($verdict | ConvertTo-Json -Depth 8)
    if (-not $hasToml) {
        # First-run guard: surface the exact copy-pasteable fix so the missing
        # step (init) cannot be skipped. The JSON verdict above already tells
        # the caller it's missing; this makes the remedy explicit and honours
        # CODEX_HOME (doctor and init both read it from the env), so the same
        # command provisions the agents even with a custom home.
        $ps1Path = Join-Path $PLUGIN_DIR 'scripts\astra-luna.ps1'
        $q = '"' + ($ps1Path -replace '"', '\"') + '"'
        Write-Err ''
        Write-Err 'doctor: missing astra_worker agent - the plugin is installed but NOT initialized.'
        Write-Err ("  expected agent file: {0}" -f $primaryToml)
        Write-Err '  consequence: the local-worker transport is unavailable and Luna model/effort probes cannot run.'
        Write-Err '  fix (copy/paste, then re-run doctor):'
        Write-Err ("    powershell -NoProfile -ExecutionPolicy Bypass -File {0} init" -f $q)
        Write-Err ''
        $script:EXIT=2; return
    }
    if ($hasCli -and -not $cliCfgOk) {
        # Fatal for the primary transport: every local-worker dispatch will
        # exit 1 before reaching the model. Name the usual culprit (nested
        # [features.*] tables) with the exact offending lines.
        Write-Err ''
        Write-Err 'doctor: the codex CLI cannot load its configuration - EVERY `codex exec` dispatch fails (exit 1) before reaching the model.'
        Write-Err ("  codex: {0}" -f $codexCli)
        Write-Err ("  error: {0}" -f $cliCfgErr)
        try {
            $badLines = @(Select-String -LiteralPath $cfgPath -Pattern '^\s*\[features\.[^\]]+\]' -ErrorAction SilentlyContinue)
            foreach ($bl in $badLines) {
                Write-Err ("  offending line {0}: {1}" -f $bl.LineNumber, $bl.Line.Trim())
            }
        } catch {}
        Write-Err '  fix: edit ~/.codex/config.toml so every [features] value is a boolean - remove or flatten nested [features.*] tables (keep a backup).'
        Write-Err '       The desktop app tolerates the nested table; the codex CLI does not. Re-run doctor afterwards.'
        Write-Err ''
        $script:EXIT=2; return
    }
    $script:EXIT=0
}

# ---------------- init ----------------
function Cmd-Init {
    Ensure-Dirs
    New-Item -ItemType Directory -Force -Path (Get-AgentsDir) | Out-Null
    $changed = $false
    # Install every luna role agent (explorer/worker/tester/reviewer/researcher).
    # Existing files are preserved, never overwritten: this plugin coexists
    # with the old sol-luna plugin and with any hand-edited agent config.
    $srcAgents = @(Get-ChildItem -LiteralPath (Join-Path $PLUGIN_DIR 'agents') -Filter '*.toml' -ErrorAction SilentlyContinue |
                   Sort-Object Name)
    if ($srcAgents.Count -eq 0) { Die 2 'init: no agent TOMLs found in the plugin agents/ directory' }
    foreach ($src in $srcAgents) {
        $dst = Join-Path (Get-AgentsDir) $src.Name
        if (Test-Path -LiteralPath $dst) {
            Write-Output "init: existing agent preserved: $dst"
        } else {
            Copy-Item -LiteralPath $src.FullName -Destination $dst
            Write-Output "init: wrote $dst"
            $changed = $true
        }
    }
    $srcSkill = Join-Path $PLUGIN_DIR 'skills\astra-command-center'
    $dstSkill = Get-SkillDst
    $skillExisted = Test-Path -LiteralPath $dstSkill
    New-Item -ItemType Directory -Force -Path $dstSkill | Out-Null
    # SKILL.md is plugin-owned: refresh on every init so skill updates
    # propagate (agent TOMLs above stay preserve-if-present; SKILL.md is not
    # user-edited state).
    Copy-Item -LiteralPath (Join-Path $srcSkill 'SKILL.md') -Destination (Join-Path $dstSkill 'SKILL.md') -Force
    # astra-diy skill (OpenAI-compatible custom worker / /astra-Diy)
    $srcDiySkill = Join-Path $PLUGIN_DIR 'skills\astra-diy'
    $dstDiySkill = Join-Path (Get-CodexDir) 'skills\astra-diy'
    if (Test-Path -LiteralPath $srcDiySkill) {
        New-Item -ItemType Directory -Force -Path $dstDiySkill | Out-Null
        if (Test-Path -LiteralPath (Join-Path $srcDiySkill 'SKILL.md')) {
            Copy-Item -LiteralPath (Join-Path $srcDiySkill 'SKILL.md') -Destination (Join-Path $dstDiySkill 'SKILL.md') -Force
            Write-Output "init: installed/refreshed skill -> $dstDiySkill"
        }
    }
    # commands/astra-Diy.md is loaded from the plugin package by Codex; also
    # copy into CODEX_HOME skills area docs for discoverability is NOT required.
    # Clone the launcher runtime next to SKILL.md. The installed skill copy is
    # invoked with CWD = skill dir, so its documented launcher path
    # ('.\scripts\astra-luna.ps1') must exist HERE - not two levels up in the
    # plugin checkout (the old copy-if-absent skill install left the copy
    # referencing a launcher that did not exist anywhere).
    foreach ($d in 'scripts','agents','templates','config') {
        $srcDir = Join-Path $PLUGIN_DIR $d
        if (-not (Test-Path -LiteralPath $srcDir)) { continue }
        $dstDir = Join-Path $dstSkill $d
        if ([System.IO.Path]::GetFullPath($srcDir) -eq [System.IO.Path]::GetFullPath($dstDir)) { continue }  # init from the clone itself
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        Get-ChildItem -LiteralPath $srcDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dstDir $_.Name) -Force
        }
    }
    if ($skillExisted) {
        Write-Output "init: skill runtime refreshed -> $dstSkill"
    } else {
        Write-Output "init: installed skill (with launcher runtime) -> $dstSkill"
        $changed=$true
    }
    $agentsPath = Get-AgentsMd
    if (-not (Test-Path -LiteralPath $agentsPath)) { Write-TextNoBom $agentsPath '' }
    # -Encoding UTF8: AGENTS.md is UTF-8 (BOM-less); PS5.1's ANSI default would
    # mojibake existing non-ASCII rules and write the corruption back.
    $agentsText = [string](Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8)
    if ($null -eq $agentsText) { $agentsText = '' }
    if ($agentsText -match [regex]::Escape($MD_BEGIN)) {
        Write-Output 'init: AGENTS.md already carries astra-luna rules'
    } else {
        $block = [System.IO.File]::ReadAllText((Join-Path $PLUGIN_DIR 'templates\AGENTS.md')).Trim()
        $sep = if ($agentsText.Trim().Length -gt 0) { "`r`n`r`n" } else { '' }
        Write-TextNoBom $agentsPath ($agentsText + $sep + $block + "`r`n")
        Write-Output "init: merged rules into $agentsPath"
    }
    Write-Output ('init: config.toml is never auto-edited. Apply config/config.toml.example yourself (model = "' + $ASTRA_MODEL + '", model_reasoning_effort = "' + $ASTRA_EFFORT + '", [agents] default_subagent_model = "' + $LUNA_MODEL + '", default_subagent_reasoning_effort = "' + $LUNA_EFFORT + '").')
    if (-not $changed) { Write-Output 'init: already configured (idempotent)' } else { Write-Output 'init: done' }
    Journal-Log @{ event='init' }
    $script:EXIT=0
}

# ---------------- new-packet ----------------
function Cmd-NewPacket {
    Ensure-Dirs
    $a = Parse-Args 'new-packet' @('SpecFile')
    $specFile = Get-ArgVal $a 'SpecFile' '' 'new-packet'
    if (-not $specFile) { Die 1 'new-packet: missing -SpecFile <json>' }
    if (-not (Test-Path -LiteralPath $specFile -PathType Leaf)) { Die 1 "new-packet: spec not found: $specFile" }
    # memory boundary: a spec larger than the read cap can never produce a
    # payload within the 12000-byte limit, and must not be slurped unbounded
    # (behavioural twin of the .sh guard).
    if ((Get-Item -LiteralPath $specFile).Length -gt $MAX_JSON_BYTES) { Die 1 "new-packet: spec too large (max $MAX_JSON_BYTES bytes)" }
    try { $spec = [System.IO.File]::ReadAllText($specFile) | ConvertFrom-Json } catch { Die 1 'new-packet: invalid spec JSON' }
    # a bare 'null' (or otherwise scalar) JSON document parses to $null, not an
    # object; .PSObject would crash under StrictMode. The .sh twin falls
    # through to "spec.goal required" -- both exit 1, cleanly.
    if ($null -eq $spec) { Die 1 'new-packet: invalid spec JSON' }
    # A UTF-8 BOM shifts every byte-scanned key match by one char, so a BOM'd
    # spec would yield empty fields and a bogus "spec.goal required" on the
    # POSIX side. Parse the BOM-stripped copy on both sides so writers stay
    # aligned. (ConvertFrom-Json handles a leading BOM fine; this is for the
    # cross-platform twin, which scans raw bytes.)
    $rawSpec = [System.IO.File]::ReadAllBytes($specFile)
    if ($rawSpec.Length -ge 3 -and $rawSpec[0] -eq 0xEF -and $rawSpec[1] -eq 0xBB -and $rawSpec[2] -eq 0xBF) {
        if ($rawSpec.Length -eq 3) { Die 1 'new-packet: invalid spec JSON' }   # BOM-only document
        $bomlessSpec = Join-Path $PACKETS_DIR ("tmp-spec." + (New-RandomTag) + ".json")
        [System.IO.File]::WriteAllBytes($bomlessSpec, $rawSpec[3..($rawSpec.Length - 1)])
        try {
            try { $spec = [System.IO.File]::ReadAllText($bomlessSpec) | ConvertFrom-Json } catch { Die 1 'new-packet: invalid spec JSON' }
            if ($null -eq $spec) { Die 1 'new-packet: invalid spec JSON' }
        } finally { Remove-Item -LiteralPath $bomlessSpec -Force -ErrorAction SilentlyContinue }
    }

    $goal = ''
    if ($spec.PSObject.Properties['goal']) { $goal = Field $spec.goal }
    if (-not $goal.Trim()) { Die 1 'new-packet: spec.goal required' }

    $S=@{}
    foreach($p in 'symptom','root_cause','scope','inputs','acceptance','constraints','files','evidence'){
        $prop = $spec.PSObject.Properties[$p]
        $S[$p] = if ($null -ne $prop) { Field $prop.Value } else { '' }
    }

    $payload = (@"
# Execution packet (gpt-5.6-luna worker - bounded executor)

## Goal
$goal

## Symptom
$($S['symptom'])

## Root cause (from GPT-6 Astra command center)
$($S['root_cause'])

## Scope (do not exceed)
$($S['scope'])

## Inputs
$($S['inputs'])

## Acceptance criteria
$($S['acceptance'])

## Constraints
$($S['constraints'])

## Relevant files
$($S['files'])

## Evidence
$($S['evidence'])

Return: (1) exact result, (2) files changed/inspected, (3) checks actually run,
(4) verification result, (5) remaining risks.
"@)
    $bytes = [Text.Encoding]::UTF8.GetByteCount($payload)
    if ($bytes -gt $DEFAULT_MAX_PAYLOAD_BYTES) {
        Write-Err "new-packet: payload $bytes bytes > limit $DEFAULT_MAX_PAYLOAD_BYTES; compress spec fields."
        $script:EXIT=2; return
    }
    $id = (Get-Date -Format 'yyyyMMddHHmmss') + '-' + (New-RandomTag).Substring(0,8)
    $payloadPath = Join-Path $PACKETS_DIR "$id.payload.md"
    $payloadTmp  = "$payloadPath.tmp.$(New-RandomTag)"
    Write-TextNoBom $payloadTmp $payload
    Move-Item -LiteralPath $payloadTmp -Destination $payloadPath -Force
    Copy-Item -LiteralPath $specFile (Join-Path $PACKETS_DIR "$id.spec.json") -Force
    $packet = [ordered]@{
        state='new'; id=$id; created_at=(Get-Now)
        model=$LUNA_MODEL; effort=$LUNA_EFFORT; transport=''
        payload_sha256= Get-Sha256File $payloadPath; payload_bytes=$bytes
        # full key set with empty defaults: byte-shape twin of the .sh
        # save_packet, so every execution.json carries all fields
        dispatched_at=''; result_file=''; result_sha256=''; result_bytes=0
        summary_file=''; summary_sha256=''
    }
    Save-Packet $packet $id
    Journal-Log @{ event='new-packet'; id=$id }
    Write-Output "created: $id"
    Write-Output "execution: $(Join-Path $PACKETS_DIR "$id.execution.json")"
    Write-Output "payload:   $payloadPath"
    Write-Output "payload_sha256: $($packet.payload_sha256)"
    Write-Output "payload_bytes: $bytes"
    $script:EXIT=0
}

# ---------------- dispatch ----------------
function Cmd-Dispatch {
    Ensure-Dirs
    $a = Parse-Args 'dispatch' @('Id','Transport','TimeoutSec')
    $id = Get-ArgVal $a 'Id' '' 'dispatch'
    if (-not $id) { Die 1 'dispatch: missing -Id <id>' }
    if (-not (Test-ValidId $id)) { Die 1 "dispatch: invalid id '$id' (allowed: A-Za-z0-9._-)" }
    $transport = Get-ArgVal $a 'Transport' '' 'dispatch'
    if (-not $transport) {
        # Default transport: when astra-Diy is enabled and replace_luna is true,
        # worker execution goes to the custom OpenAI-compatible API instead of
        # gpt-5.6-luna. Explicit -Transport always wins. Never silent: doctor
        # and diy-show report the active worker_route.
        if (Test-DiyReplacesLuna) { $transport = 'diy-openai' }
        else { $transport = 'local-worker' }
    }
    if ($transport -notin @('web-manual','local-worker','chatgpt-web','diy-openai')) {
        Die 1 "dispatch: unknown transport '$transport' (web-manual|local-worker|chatgpt-web|diy-openai)"
    }
    $rawTimeout = Get-ArgVal $a 'TimeoutSec' '900' 'dispatch'
    # ASCII-digits-only twin of the .sh '[!0-9]' guard: '08'/' 5'/'1e3'/'-1'
    # are refused here. Use [0-9], NOT \d -- .NET \d also matches Unicode
    # digits ('٥' would silently parse as 5), which the .sh refuses. '-1'
    # only reaches this check because Parse-Args treats a negative number
    # as a VALUE, not as the next flag.
    if ($rawTimeout -notmatch '^[0-9]+$') { Die 1 'dispatch: -TimeoutSec must be a positive integer' }
    # bound the length before the [int] cast so an absurd value cannot overflow
    if ($rawTimeout.Length -gt 9) { Die 1 "dispatch: -TimeoutSec must be between 1 and $MAX_TIMEOUT_SECONDS" }
    $timeout = [int]$rawTimeout
    if ($timeout -lt 1 -or $timeout -gt $MAX_TIMEOUT_SECONDS) {
        Die 1 "dispatch: -TimeoutSec must be between 1 and $MAX_TIMEOUT_SECONDS"
    }

    $packet = Load-Packet $id 'dispatch'
    $state = [string](Get-Field $packet 'state')
    if (-not $state) { Die 2 "dispatch: cannot read state for '$id'" }
    if ($state -ne 'new') { Die 1 "dispatch: packet '$id' in state '$state'; only new packets dispatch." }

    # per-packet dispatch lock (atomic; stale locks with a dead owner or older
    # than 1h are recovered)
    if (-not (Acquire-Lock $id)) {
        Die 2 "dispatch: '$id' already being dispatched (active or recent lock in $STATE_DIR)"
    }
    try {
        $mdPath = Join-Path $PACKETS_DIR "$id.payload.md"
        if (-not (Test-Path -LiteralPath $mdPath)) { Die 1 "dispatch: payload missing: $mdPath" }
        # memory boundary: refuse the unbounded read before it happens.
        if ((Get-Item -LiteralPath $mdPath).Length -gt $MAX_JSON_BYTES) { Die 2 "dispatch: payload larger than $MAX_JSON_BYTES bytes: $mdPath" }
        # SINGLE-READ binding: read the payload exactly once; the hash below is
        # computed over these bytes and these same bytes are what reach the
        # worker or the web staging file. Re-reading the file after the check
        # (the old pattern) left a swap window in which tampered content could
        # be dispatched under a verified hash.
        $payloadBytes = [System.IO.File]::ReadAllBytes($mdPath)
        $payloadSha = Get-Sha256Bytes $payloadBytes
        $recordedSha = [string](Get-Field $packet 'payload_sha256')
        if (-not $recordedSha) { Die 2 "dispatch: packet '$id' is corrupt: payload_sha256 missing." }
        # Digest-shape guards: an empty/truncated hash must never pass as
        # "" -eq "" (twin of the sh regex refusal). A stored uppercase hash
        # from an older writer is normalized before the compare.
        if (-not (Test-Sha256Shape $recordedSha)) { Die 2 "dispatch: packet '$id' corrupt: malformed payload_sha256" }
        if (-not (Test-Sha256Shape $payloadSha)) { Die 2 "dispatch: bad payload hash for '$id'" }
        if ($payloadSha -ne $recordedSha.ToLowerInvariant()) {
            Journal-Log @{ event='dispatch-refused'; id=$id; transport=$transport; reason='payload-hash-mismatch' }
            Die 3 "dispatch: payload hash mismatch for '$id'; refusing to run degraded."
        }
        $payloadText = [Text.Encoding]::UTF8.GetString($payloadBytes)

        switch ($transport) {
            'local-worker' {
                $codex = Resolve-CodexCommand
                # Explicit -Transport local-worker always keeps the pinned
                # gpt-5.6-luna + max pair (deterministic fallback / tests).
                # The DIY replacement is a separate transport: diy-openai.
                $workerModel = $LUNA_MODEL
                $workerEffort = $LUNA_EFFORT
                # Current codex-cli (>=0.148 alpha): `exec` takes the prompt as a
                # POSITIONAL arg, and the agent's model/effort come from config
                # overrides, NOT the removed `-t <agent>` / `-p <prompt>` flags.
                # We set model + reasoning effort explicitly and fold the
                # astra_worker persona (also shipped in agents/astra-worker.toml)
                # into the prompt.
                $prompt = ("You are the bounded astra_worker execution agent reporting to GPT-6 Astra. " +
                            "Complete only the assigned subtask in the execution packet ($id). " +
                            "Stay strictly in scope and file boundaries. Do not spawn agents or change architecture. " +
                            "Verify when practical. Return a result with: (1) exact result, (2) files changed/inspected, " +
                            "(3) checks run, (4) verification, (5) remaining risks.`n`n" + $payloadText)
                $run = $null
                try {
                    $run = Invoke-Run $codex @('exec','--skip-git-repo-check','--model',$workerModel,'-c',"model_reasoning_effort=`"$workerEffort`"",$prompt) $timeout
                } catch {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='local-worker'; error=[string]$_.Exception.Message }
                    Die 2 "dispatch: local-worker run failed: $_"
                }
                # memory boundary: a runaway worker's stdout is never silently
                # truncated (no silent degradation) -- refuse instead. Measured
                # in UTF-8 BYTES so the cap matches the .sh twin exactly
                # ($run.stdout.Length counts UTF-16 chars, which under-counts).
                if ([Text.Encoding]::UTF8.GetByteCount($run.stdout) -gt $MAX_JSON_BYTES) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='local-worker'; reason='result-oversize' }
                    Die 2 "dispatch: worker result exceeds $MAX_JSON_BYTES bytes"
                }
                if ($run.exit -ne 0) {
                    $errLog = Join-Path $RESULTS_DIR "$id.run-error.log"
                    try { Write-TextNoBom $errLog ($run.stdout + "`n--- stderr ---`n" + $run.stderr) } catch {}
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='local-worker'; exit=$run.exit }
                    Write-Err "dispatch: codex exec exited $($run.exit)"
                    $script:EXIT=2; return
                }
                $res = Join-Path $RESULTS_DIR "$id.result.md"
                Write-TextNoBom $res $run.stdout
                # Set-PacketProp (Add-Member -Force) also tolerates hand-edited
                # packets that lost these keys (StrictMode-safe).
                Set-PacketProp $packet 'state' 'done'
                Set-PacketProp $packet 'transport' 'local-worker'
                Set-PacketProp $packet 'dispatched_at' (Get-Now)
                Set-PacketProp $packet 'result_file' $res
                Set-PacketProp $packet 'result_sha256' (Get-Sha256File $res)
                Set-PacketProp $packet 'result_bytes' ((Get-Item -LiteralPath $res).Length)
                Save-Packet $packet $id
                Journal-Log @{ event='run-done'; id=$id; transport='local-worker'; exit=0 }
                Write-Output "done (local-worker): $res"
                $script:EXIT=0
            }
            'chatgpt-web' {
                # ChatGPT Web 自动化 transport：上层负责模型选择与审批（Astra），
                # 执行子任务经浏览器送到 ChatGPT Web（不消耗 API token），
                # 回复自动写回 result 文件并做 SHA-256 绑定。
                # 绝不静默降级：脚本不可用/未登录/提交失败/超时/提取失败
                # 都以明确错误和退出码 2 结束，packet 保持 state=new 可重试。
                $linkPath = (Join-Path $PLUGIN_DIR 'scripts\chatgpt-web.py')
                $cwScript = $null
                if ($env:ASTRA_LUNA_CHATGPT_BIN) {
                    $cwScript = $env:ASTRA_LUNA_CHATGPT_BIN
                    if (-not (Test-Path -LiteralPath $cwScript -PathType Leaf)) {
                        Journal-Log @{ event='dispatch-failed'; id=$id; transport='chatgpt-web'; reason='script-missing' }
                        Die 2 "dispatch: chatgpt-web: ASTRA_LUNA_CHATGPT_BIN not found: $cwScript"
                    }
                } elseif (Test-Path -LiteralPath $linkPath) { $cwScript = $linkPath }
                if (-not $cwScript) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='chatgpt-web'; reason='script-missing' }
                    Die 2 "dispatch: chatgpt-web: automation script not found: $linkPath (missing install; run init or set ASTRA_LUNA_CHATGPT_BIN)"
                }
                # 解释器：ASTRA_LUNA_PYTHON 优先，其次 PATH 上的 python。
                # 显式钉住的解释器如果失效（文件不存在）就是硬错误——绝不静默
                # 回落到 PATH 上的另一个解释器（与 doctor 判定一致，防静默降级）。
                $py = $null
                if ($env:ASTRA_LUNA_PYTHON) {
                    $py = $env:ASTRA_LUNA_PYTHON
                    if (-not (Test-Path -LiteralPath $py -PathType Leaf)) {
                        Journal-Log @{ event='dispatch-failed'; id=$id; transport='chatgpt-web'; reason='python-pin-broken' }
                        Die 2 ("dispatch: chatgpt-web: ASTRA_LUNA_PYTHON='" + $py + "' not found; no python interpreter is reachable (point it at a real python.exe or unset it and put python on PATH; web-manual is the fallback)")
                    }
                }
                if (-not $py) {
                    foreach ($name in 'python','python3','py') {
                        $c = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($null -ne $c) { $py = [string]$c.Source; break }
                    }
                }
                if (-not $py) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='chatgpt-web'; reason='python-missing' }
                    Die 2 "dispatch: chatgpt-web: python not found; set ASTRA_LUNA_PYTHON or use web-manual"
                }
                $profile = if ($env:ASTRA_LUNA_CHATGPT_PROFILE) { $env:ASTRA_LUNA_CHATGPT_PROFILE }
                           else { Join-Path $STATE_DIR 'chatgpt-web-profile' }
                $res = Join-Path $RESULTS_DIR "$id.result.md"
                $run = $null
                try {
                    $run = Invoke-WebRun $py @($cwScript,'send','--timeout',[string]$timeout,
                        '--profile',$profile,'--payload-file',$mdPath,'--result-file',$res) $timeout
                } catch {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='chatgpt-web'; error=[string]$_ }
                    Die 2 "dispatch: chatgpt-web run failed: $_"
                }
                if ($run.exit -ne 0) {
                    $stub = ([string]$run.stderr).Trim()
                    if ($stub.Length -gt 500) { $stub = $stub.Substring(0,500) + '...' }
                    $why = switch ($run.exit) {
                        2 { 'environment error (python/playwright/browser/payload)' }
                        3 { 'not logged in - run `python chatgpt-web.py login` once, then retry' }
                        4 { 'composer submit failed (page changed?)' }
                        5 { "generation timed out after $timeout s" }
                        6 { 'no assistant reply extracted (page changed?)' }
                        default { "unexpected exit $($run.exit)" }
                    }
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='chatgpt-web'; exit=$run.exit; reason=$why }
                    Write-Err "dispatch: chatgpt-web failed: $why"
                    if ($stub) { Write-Err "  $stub" }
                    $script:EXIT=2; return
                }
                if (-not (Test-Path -LiteralPath $res -PathType Leaf)) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='chatgpt-web'; reason='result-missing' }
                    Die 2 "dispatch: chatgpt-web exited 0 but wrote no result file: $res"
                }
                # 成功：预注册 result 哈希（与 local-worker 同构），state=done。
                Set-PacketProp $packet 'state' 'done'
                Set-PacketProp $packet 'transport' 'chatgpt-web'
                Set-PacketProp $packet 'dispatched_at' (Get-Now)
                Set-PacketProp $packet 'result_file' $res
                Set-PacketProp $packet 'result_sha256' (Get-Sha256File $res)
                Set-PacketProp $packet 'result_bytes' ((Get-Item -LiteralPath $res).Length)
                Save-Packet $packet $id
                Journal-Log @{ event='run-done'; id=$id; transport='chatgpt-web'; exit=0 }
                Write-Output "done (chatgpt-web): $res"
                $script:EXIT=0
            }
            default {
                # web-manual: stage the verified bytes for a human carrier only.
                # Never touches the clipboard (shared boundary; payload may hold
                # sensitive material) and never auto-opens a browser.
                # Staged via RANDOM temp + rename so the final file never appears
                # half-written and no predictable ".part" name can be pre-created
                # by another local user (symlink planting).
                $clip = Join-Path $RESULTS_DIR "$id.to-web.txt"
                $clipPart = "$clip.part.$(New-RandomTag)"
                [System.IO.File]::WriteAllBytes($clipPart, $payloadBytes)
                Move-Item -LiteralPath $clipPart -Destination $clip -Force
                Set-PacketProp $packet 'state' 'done'
                Set-PacketProp $packet 'transport' 'web-manual'
                Set-PacketProp $packet 'dispatched_at' (Get-Now)
                Save-Packet $packet $id
                Journal-Log @{ event='dispatch'; id=$id; transport='web-manual' }
                Write-Output "web-manual staged: $clip"
                Write-Output 'Open chatgpt.com with GPT-5.6 Luna Max selected, paste payload, then save reply to:'
                Write-Output "  $(Join-Path $RESULTS_DIR "$id.web-result.md")"
                $script:EXIT=0
            }
            'diy-openai' {
                # astra-Diy transport: send the hash-bound payload to a
                # user-configured OpenAI-compatible API. This REPLACES the
                # gpt-5.6-luna worker model only. GPT-6 Astra still owns
                # plan/review/summary. Never silently falls back to luna.
                $diy = Read-DiyConfig
                if (-not $diy.exists) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; reason='diy-config-missing' }
                    Die 2 ("dispatch: diy-openai: DIY config missing at $($diy.path). Configure via /astra-Diy or `diy-set` / `diy-settings`.")
                }
                if (-not $diy.enabled) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; reason='diy-disabled' }
                    Die 2 'dispatch: diy-openai: DIY worker is disabled. Enable with diy-set -Enabled true (or /astra-Diy).'
                }
                if (-not $diy.ready) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; reason='diy-incomplete' }
                    Die 3 ("dispatch: diy-openai: DIY config incomplete (need base_url + api_key + model). See diy-show / diy-schema.")
                }
                $diyScript = Get-OpenAiDiyScript
                if (-not $diyScript) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; reason='script-missing' }
                    Die 2 'dispatch: diy-openai: openai-diy.py not found (set ASTRA_DIY_BIN or reinstall the plugin)'
                }
                $py = Get-PythonCommand
                if (-not $py) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; reason='python-missing' }
                    Die 2 'dispatch: diy-openai: python not found; set ASTRA_LUNA_PYTHON or use local-worker/web-manual'
                }
                $res = Join-Path $RESULTS_DIR "$id.result.md"
                $run = $null
                try {
                    # Payload already single-read + hash-verified above; pass the
                    # on-disk path (same bytes) to the client for the HTTP body.
                    $run = Invoke-Run $py @($diyScript,'run','--payload',$mdPath,'--output',$res,'--packet-id',$id) $timeout
                } catch {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; error=[string]$_.Exception.Message }
                    Die 2 "dispatch: diy-openai run failed: $_"
                }
                if ($run.exit -ne 0) {
                    $errLog = Join-Path $RESULTS_DIR "$id.run-error.log"
                    try { Write-TextNoBom $errLog ($run.stdout + "`n--- stderr ---`n" + $run.stderr) } catch {}
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; exit=$run.exit }
                    Write-Err "dispatch: diy-openai exited $($run.exit)"
                    if ($run.stderr) { Write-Err ([string]$run.stderr) }
                    $script:EXIT=2; return
                }
                if (-not (Test-Path -LiteralPath $res -PathType Leaf)) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; reason='result-missing' }
                    Die 2 "dispatch: diy-openai exited 0 but wrote no result file: $res"
                }
                if ((Get-Item -LiteralPath $res).Length -gt $MAX_JSON_BYTES) {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='diy-openai'; reason='result-oversize' }
                    Die 2 "dispatch: diy-openai result exceeds $MAX_JSON_BYTES bytes"
                }
                Set-PacketProp $packet 'state' 'done'
                Set-PacketProp $packet 'transport' 'diy-openai'
                Set-PacketProp $packet 'worker_model' $diy.model
                Set-PacketProp $packet 'dispatched_at' (Get-Now)
                Set-PacketProp $packet 'result_file' $res
                Set-PacketProp $packet 'result_sha256' (Get-Sha256File $res)
                Set-PacketProp $packet 'result_bytes' ((Get-Item -LiteralPath $res).Length)
                Save-Packet $packet $id
                Journal-Log @{ event='run-done'; id=$id; transport='diy-openai'; exit=0; model=$diy.model }
                Write-Output "done (diy-openai model=$($diy.model)): $res"
                Write-Output 'Astra review required: inspect the result against acceptance before summary.'
                $script:EXIT=0
            }
        }
    } finally {
        Release-Lock
    }
}

# ---------------- ingest ----------------
function Cmd-Ingest {
    Ensure-Dirs
    $a = Parse-Args 'ingest' @('Id','ResultFile')
    $id = Get-ArgVal $a 'Id' '' 'ingest'
    if (-not $id) { Die 1 'ingest: missing -Id <id>' }
    if (-not (Test-ValidId $id)) { Die 1 "ingest: invalid id '$id' (allowed: A-Za-z0-9._-)" }
    $resultFile = Get-ArgVal $a 'ResultFile' '' 'ingest'
    if (-not $resultFile) { Die 1 'ingest: missing -ResultFile <path>' }
    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) { Die 1 "ingest: result not found: $resultFile" }
    # memory boundary: refuse absurd result files before hashing/byte-counting
    # (behavioural twin of the .sh guard).
    if ((Get-Item -LiteralPath $resultFile).Length -gt $MAX_JSON_BYTES) { Die 2 "ingest: result larger than $MAX_JSON_BYTES bytes: $resultFile" }

    $packet = Load-Packet $id 'ingest'
    $state = [string](Get-Field $packet 'state')
    if (-not $state) { Die 2 "ingest: cannot read state for '$id'" }
    if ($state -ne 'done') {
        Die 1 "ingest: packet '$id' in state '$state'; dispatch it first (state 'done' required)."
    }

    $resultSha   = Get-Sha256File $resultFile
    $resultBytes = (Get-Item -LiteralPath $resultFile).Length

    # Parent binding: dispatch (local-worker) pre-registers the result hash.
    # An ingested file whose hash disagrees was tampered with or belongs to
    # another packet — refuse with exit 3, never overwrite the recorded value.
    $p = $packet.PSObject.Properties['result_sha256']
    if ($p -and $p.Value) {
        if (-not (Test-Sha256Shape ([string]$p.Value))) { Die 2 "ingest: packet '$id' corrupt: malformed result_sha256" }
        if ([string]$p.Value -ne $resultSha) {
            Journal-Log @{ event='ingest-refused'; id=$id; reason='result-hash-mismatch' }
            Die 3 "ingest: result hash mismatch for '$id'; recorded at dispatch: $($p.Value), file: $resultSha"
        }
    }
    Set-PacketProp $packet 'state' 'ingested'
    Set-PacketProp $packet 'result_file' $resultFile
    Set-PacketProp $packet 'result_sha256' $resultSha
    Set-PacketProp $packet 'result_bytes' $resultBytes
    Save-Packet $packet $id
    Journal-Log @{ event='ingest'; id=$id; sha256=$resultSha }
    Write-Output "ingested: $id"
    Write-Output "result_sha256: $resultSha"
    $script:EXIT=0
}

# ---------------- summary ----------------
function Cmd-Summary {
    Ensure-Dirs
    $a = Parse-Args 'summary' @('Id','TextFile')
    $id = Get-ArgVal $a 'Id' '' 'summary'
    if (-not $id) { Die 1 'summary: missing -Id <id>' }
    if (-not (Test-ValidId $id)) { Die 1 "summary: invalid id '$id' (allowed: A-Za-z0-9._-)" }
    $textFile = Get-ArgVal $a 'TextFile' '' 'summary'
    if (-not $textFile) { Die 1 'summary: missing -TextFile <path>' }
    if (-not (Test-Path -LiteralPath $textFile -PathType Leaf)) { Die 1 "summary: text file not found: $textFile" }
    # memory boundary, twin of the ingest guard.
    if ((Get-Item -LiteralPath $textFile).Length -gt $MAX_JSON_BYTES) { Die 2 "summary: text larger than $MAX_JSON_BYTES bytes: $textFile" }

    $packet = Load-Packet $id 'summary'
    $state = [string](Get-Field $packet 'state')
    if (-not $state) { Die 2 "summary: cannot read state for '$id'" }
    if ($state -ne 'ingested') {
        Die 1 "summary: packet '$id' in state '$state'; ingest a result first."
    }

    # Copy FIRST, then hash the final copy: the recorded summary_sha256 always
    # describes the bytes actually stored, even if the source file is modified
    # (or swapped) between the copy and the hash.
    $out = Join-Path $RESULTS_DIR "$id.summary.md"
    $outTmp = "$out.tmp.$(New-RandomTag)"
    Copy-Item -LiteralPath $textFile $outTmp -Force
    Move-Item -LiteralPath $outTmp -Destination $out -Force
    $ssha = Get-Sha256File $out
    Set-PacketProp $packet 'state' 'summarized'
    Set-PacketProp $packet 'summary_file' $out
    Set-PacketProp $packet 'summary_sha256' $ssha
    Save-Packet $packet $id
    Journal-Log @{ event='summary'; id=$id; sha256=$ssha }
    Write-Output "summary written: $out"
    $script:EXIT=0
}

# ---------------- status ----------------
function Cmd-Status {
    Ensure-Dirs
    $a = Parse-Args 'status' @('Id')
    $id = Get-ArgVal $a 'Id' '' 'status'
    $rows = @()
    if ($id) {
        if (-not (Test-ValidId $id)) { Die 1 "status: invalid id '$id' (allowed: A-Za-z0-9._-)" }
        $p = Join-Path $PACKETS_DIR "$id.execution.json"
        if (Test-Path -LiteralPath $p) {
            try { $pkt = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | ConvertFrom-Json } catch { Die 2 "status: corrupt json for '$id'" }
            $st = [string](Get-Field $pkt 'state')
            if (-not $st) { Die 2 "status: cannot read state for '$id'" }
            $rows += ,[ordered]@{ id=(Get-Field $pkt 'id'); state=(Get-Field $pkt 'state'); transport=(Get-Field $pkt 'transport'); created=(Get-Field $pkt 'created_at') }
        }
    } else {
        $files = @(Get-ChildItem -LiteralPath $PACKETS_DIR -Filter '*.execution.json' -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($f in $files) {
            try { $pkt = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8) | ConvertFrom-Json } catch { continue }
            $rows += ,[ordered]@{ id=(Get-Field $pkt 'id'); state=(Get-Field $pkt 'state'); transport=(Get-Field $pkt 'transport'); created=(Get-Field $pkt 'created_at') }
        }
    }
    if ($rows.Count -eq 0) {
        Write-Output "status: no packets in $PACKETS_DIR"
    } else {
        foreach ($r in $rows) { Write-Output ($r | ConvertTo-Json -Compress) }
    }
    $script:EXIT=0
}

# ---------------- astra-Diy (OpenAI-compatible custom worker) ----------------
function Cmd-DiySet {
    Ensure-Dirs
    $a = Parse-Args 'diy-set' @('BaseUrl','ApiKey','Model','Enabled','ReplaceLuna','Temperature','TimeoutSec','Provider','AppId','AesKey','WxEnv')
    $argv = @('set')
    $pairs = @(
        @('Provider','--provider'),
        @('BaseUrl','--base-url'),
        @('ApiKey','--api-key'),
        @('AppId','--appid'),
        @('AesKey','--aes-key'),
        @('WxEnv','--wx-env'),
        @('Model','--model'),
        @('Enabled','--enabled'),
        @('ReplaceLuna','--replace-luna'),
        @('Temperature','--temperature'),
        @('TimeoutSec','--timeout-sec')
    )
    $any = $false
    foreach ($pair in $pairs) {
        $val = Get-ArgVal $a $pair[0] $null 'diy-set'
        if ($null -eq $val) { continue }
        $argv += @($pair[1], $val)
        $any = $true
    }
    if (-not $any) { Die 1 'diy-set: provide at least one of -Provider -BaseUrl -ApiKey -AppId -AesKey -Model -Enabled -ReplaceLuna -Temperature -TimeoutSec -WxEnv' }
    $run = Invoke-OpenAiDiy $argv 30
    if ($run.stdout) { Write-Output $run.stdout }
    if ($run.stderr) { Write-Err ([string]$run.stderr) }
    if ($run.exit -ne 0) { Die $run.exit 'diy-set failed' }
    Journal-Log @{ event='diy-set'; exit=0 }
    $script:EXIT=0
}
function Cmd-DiyShow {
    Ensure-Dirs
    $run = Invoke-OpenAiDiy @('show') 30
    if ($run.stdout) { Write-Output $run.stdout }
    if ($run.stderr) { Write-Err ([string]$run.stderr) }
    if ($run.exit -ne 0) { Die $run.exit 'diy-show failed' }
    $script:EXIT=0
}
function Cmd-DiyClear {
    Ensure-Dirs
    $run = Invoke-OpenAiDiy @('clear') 30
    if ($run.stdout) { Write-Output $run.stdout }
    if ($run.stderr) { Write-Err ([string]$run.stderr) }
    if ($run.exit -ne 0) { Die $run.exit 'diy-clear failed' }
    Journal-Log @{ event='diy-clear'; exit=0 }
    $script:EXIT=0
}
function Cmd-DiyTest {
    Ensure-Dirs
    $run = Invoke-OpenAiDiy @('test') 60
    if ($run.stdout) { Write-Output $run.stdout }
    if ($run.stderr) { Write-Err ([string]$run.stderr) }
    if ($run.exit -ne 0) { $script:EXIT=$run.exit; return }
    Journal-Log @{ event='diy-test'; exit=0 }
    $script:EXIT=0
}
function Cmd-DiyModels {
    Ensure-Dirs
    $run = Invoke-OpenAiDiy @('models') 60
    if ($run.stdout) { Write-Output $run.stdout }
    if ($run.stderr) { Write-Err ([string]$run.stderr) }
    if ($run.exit -ne 0) { $script:EXIT=$run.exit; return }
    $script:EXIT=0
}
function Cmd-DiySchema {
    $run = Invoke-OpenAiDiy @('schema') 15
    if ($run.stdout) { Write-Output $run.stdout }
    if ($run.stderr) { Write-Err ([string]$run.stderr) }
    if ($run.exit -ne 0) { Die $run.exit 'diy-schema failed' }
    $script:EXIT=0
}
function Cmd-DiySettings {
    Ensure-Dirs
    $dlg = Get-DiySettingsScript
    if (-not $dlg) { Die 2 'diy-settings: scripts\diy-settings.ps1 not found' }
    $a = Parse-Args 'diy-settings' @('CliOnly')
    $extra = @()
    if ($a.ContainsKey('CliOnly')) { $extra += '-CliOnly' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $dlg.Replace('"','\"') + '"'
    if ($extra.Count -gt 0) { $argLine += ' ' + ($extra -join ' ') }
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit(300000) | Out-Null
        $out = $outTask.Result
        $err = $errTask.Result
        if ($out) { Write-Output $out }
        if ($err) { Write-Err ([string]$err) }
        if ($proc.ExitCode -ne 0) { $script:EXIT = $proc.ExitCode; return }
        $script:EXIT=0
    } catch {
        Die 2 ("diy-settings failed: " + $_.Exception.Message)
    }
}

# ---------------- main ----------------
# Command dispatch is byte-exact (twin of the .sh case statement): 'Doctor'
# is not 'doctor' and falls through to the usage error (exit 1).
switch -CaseSensitive ($Command) {
    'doctor'       { Cmd-Doctor }
    'init'         { Cmd-Init }
    'new-packet'   { Cmd-NewPacket }
    'dispatch'     { try { Cmd-Dispatch } finally { Release-Lock } }
    'ingest'       { Cmd-Ingest }
    'summary'      { Cmd-Summary }
    'status'       { Cmd-Status }
    'diy-set'      { Cmd-DiySet }
    'diy-show'     { Cmd-DiyShow }
    'diy-clear'    { Cmd-DiyClear }
    'diy-test'     { Cmd-DiyTest }
    'diy-models'   { Cmd-DiyModels }
    'diy-settings' { Cmd-DiySettings }
    'diy-schema'   { Cmd-DiySchema }
    default      { Write-Output "usage: astra-luna.ps1 <doctor|init|new-packet|dispatch|ingest|summary|status|diy-set|diy-show|diy-clear|diy-test|diy-models|diy-settings|diy-schema>"; $script:EXIT=1 }
}
exit $script:EXIT
