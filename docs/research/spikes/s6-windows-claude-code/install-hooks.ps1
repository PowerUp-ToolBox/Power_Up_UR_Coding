# S6 check H: registers the five PowerUp hook events in the Claude Code USER
# settings file, after making a backup. Undo with restore-settings.ps1.
# Throwaway spike code (#133). Windows PowerShell 5.1 or PowerShell 7.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-hooks.ps1 -Variant curl
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-hooks.ps1 -Variant relay
#
# -Variant curl  : command is curl.exe posting stdin with the X-PowerUp-Token header
#                  (the plan's check; works whether Claude Code runs hooks via Git Bash or cmd)
# -Variant relay : command runs hook-relay.ps1 through powershell.exe (fallback, so a
#                  quoting problem in the curl variant cannot produce a false NO-GO)
# -SettingsPath  : defaults to %USERPROFILE%\.claude\settings.json
param(
    [ValidateSet('curl', 'relay')][string]$Variant = 'curl',
    [int]$Port = 47800,
    [string]$Token = 'spike-token-7f3a',
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json')
)
$ErrorActionPreference = 'Stop'

# The same five events PowerUp registers (HookInstaller.hookEvents).
$events = @('Stop', 'UserPromptSubmit', 'Notification', 'SessionEnd', 'PostToolUse')

if ($Variant -eq 'curl') {
    $command = "curl.exe -s --max-time 2 -X POST -H `"Content-Type: application/json`" -H `"X-PowerUp-Token: $Token`" --data-binary @- http://127.0.0.1:$Port/event"
} else {
    $relay = (Join-Path $PSScriptRoot 'hook-relay.ps1') -replace '\\', '/'
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$relay`" -Port $Port -Token $Token"
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$dir = Split-Path -Parent $SettingsPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$SettingsPath.s6-backup-$stamp"
if (Test-Path $SettingsPath) {
    Copy-Item -LiteralPath $SettingsPath -Destination $backup
    $text = [System.IO.File]::ReadAllText($SettingsPath, $utf8)
} else {
    # Marker: there was no settings file, so restoring means deleting it.
    [System.IO.File]::WriteAllText($backup, '__S6_NO_ORIGINAL__', $utf8)
    $text = ''
}
Write-Host "backup: $backup"

if ($text.Trim() -eq '') { $root = New-Object PSObject } else { $root = $text | ConvertFrom-Json }
if (-not ($root.PSObject.Properties.Name -contains 'hooks')) {
    $root | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject)
}
foreach ($name in $events) {
    $group = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $command }) }
    if ($root.hooks.PSObject.Properties.Name -contains $name) {
        $root.hooks.$name = @($root.hooks.$name) + @($group)
    } else {
        $root.hooks | Add-Member -NotePropertyName $name -NotePropertyValue @($group)
    }
}

# UTF-8 WITHOUT a byte-order mark: Windows PowerShell's Set-Content -Encoding UTF8
# writes a BOM, which could make the CLI reject the file and fake a NO-GO.
$json = $root | ConvertTo-Json -Depth 32
[System.IO.File]::WriteAllText($SettingsPath, $json, $utf8)
Write-Host "registered $($events.Count) events in $SettingsPath with command:"
Write-Host "  $command"
Write-Host 'verify: Get-Content -Raw $env:USERPROFILE\.claude\settings.json; and run /hooks inside claude'
