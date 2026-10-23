# S5: transcribes every clip with the Windows desktop speech recognizer
# (System.Speech / SAPI, offline, dictation grammar) for the given culture.
# It takes WAV files directly, unlike Windows.Media.SpeechRecognition (WinRT),
# which only listens to a live microphone (see run-winrt-live.ps1).
# Throwaway spike code (#135). Requires Windows PowerShell 5.1 (powershell.exe):
# System.Speech is part of .NET Framework, not of PowerShell 7.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-sapi.ps1                  # zh-CN
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-sapi.ps1 -Culture en-US   # optional second row
#
# Output: results\sapi-<culture>\clipNN.txt and rows in results\timings.csv.
# wall_ms = SetInputToWaveFile to last phrase (engine already loaded; file input is
# processed as fast as the engine can, not in real time). load_ms = engine load, once.
param(
    [string]$Culture = 'zh-CN',
    [string]$ClipDir = (Join-Path $PSScriptRoot 'clips'),
    [string]$ResultDir = (Join-Path $PSScriptRoot 'results')
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Speech

$installed = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
Write-Host 'installed SAPI recognizers:'
$installed | ForEach-Object { Write-Host "  $($_.Culture.Name)  $($_.Description)  [$($_.Id)]" }
$info = $installed | Where-Object { $_.Culture.Name -eq $Culture } | Select-Object -First 1
if ($null -eq $info) {
    throw "no SAPI recognizer for $Culture. Settings > Time & language > Language & region > $Culture > Language options > Speech recognition: install, then re-run. If none can be installed, record 'not available' in the S5 record."
}

$label = "sapi-$Culture"
$outDir = Join-Path $ResultDir $label
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$timings = Join-Path $ResultDir 'timings.csv'
if (-not (Test-Path $timings)) { [System.IO.File]::WriteAllText($timings, "engine,clip,wall_ms,load_ms,engine_total_ms`n", $utf8) }

$loadWatch = [System.Diagnostics.Stopwatch]::StartNew()
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine($info)
$engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
$loadWatch.Stop()
Write-Host "engine: $($info.Description), loaded in $($loadWatch.ElapsedMilliseconds) ms"

$clips = Get-ChildItem $ClipDir -Filter 'clip*.wav' | Sort-Object Name
foreach ($clip in $clips) {
    $id = [IO.Path]::GetFileNameWithoutExtension($clip.Name)
    $duration = ($clip.Length - 44) / 32000.0
    $texts = New-Object System.Collections.Generic.List[string]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $engine.SetInputToWaveFile($clip.FullName)
    $guard = 0
    while ($guard -lt 40) {
        $guard++
        $before = $engine.RecognizerAudioPosition
        $result = $engine.Recognize()
        if ($null -ne $result) { $texts.Add($result.Text) }
        $after = $engine.RecognizerAudioPosition
        if ($after.TotalSeconds -ge ($duration - 0.2)) { break }
        if ($null -eq $result -and $after -eq $before) { break }
    }
    $sw.Stop()
    $engine.SetInputToNull()
    $text = ($texts -join ' ').Trim()
    [System.IO.File]::WriteAllText((Join-Path $outDir "$id.txt"), $text, $utf8)
    [System.IO.File]::AppendAllText($timings, "$label,$id,$($sw.ElapsedMilliseconds),$($loadWatch.ElapsedMilliseconds),`n", $utf8)
    Write-Host ("{0}  wall={1} ms  {2}" -f $id, $sw.ElapsedMilliseconds, $text)
}
$engine.Dispose()
