# S6 check H: a stand-in for PowerUp's hook drop box. Listens on 127.0.0.1:<Port>,
# accepts `POST /event`, checks the `X-PowerUp-Token` header exactly like PowerUp
# (NOT `Authorization: Bearer`), logs every request as one JSON line, answers
# 204 on a good token and 401 otherwise. Throwaway spike code (#133).
# Windows PowerShell 5.1 or PowerShell 7. Ctrl+C to stop.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File hook-listener.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File hook-listener.ps1 -Port 47800 -Token spike-token-7f3a
param(
    [int]$Port = 47800,
    [string]$Token = 'spike-token-7f3a',
    [string]$Out = (Join-Path $PSScriptRoot 'results\hook-events.jsonl'),
    [int]$MaxRequests = 0   # 0 = run until Ctrl+C (tests pass a small number)
)

$utf8 = New-Object System.Text.UTF8Encoding($false)
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Read-Request([System.Net.Sockets.NetworkStream]$stream) {
    $head = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { break }
        $head.Add([byte]$b)
        $n = $head.Count
        if ($n -ge 4 -and $head[$n - 4] -eq 13 -and $head[$n - 3] -eq 10 -and $head[$n - 2] -eq 13 -and $head[$n - 1] -eq 10) { break }
        if ($n -gt 65536) { break }
    }
    $lines = [System.Text.Encoding]::ASCII.GetString($head.ToArray()) -split "`r`n"
    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $idx = $lines[$i].IndexOf(':')
        if ($idx -gt 0) { $headers[$lines[$i].Substring(0, $idx).Trim().ToLowerInvariant()] = $lines[$i].Substring($idx + 1).Trim() }
    }
    if ($headers.ContainsKey('expect') -and $headers['expect'] -match '100-continue') {
        $cont = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
        $stream.Write($cont, 0, $cont.Length)
    }
    $length = 0
    if ($headers.ContainsKey('content-length')) { [void][int]::TryParse($headers['content-length'], [ref]$length) }
    $body = New-Object byte[] $length
    $read = 0
    while ($read -lt $length) {
        $r = $stream.Read($body, $read, $length - $read)
        if ($r -le 0) { break }
        $read += $r
    }
    return @{ RequestLine = $lines[0]; Headers = $headers; Body = $utf8.GetString($body, 0, $read) }
}

function Send-Response([System.Net.Sockets.NetworkStream]$stream, [int]$code, [string]$reason) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code $reason`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
    $stream.Write($bytes, 0, $bytes.Length)
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "hook listener on http://127.0.0.1:$Port/event  token header: X-PowerUp-Token: $Token"
Write-Host "logging to $Out"
$count = 0
try {
    while ($MaxRequests -le 0 -or $count -lt $MaxRequests) {
        $client = $listener.AcceptTcpClient()
        $count++
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $req = Read-Request $stream
            $tokenHeader = $req.Headers['x-powerup-token']
            $tokenOk = ($tokenHeader -ceq $Token)
            $pathOk = ($req.RequestLine -match '^POST /event(\?| )')
            $hookEvent = $null; $session = $null; $jsonOk = $false
            try {
                $parsed = $req.Body | ConvertFrom-Json -ErrorAction Stop
                $jsonOk = ($null -ne $parsed)
                $hookEvent = $parsed.hook_event_name
                $session = $parsed.session_id
            } catch { }
            if ($tokenOk -and $pathOk) { Send-Response $stream 204 'No Content' } else { Send-Response $stream 401 'Unauthorized' }
            $record = [ordered]@{
                at                  = (Get-Date).ToString('o')
                requestLine         = $req.RequestLine
                pathOk              = $pathOk
                tokenHeader         = $tokenHeader
                tokenOk             = $tokenOk
                authorizationHeader = $req.Headers['authorization']
                contentType         = $req.Headers['content-type']
                userAgent           = $req.Headers['user-agent']
                bodyBytes           = $utf8.GetByteCount($req.Body)
                jsonOk              = $jsonOk
                hook_event_name     = $hookEvent
                session_id          = $session
                body                = $req.Body
            }
            $line = ($record | ConvertTo-Json -Compress -Depth 4)
            [System.IO.File]::AppendAllText($Out, $line + "`n", $utf8)
            Write-Host ("{0}  {1,-18} token={2} json={3} bytes={4}  {5}" -f $record.at, "$hookEvent", $tokenOk, $jsonOk, $record.bodyBytes, $req.RequestLine)
        } catch {
            Write-Host "request error: $_"
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
