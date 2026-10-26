# S6 check H, fallback variant: reads the hook payload from stdin and posts it to
# the listener with the X-PowerUp-Token header. Always exits 0 so Claude Code is
# never blocked. Installed by: install-hooks.ps1 -Variant relay
param([int]$Port = 47800, [string]$Token = 'spike-token-7f3a')
try {
    $stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    $payload = $stdin.ReadToEnd()
    $request = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/event")
    $request.Method = 'POST'
    $request.ContentType = 'application/json'
    $request.Timeout = 2000
    $request.Headers.Add('X-PowerUp-Token', $Token)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($payload)
    $request.ContentLength = $bytes.Length
    $body = $request.GetRequestStream()
    $body.Write($bytes, 0, $bytes.Length)
    $body.Close()
    $request.GetResponse().Close()
} catch { }
exit 0
