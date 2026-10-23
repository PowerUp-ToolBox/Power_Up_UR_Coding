# S6 check S: drives `claude -p` in stream-json mode with the exact flags PowerUp
# uses (ClaudeService.swift) and the nested control-request envelope (DESIGN.md
# v1.1A), and records every stdout line. Throwaway spike code (#133).
# Windows PowerShell 5.1 or PowerShell 7. Spends a few cents of real usage.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File stream-json-probe.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File stream-json-probe.ps1 -FlatShapeControl
#
# Default run, in order (each step waits for its answer, with a timeout):
#   S1  user turn "Reply with exactly the word pong."      expect system/init, then result
#   S2  control_request set_permission_mode {mode: plan}    expect control_response success
#   S3  control_request set_model {model: <-SwitchModel>}   expect control_response success
#   S4  control_request set_effort (does not exist)         expect control_response error, process alive
#   S5  user turn "Count slowly from 1 to 50, one per line." then interrupt
#                                                           expect control_response success, then result
#   S6  close stdin                                         expect clean exit
# -FlatShapeControl instead sends ONLY the flat {"type":"control_request","subtype":"interrupt"}
# which kills the CLI on macOS (exit 1, "Missing request on control_request"); it checks parity.
param(
    [string]$ClaudePath = '',
    [string]$SwitchModel = 'haiku',
    [string]$OutDir = (Join-Path $PSScriptRoot 'results'),
    [int]$TurnTimeoutSec = 180,
    [int]$ControlTimeoutSec = 30,
    [switch]$FlatShapeControl
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$tag = if ($FlatShapeControl) { 'flat' } else { 'nested' }
$transcript = Join-Path $OutDir "stream-json-$tag.jsonl"
$stderrFile = Join-Path $OutDir "stream-json-$tag.stderr.txt"
[System.IO.File]::WriteAllText($transcript, '', $utf8)

if ($ClaudePath -eq '') {
    $cmd = Get-Command claude -ErrorAction Stop
    $ClaudePath = $cmd.Source
}
$flags = @('-p', '--verbose', '--input-format', 'stream-json', '--output-format', 'stream-json', '--include-partial-messages')
$psi = New-Object System.Diagnostics.ProcessStartInfo
if ($ClaudePath -match '\.(cmd|bat)$') {
    # npm-style shim: go through cmd.exe so stdin/stdout still reach node.
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /s /c ""' + $ClaudePath + '" ' + ($flags -join ' ') + '"'
} else {
    $psi.FileName = $ClaudePath
    $psi.Arguments = $flags -join ' '
}
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$psi.WorkingDirectory = $OutDir

Write-Host "spawning: $($psi.FileName) $($psi.Arguments)"
$proc = [System.Diagnostics.Process]::Start($psi)
$stderrTask = $proc.StandardError.ReadToEndAsync()
$stdin = $proc.StandardInput.BaseStream
$script:pending = $null
$results = [ordered]@{}
$script:sawInit = $false

function Write-Line([string]$json) {
    $bytes = $utf8.GetBytes($json + "`n")
    $stdin.Write($bytes, 0, $bytes.Length)
    $stdin.Flush()
    [System.IO.File]::AppendAllText($transcript, '>> ' + $json + "`n", $utf8)
    Write-Host ">> $json"
}

# Returns @{ line = <string or $null>; eof = <bool>; timeout = <bool> }
function Read-Line([int]$timeoutMs) {
    if ($null -eq $script:pending) { $script:pending = $proc.StandardOutput.ReadLineAsync() }
    if (-not $script:pending.Wait($timeoutMs)) { return @{ line = $null; eof = $false; timeout = $true } }
    $line = $script:pending.Result
    $script:pending = $null
    if ($null -eq $line) { return @{ line = $null; eof = $true; timeout = $false } }
    [System.IO.File]::AppendAllText($transcript, '<< ' + $line + "`n", $utf8)
    return @{ line = $line; eof = $false; timeout = $false }
}

# Reads lines until $predicate returns true for a parsed message. Notes system/init on the way.
function Wait-For([scriptblock]$predicate, [int]$timeoutSec, [string]$label) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $remaining = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
        $r = Read-Line $remaining
        if ($r.eof) { return @{ ok = $false; why = 'EOF (process closed stdout)'; msg = $null } }
        if ($r.timeout) { break }
        try { $msg = $r.line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($msg.type -eq 'system' -and $msg.subtype -eq 'init' -and -not $script:sawInit) {
            $script:sawInit = $true
            $results['init'] = "PASS session_id=$($msg.session_id) model=$($msg.model) cwd=$($msg.cwd)"
            Write-Host "<< system/init session_id=$($msg.session_id) model=$($msg.model)"
        }
        if (& $predicate $msg) { return @{ ok = $true; why = ''; msg = $msg } }
    }
    return @{ ok = $false; why = "timeout after $timeoutSec s waiting for $label"; msg = $null }
}

function User([string]$text) {
    $envelope = [ordered]@{
        type               = 'user'
        message            = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'text'; text = $text }) }
        parent_tool_use_id = $null
    }
    Write-Line ($envelope | ConvertTo-Json -Compress -Depth 8)
}

function Control([string]$id, [hashtable]$request) {
    $envelope = [ordered]@{ type = 'control_request'; request_id = $id; request = $request }
    Write-Line ($envelope | ConvertTo-Json -Compress -Depth 8)
}

function Is-Response($msg, [string]$id) {
    $msg.type -eq 'control_response' -and $msg.response.request_id -eq $id
}

if ($FlatShapeControl) {
    Write-Line '{"type":"control_request","subtype":"interrupt"}'
    $exited = $proc.WaitForExit(30000)
    $stdin.Close()
    if (-not $exited) { $proc.Kill(); $results['flat'] = 'process still alive after 30 s (killed by probe)' }
    else { $results['flat'] = "exited with code $($proc.ExitCode)" }
} else {
    User 'Reply with exactly the word pong.'
    $r = Wait-For { param($m) $m.type -eq 'result' } $TurnTimeoutSec 'result of turn 1'
    if (-not $results.Contains('init')) { $results['init'] = 'FAIL no system/init seen before the first result' }
    $results['S1 turn'] = if ($r.ok) { "PASS subtype=$($r.msg.subtype) is_error=$($r.msg.is_error) result=$($r.msg.result)" } else { "FAIL $($r.why)" }

    Control 'S2' @{ subtype = 'set_permission_mode'; mode = 'plan' }
    $r = Wait-For { param($m) Is-Response $m 'S2' } $ControlTimeoutSec 'control_response S2'
    $results['S2 set_permission_mode'] = if ($r.ok) { "$(if ($r.msg.response.subtype -eq 'success') { 'PASS' } else { 'FAIL' }) $($r.msg.response | ConvertTo-Json -Compress -Depth 6)" } else { "FAIL $($r.why)" }

    Control 'S3' @{ subtype = 'set_model'; model = $SwitchModel }
    $r = Wait-For { param($m) Is-Response $m 'S3' } $ControlTimeoutSec 'control_response S3'
    $results['S3 set_model'] = if ($r.ok) { "$(if ($r.msg.response.subtype -eq 'success') { 'PASS' } else { 'FAIL' }) $($r.msg.response | ConvertTo-Json -Compress -Depth 6)" } else { "FAIL $($r.why)" }

    Control 'S4' @{ subtype = 'set_effort'; effort = 'low' }
    $r = Wait-For { param($m) Is-Response $m 'S4' } $ControlTimeoutSec 'control_response S4'
    $alive = -not $proc.HasExited
    $results['S4 unknown subtype'] = if ($r.ok) { "$(if ($r.msg.response.subtype -eq 'error' -and $alive) { 'PASS' } else { 'FAIL' }) alive=$alive $($r.msg.response | ConvertTo-Json -Compress -Depth 6)" } else { "FAIL $($r.why) alive=$alive" }

    User 'Count slowly from 1 to 50, one number per line.'
    $r = Wait-For { param($m) $m.type -eq 'stream_event' -or $m.type -eq 'assistant' } $TurnTimeoutSec 'first streamed output of turn 2'
    Control 'S5' @{ subtype = 'interrupt' }
    $script:ack = $null
    $r = Wait-For { param($m) if (Is-Response $m 'S5') { $script:ack = $m }; $m.type -eq 'result' } $TurnTimeoutSec 'result of interrupted turn 2'
    $ackText = if ($script:ack) { $script:ack.response | ConvertTo-Json -Compress -Depth 6 } else { 'no control_response for S5' }
    $results['S5 interrupt'] = if ($r.ok -and $script:ack -and $script:ack.response.subtype -eq 'success') { "PASS ack=$ackText result.subtype=$($r.msg.subtype)" } else { "FAIL ack=$ackText $($r.why)" }

    $stdin.Close()
    $exited = $proc.WaitForExit(30000)
    if (-not $exited) { $proc.Kill() }
    $results['S6 exit'] = if ($exited) { "exit code $($proc.ExitCode)" } else { 'did not exit within 30 s after stdin closed (killed by probe)' }
}

[void]$stderrTask.Wait(5000)
$stderrText = if ($stderrTask.IsCompleted) { $stderrTask.Result } else { '' }
[System.IO.File]::WriteAllText($stderrFile, $stderrText, $utf8)

Write-Host ''
Write-Host "== S6 stream-json probe ($tag)"
foreach ($k in $results.Keys) { Write-Host ("{0,-24} {1}" -f $k, $results[$k]) }
Write-Host "stderr (first 400 chars): $($stderrText.Substring(0, [Math]::Min(400, $stderrText.Length)))"
Write-Host "transcript: $transcript"
