#Requires -Version 5.1
<#
  sol-luna.ps1 -- GPT-5.6 Sol command-center plugin (Windows transport).

  Workflow:
    Sol (Codex) --packet--> ChatGPT Web GPT-5.6 Luna Max --result--> Sol (summary)

  Subcommands:
    doctor       Ready checks (transport, agent TOML, size limit) -> JSON verdict
    init         Idempotent install: agent TOML, skill, AGENTS.md rules.
                 NEVER edits config.toml (only reports the recommendation).
    new-packet   -SpecFile <json>       build an execution packet + payload.md
    dispatch     -Id <id> [-Transport web-desktop|web-manual|local-worker] [-TimeoutSec <n>]
    ingest       -Id <id> -ResultFile <file>
    summary      -Id <id> -TextFile <file>
    status       [-Id <id>] : list packet states

  Exit: 0 ok | 1 usage/validation | 2 runtime | 3 hash mismatch
  This tool NEVER silently degrades transport or model.

  Environment:
    SOL_LUNA_STATE_DIR  state directory override (default <plugin>\.sol-luna-state)
    CODEX_HOME          Codex home override (default %USERPROFILE%\.codex)
    SOL_LUNA_CODEX_BIN  explicit codex CLI path (pinned/non-PATH installs and
                        tests); dispatch accepts a native .exe (a shim is
                        resolved to the native codex.exe behind it)

  Security notes:
    - packet ids are strictly validated (^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$);
      path metacharacters never reach the filesystem.
    - the per-packet dispatch lock is created atomically (FileMode CreateNew);
      a lock older than 1h is stale: removed once, then retried.
    - hashes are computed over raw FILE bytes (SHA-256), never re-encoded text.
    - child process output is drained asynchronously (no pipe deadlock) and
      every argv element is quoted with MSVCRT rules before CreateProcess.
    - local-worker only ever CreateProcess's a NATIVE codex.exe. A .cmd/.bat
      `codex` shim is never executed (it would hand the payload to cmd.exe's
      re-parsing: BatBadBut); the native binary behind the shim is resolved and
      used instead, and when none can be proven to exist dispatch refuses.
    - execution.json / payload.md are written atomically (temp + move).
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('doctor','init','new-packet','dispatch','ingest','summary','status')]
    [string]$Command,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RawArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PLUGIN_DIR  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$STATE_DIR   = if ($env:SOL_LUNA_STATE_DIR) { [System.IO.Path]::GetFullPath($env:SOL_LUNA_STATE_DIR) }
               else { Join-Path $PLUGIN_DIR '.sol-luna-state' }
$PACKETS_DIR = Join-Path $STATE_DIR 'packets'
$RESULTS_DIR = Join-Path $STATE_DIR 'results'
$JOURNAL     = Join-Path $STATE_DIR 'journal.jsonl'
$DEFAULT_MAX_PAYLOAD_BYTES = 12000
$MAX_JSON_BYTES            = 1MB      # read cap for spec / execution.json (memory boundary)
$MAX_TIMEOUT_SECONDS       = 86400    # upper-bound twin of the .sh dispatch guard (24h);
                                      # keeps Invoke-Run's millisecond math inside int32
$LOCK_STALE_SECONDS        = 3600
$MD_BEGIN    = 'sol-luna:begin'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:EXIT = 0
$script:OwnedLock = $null

function Write-Err([string]$m){ [Console]::Error.WriteLine('sol-luna: ' + $m) }
function Die([int]$c,[string]$m){ if($m){Write-Err $m}; exit $c }

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
    # Full option name only. A single-letter alias fallback ('-Transport' -> 't')
    # collided with '-TimeoutSec'/'-TextFile' (same short form), so
    # `dispatch -Id X -TimeoutSec 300` parsed transport='300' and died with a
    # bogus usage error instead of using the local-worker default. All
    # documented spellings are the full names.
    # A flag seen WITHOUT a value ('-Transport' at end of argv) never falls
    # back silently to the default: that is a usage error (exit 1), twin of
    # the .sh "<option> needs a value" path.
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
                $mig = "$JOURNAL.migrate.$PID"
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
function Get-AgentToml { Join-Path (Get-CodexDir) 'agents\luna-worker.toml' }
function Get-SkillDst  { Join-Path (Get-CodexDir) 'skills\sol-command-center' }
function Get-AgentsMd  { Join-Path $PWD.Path 'AGENTS.md' }
function Get-Now { try { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { (Get-Date).ToString('s') } }

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
    # atomic write: temp file + move -> never a torn execution.json
    $p   = Join-Path $PACKETS_DIR "$id.execution.json"
    $tmp = "$p.tmp.$PID"
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
    # a shim. SOL_LUNA_CODEX_BIN pins the CLI explicitly and is held to the same
    # rule (a pinned shim is resolved, never executed).
    if ($env:SOL_LUNA_CODEX_BIN) {
        $pin = [string]$env:SOL_LUNA_CODEX_BIN
        if (-not (Test-Path -LiteralPath $pin -PathType Leaf)) {
            Die 2 "dispatch: local-worker: SOL_LUNA_CODEX_BIN not found: $pin"
        }
        if ([System.IO.Path]::GetExtension($pin) -eq '.exe') { return $pin }
        $native = Get-NativeCodexFromShim $pin
        if ($native) { return $native }
        Die 2 ("dispatch: local-worker: SOL_LUNA_CODEX_BIN='" + $pin + "' is not a native .exe and no native codex.exe exists behind it; " +
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
           "install the native codex.exe (or point SOL_LUNA_CODEX_BIN at codex.exe); passing payload text through cmd.exe would be unsafe (BatBadBut).")
}

# ---------------- doctor ----------------
function Cmd-Doctor {
    Ensure-Dirs
    $agentToml = Get-AgentToml
    $hasToml = Test-Path -LiteralPath $agentToml
    $model='gpt-5.6-luna'; $effort='max'
    if ($hasToml) {
        try {
            $c = [System.IO.File]::ReadAllText($agentToml)
            $m=[regex]::Match($c,'(?im)^\s*model\s*=\s*"([^"]+)"'); if($m.Success){$model=$m.Groups[1].Value}
            $e=[regex]::Match($c,'(?im)^\s*model_reasoning_effort\s*=\s*"([^"]+)"'); if($e.Success){$effort=$e.Groups[1].Value}
        } catch {}
    }
    $cfgPath = Join-Path (Get-CodexDir) 'config.toml'
    $ask=$false
    if (Test-Path -LiteralPath $cfgPath) {
        try { $ask=(([System.IO.File]::ReadAllText($cfgPath)) -match 'default_mode_request_user_input\s*=\s*true') } catch {}
    }
    # local_worker availability on Windows is the agent TOML: hashing is
    # Get-FileHash (always present), codex.exe is resolved at dispatch time
    # and reported loudly if missing (no silent degradation).
    $localWorker = $hasToml

    $verdict = [ordered]@{
        os = 'windows'
        plugin_dir = $PLUGIN_DIR
        state_dir = $STATE_DIR
        size_limit_bytes = $DEFAULT_MAX_PAYLOAD_BYTES
        transports = [ordered]@{ web_desktop=$true; web_manual=$true; local_worker=$localWorker }
        agent_toml = $hasToml
        agent_path = $agentToml
        luna_model = $model
        luna_effort = $effort
        config_toml = (Test-Path -LiteralPath $cfgPath)
        request_user_input = $ask
        probe = 'local-worker: verify the model round-trip works (model answers a known-answer question correctly). The gpt-5.6-* tiers run on a gpt-5 base, so a gpt-5/GPT-5 self-identification is expected and still counts for the gpt-5.6-luna + max route; do not gate dispatch on an exact slug. web-desktop/web-manual are verified by the user selecting GPT-5.6 Luna Max in the ChatGPT UI — no local probe required.'
    }
    Write-Output ($verdict | ConvertTo-Json -Depth 8)
    if (-not $hasToml) {
        # First-run guard: surface the exact copy-pasteable fix so the missing
        # step (init) cannot be skipped. The JSON verdict above already 手上
        # already tells the caller it's missing; this makes the remedy explicit and
        # honours CODEX_HOME (doctor and init both read it from the env), so
        # the same command provisions the agent even with a custom home.
        $ps1Path = Join-Path $PLUGIN_DIR 'scripts\sol-luna.ps1'
        $q = '"' + ($ps1Path -replace '"', '\"') + '"'
        Write-Err ''
        Write-Err 'doctor: missing luna_worker agent - the plugin is installed but NOT initialized.'
        Write-Err ("  expected agent file: {0}" -f $agentToml)
        Write-Err '  consequence: the local-worker transport is unavailable and Luna model/effort probes cannot run.'
        Write-Err '  fix (copy/paste, then re-run doctor):'
        Write-Err ("    powershell -NoProfile -ExecutionPolicy Bypass -File {0} init" -f $q)
        Write-Err ''
        $script:EXIT=2; return
    }
    $script:EXIT=0
}

# ---------------- init ----------------
function Cmd-Init {
    Ensure-Dirs
    New-Item -ItemType Directory -Force -Path (Join-Path (Get-CodexDir) 'agents') | Out-Null
    $agentPath = Get-AgentToml
    $changed = $false
    if (Test-Path -LiteralPath $agentPath) {
        Write-Output "init: existing agent preserved: $agentPath"
    } else {
        Copy-Item (Join-Path $PLUGIN_DIR 'agents\luna-worker.toml') $agentPath
        Write-Output "init: wrote $agentPath"
        $changed=$true
    }
    $srcSkill = Join-Path $PLUGIN_DIR 'skills\sol-command-center'
    $dstSkill = Get-SkillDst
    $skillExisted = Test-Path -LiteralPath $dstSkill
    New-Item -ItemType Directory -Force -Path $dstSkill | Out-Null
    # SKILL.md is plugin-owned: refresh on every init so skill updates
    # propagate (the agent TOML above stays preserve-if-present; SKILL.md is
    # not user-edited state).
    Copy-Item -LiteralPath (Join-Path $srcSkill 'SKILL.md') -Destination (Join-Path $dstSkill 'SKILL.md') -Force
    # Clone the launcher runtime next to SKILL.md. The installed skill copy is
    # invoked with CWD = skill dir, so its documented launcher path
    # ('.\scripts\sol-luna.ps1') must exist HERE - not two levels up in the
    # plugin checkout. The old copy-if-absent install copied only SKILL.md and
    # left the copy referencing a launcher that existed nowhere
    # (..\..\scripts\ resolved to ~/.codex/scripts/, which is never created).
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
        Write-Output 'init: AGENTS.md already carries sol-luna rules'
    } else {
        $block = [System.IO.File]::ReadAllText((Join-Path $PLUGIN_DIR 'templates\AGENTS.md')).Trim()
        $sep = if ($agentsText.Trim().Length -gt 0) { "`r`n`r`n" } else { '' }
        Write-TextNoBom $agentsPath ($agentsText + $sep + $block + "`r`n")
        Write-Output "init: merged rules into $agentsPath"
    }
    Write-Output 'init: config.toml is never auto-edited. Apply config/config.toml.example yourself.'
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
        $bomlessSpec = Join-Path $env:TEMP ("sol-luna-spec." + $PID + ".json")
        [System.IO.File]::WriteAllBytes($bomlessSpec, $rawSpec[3..($rawSpec.Length - 1)])
        try { $spec = [System.IO.File]::ReadAllText($bomlessSpec) | ConvertFrom-Json } catch { Die 1 'new-packet: invalid spec JSON' }
        if ($null -eq $spec) { Die 1 'new-packet: invalid spec JSON' }
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
# Execution packet (GPT-5.6 Luna Max - bounded executor)

## Goal
$goal

## Symptom
$($S['symptom'])

## Root cause (from GPT-5.6 Sol command center)
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
    $id = (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
    $payloadPath = Join-Path $PACKETS_DIR "$id.payload.md"
    $payloadTmp  = "$payloadPath.tmp.$PID"
    Write-TextNoBom $payloadTmp $payload
    Move-Item -LiteralPath $payloadTmp -Destination $payloadPath -Force
    Copy-Item -LiteralPath $specFile (Join-Path $PACKETS_DIR "$id.spec.json") -Force
    $packet = [ordered]@{
        state='new'; id=$id; created_at=(Get-Now)
        model='gpt-5.6-luna'; effort='max'; transport=''
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
    if (-not $transport) { $transport = 'local-worker' }
    if ($transport -notin @('web-desktop','web-manual','local-worker')) {
        Die 1 "dispatch: unknown transport '$transport' (web-desktop|web-manual|local-worker)"
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

    # per-packet dispatch lock (atomic; stale locks older than 1h are recovered)
    if (-not (Acquire-Lock $id)) {
        Die 2 "dispatch: '$id' already being dispatched (active or recent lock in $STATE_DIR)"
    }
    try {
        $mdPath = Join-Path $PACKETS_DIR "$id.payload.md"
        if (-not (Test-Path -LiteralPath $mdPath)) { Die 1 "dispatch: payload missing: $mdPath" }
        # memory boundary (twin of the sh MAX_JSON_BYTES guard): creation
        # already caps payloads at 12000 bytes, so a bigger file here was
        # swapped in after creation.
        if ((Get-Item -LiteralPath $mdPath).Length -gt $MAX_JSON_BYTES) { Die 2 "dispatch: payload larger than $MAX_JSON_BYTES bytes: $mdPath" }
        $payloadSha = Get-Sha256File $mdPath
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

        switch ($transport) {
            'local-worker' {
                $codex = Resolve-CodexCommand
                # Current codex-cli (>=0.148 alpha): `exec` takes the prompt as a
                # POSITIONAL arg, and the agent's model/effort come from config
                # overrides, NOT the removed `-t <agent>` / `-p <prompt>` flags.
                # We set model + reasoning effort explicitly and fold the
                # luna_worker persona (previously the developer_instructions in
                # agents/luna-worker.toml) into the prompt.
                $prompt = ("You are the bounded luna_worker execution agent reporting to GPT-5.6 Sol. " +
                            "Complete only the assigned subtask in the execution packet ($id). " +
                            "Stay strictly in scope and file boundaries. Do not spawn agents or change architecture. " +
                            "Verify when practical. Return a result with: (1) exact result, (2) files changed/inspected, " +
                            "(3) checks run, (4) verification, (5) remaining risks.`n`n" + [System.IO.File]::ReadAllText($mdPath))
                $run = $null
                try {
                    $run = Invoke-Run $codex @('exec','--skip-git-repo-check','--model','gpt-5.6-luna','-c','model_reasoning_effort="max"',$prompt) $timeout
                } catch {
                    Journal-Log @{ event='dispatch-failed'; id=$id; transport='local-worker'; error=[string]$_ }
                    Die 2 "dispatch: local-worker run failed: $_"
                }
                # memory boundary: a runaway worker's stdout is never silently
                # truncated (no silent degradation) -- refuse instead.
                if ($run.stdout.Length -gt $MAX_JSON_BYTES) {
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
            'web-desktop' {
                # web-* transports stage a file for a human carrier only. They
                # never touch the clipboard (shared boundary; payload may hold
                # sensitive material) and never auto-open a browser.
                # Staged via temp + rename so the final file never appears
                # half-written.
                $clip = Join-Path $RESULTS_DIR "$id.to-web.txt"
                # Unique temp suffix: two concurrent dispatches of the same id
                # are already excluded by the lock, but a crashed earlier run
                # could leave "....part" behind; a fixed name would then race
                # Move-Item (twin of the sh "$$"-suffixed staging temp).
                $clipPart = "$clip.part.$PID"
                Copy-Item -LiteralPath $mdPath $clipPart -Force
                Move-Item -LiteralPath $clipPart $clip -Force
                Set-PacketProp $packet 'state' 'done'
                Set-PacketProp $packet 'transport' 'web-desktop'
                Set-PacketProp $packet 'dispatched_at' (Get-Now)
                Save-Packet $packet $id
                Journal-Log @{ event='dispatch'; id=$id; transport='web-desktop' }
                Write-Output "web-desktop staged: $clip"
                Write-Output "Open the ChatGPT desktop app with GPT-5.6 Luna Max selected, paste payload, then save reply to:"
                Write-Output "  $(Join-Path $RESULTS_DIR "$id.web-result.md")"
                $script:EXIT=0
            }
            default {
                # web-manual: same staging discipline as web-desktop.
                $clip = Join-Path $RESULTS_DIR "$id.to-web.txt"
                $clipPart = "$clip.part.$PID"
                Copy-Item -LiteralPath $mdPath $clipPart -Force
                Move-Item -LiteralPath $clipPart $clip -Force
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

    $ssha = Get-Sha256File $textFile   # hash the source exactly once, reuse below
    $out = Join-Path $RESULTS_DIR "$id.summary.md"
    Copy-Item -LiteralPath $textFile $out -Force
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

# ---------------- main ----------------
# Command dispatch is byte-exact (twin of the .sh case statement): 'Doctor'
# is not 'doctor' and falls through to the usage error (exit 1).
switch -CaseSensitive ($Command) {
    'doctor'     { Cmd-Doctor }
    'init'       { Cmd-Init }
    'new-packet' { Cmd-NewPacket }
    'dispatch'   { try { Cmd-Dispatch } finally { Release-Lock } }
    'ingest'     { Cmd-Ingest }
    'summary'    { Cmd-Summary }
    'status'     { Cmd-Status }
    default      { Write-Output "usage: sol-luna.ps1 <doctor|init|new-packet|dispatch|ingest|summary|status>"; $script:EXIT=1 }
}
exit $script:EXIT
