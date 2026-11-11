#requires -Version 5.1
# A login saved by the Roblox app makes every ticket launch fail: the client loads
# it and its web login answers 403 (9 Nov, 21:48 on, every account). Before a
# launch the saver moves RobloxCookies.dat aside, but only when it holds a
# .ROBLOSECURITY cookie. Runs against a temporary folder, never this PC's Roblox.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($f.Name -eq 'Clear-ArkuzoRobloxSavedLogin') { . ([scriptblock]::Create($f.Extent.Text)) }
}
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
Add-Type -AssemblyName System.Security

function Write-Jar([string]$Dir, [string[]]$Cookies) {
    # Roblox's format: JSON with DPAPI (current user, no entropy) Netscape cookie lines.
    $lines = @('# Netscape HTTP Cookie File') + @($Cookies | ForEach-Object { "#HttpOnly_.roblox.com`tTRUE`t/`tTRUE`t0`t$_`tVALUE-$_" })
    $data = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($lines -join "`n"), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllText((Join-Path $Dir 'RobloxCookies.dat'), (@{ CookiesVersion = '1'; CookiesData = [Convert]::ToBase64String($data) } | ConvertTo-Json -Compress))
}

$dir = Join-Path ([IO.Path]::GetTempPath()) ('roblox-saved-login-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($dir) | Out-Null
try {
    $jar = Join-Path $dir 'RobloxCookies.dat'; $backup = $jar + '.arkuzo-saved-login'
    Assert (-not (Clear-ArkuzoRobloxSavedLogin $dir)) 'no cookie file: nothing to do'

    # What ticket-launched clients write: no login, left alone.
    Write-Jar $dir @('RBXEventTrackerV2')
    Assert (-not (Clear-ArkuzoRobloxSavedLogin $dir) -and (Test-Path $jar) -and -not (Test-Path $backup)) 'a cookie file without a login is left alone'

    # The Roblox app signed in: the file is moved aside, with its contents intact.
    Write-Jar $dir @('RBXEventTrackerV2', '.ROBLOSECURITY')
    $before = [IO.File]::ReadAllText($jar)
    Assert (Clear-ArkuzoRobloxSavedLogin $dir) 'a saved login is moved aside'
    Assert (-not (Test-Path $jar) -and (Test-Path $backup) -and [IO.File]::ReadAllText($backup) -ceq $before) 'kept as RobloxCookies.dat.arkuzo-saved-login, unchanged'
    Assert (-not (Clear-ArkuzoRobloxSavedLogin $dir)) 'nothing left to move on the next launch'

    # A later sign-in replaces the older backup instead of failing.
    Write-Jar $dir @('.ROBLOSECURITY')
    $second = [IO.File]::ReadAllText($jar)
    Assert ((Clear-ArkuzoRobloxSavedLogin $dir) -and [IO.File]::ReadAllText($backup) -ceq $second) 'the newest saved login replaces the older backup'

    # Unreadable files never block a launch and are never moved.
    [IO.File]::WriteAllText($jar, 'not json')
    Assert (-not (Clear-ArkuzoRobloxSavedLogin $dir) -and (Test-Path $jar)) 'a corrupt file is left alone, no error'
    [IO.File]::WriteAllText($jar, '{"CookiesVersion":"1","CookiesData":"bm90LWRwYXBp"}')
    Assert (-not (Clear-ArkuzoRobloxSavedLogin $dir) -and (Test-Path $jar)) 'a file that does not decrypt is left alone, no error'
    Assert (-not (Clear-ArkuzoRobloxSavedLogin '')) 'no Roblox folder: nothing to do'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PASS: a login saved by the Roblox app is moved aside before a launch, nothing else is touched ($checks checks)"
