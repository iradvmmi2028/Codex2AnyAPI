#Requires -Version 5.1
<#
  diy-settings.ps1 -- OpenAI-compatible DIY worker settings dialog (Windows).

  Renders real textboxes for Base URL / API Key / Model plus enable and
  replace-luna toggles. Saves through scripts/openai-diy.py so the file format
  stays identical to the CLI path.

  Usage:
    powershell -File scripts\diy-settings.ps1
    powershell -File scripts\diy-settings.ps1 -CliOnly   # print the form fields + diy-set command (no GUI)

  Exit: 0 saved | 1 cancelled / usage | 2 runtime
#>
[CmdletBinding()]
param(
    [switch]$CliOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PLUGIN_DIR = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DIY_PY = Join-Path $PLUGIN_DIR 'scripts\openai-diy.py'

function Get-PythonCommand {
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

function Invoke-Diy([string[]]$argv) {
    $py = Get-PythonCommand
    if (-not $py) { throw 'python not found (set ASTRA_LUNA_PYTHON or put python on PATH)' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $py
    $quoted = @()
    foreach ($a in $argv) {
        if ($a -match '[\s"]') { $quoted += '"' + ($a -replace '"','\"') + '"' } else { $quoted += $a }
    }
    $psi.Arguments = ('"'+$DIY_PY+'" ' + ($quoted -join ' '))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Exit=$p.ExitCode; Out=$out; Err=$err }
}

if (-not (Test-Path -LiteralPath $DIY_PY -PathType Leaf)) {
    [Console]::Error.WriteLine("diy-settings: openai-diy.py not found at $DIY_PY")
    exit 2
}

# Load current values (masked key is not written back unless the user retypes it).
$show = Invoke-Diy @('show')
$cur = @{}
if ($show.Exit -eq 0 -and $show.Out) {
    try { $j = $show.Out | ConvertFrom-Json
        $cur.base_url = [string]$j.base_url
        $cur.model = [string]$j.model
        $cur.enabled = [bool]$j.enabled
        $cur.replace_luna = [bool]$j.replace_luna
        $cur.api_key_masked = [string]$j.api_key_masked
        $cur.ready = [bool]$j.ready
        $cur.config_path = [string]$j.config_path
    } catch {}
}
if (-not $cur.ContainsKey('base_url')) { $cur.base_url = '' }
if (-not $cur.ContainsKey('model')) { $cur.model = '' }
if (-not $cur.ContainsKey('enabled')) { $cur.enabled = $false }
if (-not $cur.ContainsKey('replace_luna')) { $cur.replace_luna = $true }
if (-not $cur.ContainsKey('api_key_masked')) { $cur.api_key_masked = '' }
if (-not $cur.ContainsKey('config_path')) { $cur.config_path = '' }

if ($CliOnly) {
    Write-Output 'astra-Diy settings fields (fill, then run the diy-set command):'
    Write-Output '  Base URL   : OpenAI-compatible endpoint, e.g. http://127.0.0.1:11434/v1'
    Write-Output '  API Key    : Bearer token (sk-... or provider token)'
    Write-Output '  Model      : custom model id replacing gpt-5.6-luna'
    Write-Output ''
    Write-Output ("current: enabled={0} replace_luna={1} base_url={2} model={3} api_key={4}" -f $cur.enabled, $cur.replace_luna, $cur.base_url, $cur.model, $cur.api_key_masked)
    Write-Output ''
    Write-Output 'Example (PowerShell):'
    Write-Output '  powershell -File scripts\astra-luna.ps1 diy-set -BaseUrl "https://api.example.com/v1" -ApiKey "sk-..." -Model "my-model" -Enabled true -ReplaceLuna true'
    Write-Output '  powershell -File scripts\astra-luna.ps1 diy-test'
    Write-Output '  powershell -File scripts\astra-luna.ps1 diy-models'
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Astra DIY — OpenAI-compatible worker settings'
$form.Size = New-Object System.Drawing.Size(560, 420)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

function Add-Label([string]$text,[int]$x,[int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x,$y)
    $l.AutoSize = $true
    $form.Controls.Add($l)
    return $l
}

Add-Label 'Base URL (OpenAI-compatible)' 20 20 | Out-Null
$tbBase = New-Object System.Windows.Forms.TextBox
$tbBase.Location = New-Object System.Drawing.Point(20,42)
$tbBase.Size = New-Object System.Drawing.Size(500,24)
$tbBase.Text = [string]$cur.base_url
$form.Controls.Add($tbBase)

Add-Label "API Key (leave blank to keep current: $($cur.api_key_masked))" 20 78 | Out-Null
$tbKey = New-Object System.Windows.Forms.TextBox
$tbKey.Location = New-Object System.Drawing.Point(20,100)
$tbKey.Size = New-Object System.Drawing.Size(500,24)
$tbKey.UseSystemPasswordChar = $true
$tbKey.Text = ''
$form.Controls.Add($tbKey)

Add-Label 'Model (custom id that replaces gpt-5.6-luna)' 20 136 | Out-Null
$tbModel = New-Object System.Windows.Forms.TextBox
$tbModel.Location = New-Object System.Drawing.Point(20,158)
$tbModel.Size = New-Object System.Drawing.Size(500,24)
$tbModel.Text = [string]$cur.model
$form.Controls.Add($tbModel)

$chkEnabled = New-Object System.Windows.Forms.CheckBox
$chkEnabled.Text = 'Enable DIY worker (astra-Diy)'
$chkEnabled.Location = New-Object System.Drawing.Point(20,200)
$chkEnabled.AutoSize = $true
$chkEnabled.Checked = [bool]$cur.enabled
$form.Controls.Add($chkEnabled)

$chkReplace = New-Object System.Windows.Forms.CheckBox
$chkReplace.Text = 'Replace gpt-5.6-luna as worker (Astra remains control tower)'
$chkReplace.Location = New-Object System.Drawing.Point(20,228)
$chkReplace.AutoSize = $true
$chkReplace.Checked = [bool]$cur.replace_luna
$form.Controls.Add($chkReplace)

$lblPath = New-Object System.Windows.Forms.Label
$lblPath.Text = "Config: $($cur.config_path)"
$lblPath.Location = New-Object System.Drawing.Point(20,262)
$lblPath.AutoSize = $true
$lblPath.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblPath)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = 'Test connection'
$btnTest.Location = New-Object System.Drawing.Point(20,300)
$btnTest.Size = New-Object System.Drawing.Size(140,32)
$form.Controls.Add($btnTest)

$btnModels = New-Object System.Windows.Forms.Button
$btnModels.Text = 'Fetch models'
$btnModels.Location = New-Object System.Drawing.Point(170,300)
$btnModels.Size = New-Object System.Drawing.Size(120,32)
$form.Controls.Add($btnModels)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save'
$btnSave.Location = New-Object System.Drawing.Point(360,300)
$btnSave.Size = New-Object System.Drawing.Size(80,32)
$form.Controls.Add($btnSave)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(450,300)
$btnCancel.Size = New-Object System.Drawing.Size(70,32)
$form.Controls.Add($btnCancel)

$txtStatus = New-Object System.Windows.Forms.TextBox
$txtStatus.Multiline = $true
$txtStatus.ScrollBars = 'Vertical'
$txtStatus.ReadOnly = $true
$txtStatus.Location = New-Object System.Drawing.Point(20,340)
$txtStatus.Size = New-Object System.Drawing.Size(500,40)
$txtStatus.Text = 'Fill Base URL / API Key / Model, then Save. Use Test / Fetch models to verify the provider.'
$form.Controls.Add($txtStatus)

function Save-FromForm([bool]$enableIfReady) {
    $base = $tbBase.Text.Trim()
    $key = $tbKey.Text
    $model = $tbModel.Text.Trim()
    if (-not $base) { $txtStatus.Text = 'Base URL is required.'; return $false }
    if (-not $model) { $txtStatus.Text = 'Model is required.'; return $false }
    $enabled = $chkEnabled.Checked
    if ($enableIfReady -and -not $enabled) { $enabled = $true }
    $argv = @('set','--base-url',$base,'--model',$model,
              '--enabled',$(if($enabled){'true'}else{'false'}),
              '--replace-luna',$(if($chkReplace.Checked){'true'}else{'false'}))
    if ($key -ne '') { $argv += @('--api-key',$key) }
    $r = Invoke-Diy $argv
    if ($r.Exit -ne 0) {
        $txtStatus.Text = 'Save failed: ' + $r.Err
        return $false
    }
    $txtStatus.Text = 'Saved. Run Test connection, then diy-openai dispatch when ready.'
    return $true
}

$btnSave.Add_Click({ [void](Save-FromForm $false); if ($txtStatus.Text -like 'Saved*') { $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() } })
$btnCancel.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })
$btnTest.Add_Click({
    if (-not (Save-FromForm $false)) { return }
    $r = Invoke-Diy @('test')
    $txtStatus.Text = if ($r.Exit -eq 0) { 'TEST OK' + "`n" + $r.Out } else { 'TEST FAIL' + "`n" + $r.Out + $r.Err }
})
$btnModels.Add_Click({
    if (-not (Save-FromForm $false)) { return }
    $r = Invoke-Diy @('models')
    $txtStatus.Text = if ($r.Exit -eq 0) { $r.Out } else { 'models failed' + "`n" + $r.Out + $r.Err }
})

$result = $form.ShowDialog()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) { exit 0 }
exit 1
