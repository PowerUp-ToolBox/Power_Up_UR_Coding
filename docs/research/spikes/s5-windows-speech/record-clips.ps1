# S5: records the ten corpus sentences as 16 kHz mono 16-bit PCM WAV files with
# ffmpeg (used only as a recording tool; nothing links it). Throwaway spike code (#135).
# Windows PowerShell 5.1 or PowerShell 7.
#
#   ffmpeg -hide_banner -list_devices true -f dshow -i dummy      # find your microphone's name
#   powershell -NoProfile -ExecutionPolicy Bypass -File record-clips.ps1 -Device "Microphone (USB Audio)"
#   powershell -NoProfile -ExecutionPolicy Bypass -File record-clips.ps1 -Device "..." -Only clip04
#
# For each sentence: read it on screen, press Enter, speak within half a second,
# then press q in this window as soon as you finish (hard cap -MaxSeconds).
param(
    [Parameter(Mandatory = $true)][string]$Device,
    [string]$Corpus = (Join-Path $PSScriptRoot 'corpus.tsv'),
    [string]$OutDir = (Join-Path $PSScriptRoot 'clips'),
    [int]$MaxSeconds = 12,
    [string]$Only = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg not on PATH (winget install Gyan.FFmpeg, then open a new terminal)' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$rows = [System.IO.File]::ReadAllLines($Corpus, [System.Text.Encoding]::UTF8) | Select-Object -Skip 1 |
    Where-Object { $_.Trim() -ne '' } | ForEach-Object { $c = $_ -split "`t"; [pscustomobject]@{ id = $c[0]; text = $c[1] } }

foreach ($row in $rows) {
    if ($Only -ne '' -and $row.id -ne $Only) { continue }
    $wav = Join-Path $OutDir "$($row.id).wav"
    Write-Host ''
    Write-Host "[$($row.id)]  $($row.text)"
    Read-Host 'press Enter, then speak; press q when done'
    & ffmpeg -hide_banner -loglevel error -f dshow -i "audio=$Device" -ac 1 -ar 16000 -sample_fmt s16 -t $MaxSeconds -y $wav
    $seconds = ((Get-Item $wav).Length - 44) / 32000.0
    Write-Host ("saved {0}  ~{1:N1} s" -f $wav, $seconds)
    if ($seconds -lt 3 -or $seconds -gt 11) { Write-Host 'WARNING: outside 5-10 s; re-record with -Only' $row.id }
}

$sums = Get-ChildItem $OutDir -Filter 'clip*.wav' | Sort-Object Name | ForEach-Object {
    $h = Get-FileHash -Algorithm SHA256 $_.FullName
    '{0}  {1}  {2:N1}s' -f $h.Hash.ToLowerInvariant(), $_.Name, (($_.Length - 44) / 32000.0)
}
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'SHA256SUMS.txt'), [string[]]$sums)
Write-Host ''
$sums | ForEach-Object { Write-Host $_ }
