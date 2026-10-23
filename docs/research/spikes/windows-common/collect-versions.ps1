# Collects the versions every Windows spike record (S4, S5, S6) must list.
# Windows PowerShell 5.1 or PowerShell 7. Prints Markdown table rows; paste them
# into the record's "Versions" table. Read-only: changes nothing on the machine.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File collect-versions.ps1 > versions.md

$ErrorActionPreference = 'Continue'

function Row([string]$name, $value) {
    if ($null -eq $value -or "$value".Trim() -eq '') { $value = '(not found)' }
    "| $name | $("$value".Trim() -replace '\r?\n', '<br>') |"
}

function Try-Command([scriptblock]$block) {
    try { (& $block 2>&1 | Out-String).Trim() } catch { '(not found)' }
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
$display = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion

'| Item | Value |'
'|---|---|'
Row 'Windows' "$($os.Caption) $display, build $($os.BuildNumber).$ubr, $($os.OSArchitecture)"
Row 'Machine' "$($cs.Manufacturer) $($cs.Model); bare metal: $(-not ($cs.Model -match 'Virtual|VMware|KVM|Parallels'))"
Row 'CPU' "$($cpu.Name), $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads"
Row 'RAM' ("{0:N1} GB" -f ($cs.TotalPhysicalMemory / 1GB))
Row 'PowerShell' $PSVersionTable.PSVersion.ToString()

$wt = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
Row 'Windows Terminal' $(if ($wt) { $wt.Version } else { $null })

$claude = Get-Command claude -ErrorAction SilentlyContinue
Row 'claude path' $(if ($claude) { $claude.Source } else { $null })
Row 'claude --version' $(if ($claude) { Try-Command { claude --version } } else { $null })
Row 'git --version (Git Bash for Claude Code)' (Try-Command { git --version })
Row 'curl.exe --version' (Try-Command { (curl.exe --version | Select-Object -First 1) })

Row 'rustc --version' (Try-Command { rustc --version })
Row 'cargo --version' (Try-Command { cargo --version })
Row 'cmake --version' (Try-Command { (cmake --version | Select-Object -First 1) })
Row 'MSVC (cl.exe)' (Try-Command { (cmd /c 'cl 2>&1' | Select-Object -First 1) })

$langs = (Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) -join ', '
Row 'User languages' $langs
try {
    Add-Type -AssemblyName System.Speech
    $recognizers = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() |
        ForEach-Object { "$($_.Culture.Name): $($_.Description)" }
    Row 'SAPI recognizers (System.Speech)' ($recognizers -join '; ')
} catch {
    Row 'SAPI recognizers (System.Speech)' '(System.Speech unavailable in this PowerShell; use Windows PowerShell 5.1)'
}
$caps = Get-WindowsCapability -Online -Name 'Language.Speech*' -ErrorAction SilentlyContinue |
    Where-Object { $_.State -eq 'Installed' } | ForEach-Object { $_.Name }
Row 'Installed speech capabilities' ($caps -join ', ')

$pads = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'DualSense|Wireless Controller|Sony' -or $_.InstanceId -match 'VID_054C' } |
    ForEach-Object { "$($_.Class): $($_.FriendlyName) [$($_.InstanceId)]" }
Row 'DualSense devices present (VID 054C)' ($pads -join '; ')
