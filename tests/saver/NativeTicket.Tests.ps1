#requires -Version 5.1
# The launch-ticket request runs off the main loop: the real runspace job against a local
# endpoint (an ephemeral port on 127.0.0.1) that answers like auth.roblox.com, slowly.
# Roblox is never contacted; the cookie and ticket are synthetic.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($name in @('Invoke-ArkuzoRobloxPost', 'Get-ArkuzoAuthTicket', 'Start-ArkuzoNativeTicketJob', 'Receive-ArkuzoNativeTicketJob', 'Stop-ArkuzoNativeTicketJob')) {
    $f = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name }, $false))
    if ($f.Count -ne 1) { throw "$name must exist exactly once" }
    . ([scriptblock]::Create($f[0].Extent.Text))
}
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
$script:NativeUserAgent = 'arkuzo-test'

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$url = "http://127.0.0.1:$port/v1/authentication-ticket"
function Accept-Request {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not $listener.Pending()) { if ($deadline.Elapsed.TotalSeconds -gt 15) { throw 'no request arrived' }; Start-Sleep -Milliseconds 20 }
    $client = $listener.AcceptTcpClient()
    $stream = $client.GetStream(); $stream.ReadTimeout = 10000
    $buffer = New-Object byte[] 8192; $text = ''
    while ($text -notmatch "`r`n`r`n") { $n = $stream.Read($buffer, 0, $buffer.Length); if ($n -le 0) { break }; $text += [Text.Encoding]::ASCII.GetString($buffer, 0, $n) }
    if ($text -match 'Content-Length:\s*(\d+)') { $want = [int]$matches[1]; $have = $text.Length - ($text.IndexOf("`r`n`r`n") + 4); while ($have -lt $want) { $n = $stream.Read($buffer, 0, $buffer.Length); if ($n -le 0) { break }; $have += $n } }
    return @{ Client = $client; Stream = $stream; Text = $text }
}
function Send-Response($Request, [string]$Head) {
    $bytes = [Text.Encoding]::ASCII.GetBytes($Head + "Content-Length: 0`r`nConnection: close`r`n`r`n")
    $Request.Stream.Write($bytes, 0, $bytes.Length); $Request.Stream.Flush(); $Request.Client.Close()
}
function Wait-Result($Job) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.Elapsed.TotalSeconds -lt 15) { $r = Receive-ArkuzoNativeTicketJob $Job; if ($null -ne $r) { return $r }; Start-Sleep -Milliseconds 20 }
    throw 'ticket job never finished'
}

try {
    $cookie = 'FAKE-COOKIE-' + ('c' * 30)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $job = Start-ArkuzoNativeTicketJob $cookie $url
    Assert ($sw.Elapsed.TotalMilliseconds -lt 2000) 'starting the ticket request returns at once'
    Assert ($null -eq (Receive-ArkuzoNativeTicketJob $job)) 'no result while Roblox has not answered'
    $first = Accept-Request
    Assert ($first.Text -match '(?m)^POST /v1/authentication-ticket' -and $first.Text -match ('Cookie: \.ROBLOSECURITY=' + [regex]::Escape($cookie)) -and $first.Text -notmatch 'X-CSRF-TOKEN') 'first request carries the cookie, no CSRF token yet'
    Assert ($first.Text -match 'User-Agent: arkuzo-test') 'the engine''s user agent is used'
    # Roblox is slow: the caller (the main loop) keeps running meanwhile.
    Start-Sleep -Milliseconds 600
    Assert ($null -eq (Receive-ArkuzoNativeTicketJob $job)) 'still no result while the request is pending: the loop is not blocked'
    Send-Response $first "HTTP/1.1 403 Forbidden`r`nx-csrf-token: tok-42`r`n"
    $second = Accept-Request
    Assert ($second.Text -match 'X-CSRF-TOKEN: tok-42') 'second request answers the CSRF handshake'
    Send-Response $second ("HTTP/1.1 200 OK`r`nrbx-authentication-ticket: TICKET-XYZ`r`nSet-Cookie: .ROBLOSECURITY=ROTATED-" + ('r' * 20) + "; domain=.roblox.com; path=/`r`n")
    $r = Wait-Result $job
    Assert ($r.status -eq 200 -and $r.ticket -ceq 'TICKET-XYZ') 'the ticket comes back from the runspace'
    Assert ($r.rotated -and $r.cookie -ceq ('ROTATED-' + ('r' * 20))) 'a rotated cookie comes back too'

    # A request Roblox never answers is abandoned without waiting for it.
    $job = Start-ArkuzoNativeTicketJob $cookie $url
    $hang = Accept-Request
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Stop-ArkuzoNativeTicketJob $job
    Assert ($sw.Elapsed.TotalMilliseconds -lt 1500) ('stopping a hung request does not block (' + [int]$sw.Elapsed.TotalMilliseconds + ' ms)')
    $hang.Client.Close()

    # No answer at all (connection refused) is status 0, not an exception.
    $listener.Stop()
    $r = Wait-Result (Start-ArkuzoNativeTicketJob $cookie $url)
    Assert ($r.status -eq 0) 'an unreachable endpoint gives status 0'
    Write-Host "PASS: the launch ticket is requested off the loop thread, with the CSRF handshake and cookie rotation ($script:checks checks)"
} finally {
    try { $listener.Stop() } catch { }
}
