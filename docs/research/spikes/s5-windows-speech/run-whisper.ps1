# S5: transcribes every clip with whisper.cpp's whisper-cli, one process per clip
# (the way the planned Windows adapter would run it), and records wall-clock latency.
# Throwaway spike code (#135). Windows PowerShell 5.1 or PowerShell 7.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-whisper.ps1 -WhisperCli C:\tools\whisper\whisper-cli.exe -Model C:\tools\whisper\ggml-small.bin -Label whisper-small
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-whisper.ps1 -WhisperCli ... -Model ...\ggml-base.bin -Label whisper-base
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-whisper.ps1 -WhisperCli ... -Model ...\ggml-small.bin -Label whisper-small-prompt -Prompt "parseConfig, ControllerService, setLight, useEffect, userId, HookInstaller, settingsURL, git rebase, commit, JSON, guard let, control_request"
#
# Output: results\<Label>\clipNN.txt (transcript), results\<Label>\clipNN.stderr.txt,
# and one row per clip appended to results\timings.csv:
#   engine,clip,wall_ms,load_ms,engine_total_ms
# wall_ms = process start to exit (includes model load: one process per utterance).
# load_ms / engine_total_ms are parsed from whisper's own timing lines (blank if absent).
param(
    [Parameter(Mandatory = $true)][string]$WhisperCli,
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$Language = 'auto',
    [string]$Prompt = '',
    [int]$Threads = 0,
    [string]$ClipDir = (Join-Path $PSScriptRoot 'clips'),
    [string]$ResultDir = (Join-Path $PSScriptRoot 'results')
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
if ($Threads -le 0) { $Threads = [Math]::Min(8, [Environment]::ProcessorCount) }
$outDir = Join-Path $ResultDir $Label
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$timings = Join-Path $ResultDir 'timings.csv'
if (-not (Test-Path $timings)) { [System.IO.File]::WriteAllText($timings, "engine,clip,wall_ms,load_ms,engine_total_ms`n", $utf8) }

function Quote([string]$s) { '"' + ($s -replace '"', '\"') + '"' }

function Invoke-Whisper([string]$wav, [string]$prefix) {
    $argList = @('-m', (Quote $Model), '-f', (Quote $wav), '-l', $Language, '-t', $Threads, '-nt', '-otxt', '-of', (Quote $prefix))
    if ($Prompt -ne '') { $argList += @('--prompt', (Quote $Prompt)) }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WhisperCli
    $psi.Arguments = $argList -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $sw.Stop()
    return @{ wall = $sw.ElapsedMilliseconds; exit = $p.ExitCode; stdout = $outTask.Result; stderr = $errTask.Result }
}

function Parse-Ms([string]$text, [string]$label) {
    $m = [regex]::Match($text, [regex]::Escape($label) + '\s*=\s*([0-9.]+)\s*ms')
    if ($m.Success) { return [string][Math]::Round([double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)) }
    return ''
}

$clips = Get-ChildItem $ClipDir -Filter 'clip*.wav' | Sort-Object Name
if ($clips.Count -eq 0) { throw "no clip*.wav in $ClipDir" }

Write-Host "warm-up (discarded): $($clips[0].Name)"
[void](Invoke-Whisper $clips[0].FullName (Join-Path $env:TEMP 's5-warmup'))

foreach ($clip in $clips) {
    $id = [IO.Path]::GetFileNameWithoutExtension($clip.Name)
    $prefix = Join-Path $outDir $id
    $r = Invoke-Whisper $clip.FullName $prefix
    [System.IO.File]::WriteAllText("$prefix.stderr.txt", $r.stderr, $utf8)
    if ($r.exit -ne 0) { Write-Host "$id FAILED exit=$($r.exit); see $prefix.stderr.txt"; continue }
    $load = Parse-Ms $r.stderr 'load time'
    $total = Parse-Ms $r.stderr 'total time'
    [System.IO.File]::AppendAllText($timings, "$Label,$id,$($r.wall),$load,$total`n", $utf8)
    $text = if (Test-Path "$prefix.txt") { ([System.IO.File]::ReadAllText("$prefix.txt", $utf8)).Trim() } else { '(no txt output)' }
    Write-Host ("{0}  wall={1} ms  load={2} ms  total={3} ms  {4}" -f $id, $r.wall, $load, $total, $text)
}
