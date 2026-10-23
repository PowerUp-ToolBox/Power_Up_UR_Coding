# S6 check K target: reads lines from the console and prints each line's UTF-16
# code units, so a split surrogate pair or a lost character is visible exactly.
# Run it in a Windows Terminal tab (PowerShell 7 `pwsh` preferred; Windows
# PowerShell 5.1 also works). Ctrl+C to quit.
#
#   pwsh -NoProfile -File echo-target.ps1
try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }
Write-Host 'echo target ready: focus this tab, then run send-unicode.ps1 from another window'
while ($true) {
    $line = [Console]::ReadLine()
    if ($null -eq $line) { break }
    $units = ($line.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '
    $lone = 0
    for ($i = 0; $i -lt $line.Length; $i++) {
        $c = $line[$i]
        if ([char]::IsHighSurrogate($c)) {
            if ($i + 1 -lt $line.Length -and [char]::IsLowSurrogate($line[$i + 1])) { $i++ } else { $lone++ }
        } elseif ([char]::IsLowSurrogate($c)) { $lone++ }
    }
    Write-Host ("got [{0}] units={1} loneSurrogates={2}" -f $line, $units, $lone)
}
