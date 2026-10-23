# S6: undoes install-hooks.ps1 by putting the backup back.
# With no -Backup, uses the newest settings.json.s6-backup-* next to the settings file.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File restore-settings.ps1
param(
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$Backup = ''
)
$ErrorActionPreference = 'Stop'
if ($Backup -eq '') {
    $dir = Split-Path -Parent $SettingsPath
    $leaf = Split-Path -Leaf $SettingsPath
    $newest = Get-ChildItem -LiteralPath $dir -Filter "$leaf.s6-backup-*" | Sort-Object Name | Select-Object -Last 1
    if ($null -eq $newest) { throw "no $leaf.s6-backup-* found in $dir" }
    $Backup = $newest.FullName
}
$content = [System.IO.File]::ReadAllText($Backup)
if ($content -eq '__S6_NO_ORIGINAL__') {
    if (Test-Path $SettingsPath) { Remove-Item -LiteralPath $SettingsPath }
    Write-Host "there was no settings file before the spike; removed $SettingsPath"
} else {
    Copy-Item -LiteralPath $Backup -Destination $SettingsPath -Force
    Write-Host "restored $SettingsPath from $Backup"
}
Write-Host "the backup file is kept; delete it yourself once you have checked: $Backup"
