#requires -Version 5.1
# The launch-ticket request recognises a moderated account. On 9 Nov Roblox
# moderated 10 farm accounts; auth.roblox.com answered 403 "User is moderated"
# and the saver retried each of them as if the refusal were temporary.
# The real Invoke-ArkuzoRobloxPost runs against a local HTTP listener.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($f.Name -in 'Invoke-ArkuzoRobloxPost', 'Get-ArkuzoAuthTicket') { . ([scriptblock]::Create($f.Extent.Text)) }
}
$script:NativeUserAgent = 'test'
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }

# Free port, then a listener answering like auth.roblox.com in a background runspace.
$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$prefix = "http://127.0.0.1:$port/"
$listener = New-Object Net.HttpListener; $listener.Prefixes.Add($prefix); $listener.Start()
$ps = [PowerShell]::Create()
[void]$ps.AddScript({
    param($listener)
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        $path = $ctx.Request.Url.AbsolutePath; $csrf = $ctx.Request.Headers['X-CSRF-TOKEN']
        $res = $ctx.Response
        if (-not $csrf) { $res.StatusCode = 403; $res.Headers.Add('x-csrf-token', 'tok-1'); $body = '{"errors":[{"code":0,"message":"Token Validation Failed"}]}' }
        elseif ($path -eq '/moderated') { $res.StatusCode = 403; $res.Headers.Add('Set-Cookie', '.ROBLOSECURITY=ROTATED-COOKIE; path=/'); $body = '{"errors":[{"code":0,"message":"User is moderated"}]}' }
        elseif ($path -eq '/forbidden') { $res.StatusCode = 403; $body = '{"errors":[{"code":0,"message":"Forbidden"}]}' }
        else { $res.StatusCode = 200; $res.Headers.Add('rbx-authentication-ticket', 'TICKET-OK'); $body = '{}' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($body); $res.ContentLength64 = $bytes.Length; $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.Close()
    }
}).AddArgument($listener)
$async = $ps.BeginInvoke()
try {
    # Get-ArkuzoAuthTicket always posts to auth.roblox.com; drive the same handshake by hand.
    $first = Invoke-ArkuzoRobloxPost ($prefix + 'moderated') 'COOKIE'
    Assert ($first.status -eq 403 -and $first.csrf -eq 'tok-1' -and -not $first.moderated) 'the CSRF 403 is not moderation'
    $second = Invoke-ArkuzoRobloxPost ($prefix + 'moderated') 'COOKIE' $first.csrf
    Assert ($second.status -eq 403 -and $second.moderated) '403 "User is moderated" is recognised'
    Assert ($second.rotated -ceq 'ROTATED-COOKIE') 'a cookie re-issued with it is still picked up'
    $other = Invoke-ArkuzoRobloxPost ($prefix + 'forbidden') 'COOKIE' 'tok-1'
    Assert ($other.status -eq 403 -and -not $other.moderated) 'another 403 is not taken for moderation'
    $ok = Invoke-ArkuzoRobloxPost ($prefix + 'ok') 'COOKIE' 'tok-1'
    Assert ($ok.status -eq 200 -and $ok.ticket -ceq 'TICKET-OK' -and -not $ok.moderated) 'a granted ticket is unchanged'
} finally {
    $listener.Stop(); $listener.Close()
    try { [void]$ps.EndInvoke($async) } catch { }
    $ps.Dispose()
}
Write-Host "PASS: a moderated account is recognised from the launch-ticket reply ($checks checks)"
