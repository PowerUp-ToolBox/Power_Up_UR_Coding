# S5 (optional row): Windows.Media.SpeechRecognition (WinRT) with free dictation.
# WinRT recognizers only listen to the live default microphone, so this script asks
# you to READ each corpus sentence aloud again; its numbers are therefore not
# file-for-file comparable with whisper/SAPI and the record must say so.
# Throwaway spike code (#135), untested on Windows. Requires Windows PowerShell 5.1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-winrt-live.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-winrt-live.ps1 -Language en-US -Only clip03
#
# Run it once with Settings > Privacy & security > Speech > "Online speech recognition"
# OFF (the offline question) and, if that fails, once with it ON (label the rows).
# Output: results\winrt-<lang>-<online|offline>\clipNN.txt and rows in results\timings.csv
# where wall_ms = RecognizeAsync start to result (includes your speaking time).
param(
    [string]$Language = 'zh-CN',
    [string]$Corpus = (Join-Path $PSScriptRoot 'corpus.tsv'),
    [string]$ResultDir = (Join-Path $PSScriptRoot 'results'),
    [string]$Only = ''
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
function Await($operation, [Type]$resultType) {
    $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($operation))
    [void]$task.Wait(-1)
    $task.Result
}

[void][Windows.Media.SpeechRecognition.SpeechRecognizer, Windows.Media.SpeechRecognition, ContentType = WindowsRuntime]
[void][Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

$online = $null
try { $online = (Get-ItemProperty 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -ErrorAction Stop).HasAccepted } catch { }
$mode = if ($online -eq 1) { 'online' } else { 'offline' }
Write-Host "Online speech recognition setting: $(if ($null -eq $online) { 'unknown (treated as offline)' } else { $online })"

$supported = [Windows.Media.SpeechRecognition.SpeechRecognizer]::SupportedTopicLanguages | ForEach-Object { $_.LanguageTag }
Write-Host "dictation (topic) languages: $($supported -join ', ')"

$lang = New-Object Windows.Globalization.Language($Language)
$recognizer = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer($lang)
$compile = Await ($recognizer.CompileConstraintsAsync()) ([Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult])
Write-Host "constraints compiled: $($compile.Status)"
if ("$($compile.Status)" -ne 'Success') { throw "compile failed: $($compile.Status) (record this in the S5 record)" }

$label = "winrt-$Language-$mode"
$outDir = Join-Path $ResultDir $label
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$timings = Join-Path $ResultDir 'timings.csv'
if (-not (Test-Path $timings)) { [System.IO.File]::WriteAllText($timings, "engine,clip,wall_ms,load_ms,engine_total_ms`n", $utf8) }

$rows = [System.IO.File]::ReadAllLines($Corpus, [System.Text.Encoding]::UTF8) | Select-Object -Skip 1 |
    Where-Object { $_.Trim() -ne '' } | ForEach-Object { $c = $_ -split "`t"; [pscustomobject]@{ id = $c[0]; text = $c[1] } }
foreach ($row in $rows) {
    if ($Only -ne '' -and $row.id -ne $Only) { continue }
    Write-Host ''
    Write-Host "[$($row.id)]  $($row.text)"
    Read-Host 'press Enter, then read the sentence aloud'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = Await ($recognizer.RecognizeAsync()) ([Windows.Media.SpeechRecognition.SpeechRecognitionResult])
        $sw.Stop()
        $text = "$($result.Text)".Trim()
        $status = "$($result.Status)"
    } catch {
        $sw.Stop()
        $text = ''
        $status = "error: $($_.Exception.InnerException.Message)"
    }
    [System.IO.File]::WriteAllText((Join-Path $outDir "$($row.id).txt"), $text, $utf8)
    [System.IO.File]::AppendAllText($timings, "$label,$($row.id),$($sw.ElapsedMilliseconds),,`n", $utf8)
    Write-Host ("{0}  status={1}  wall={2} ms  {3}" -f $row.id, $status, $sw.ElapsedMilliseconds, $text)
}
$recognizer.Dispose()
