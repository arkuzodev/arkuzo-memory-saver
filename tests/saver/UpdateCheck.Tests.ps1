#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false))
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw ('FAIL: '+$Message) } }

# Check that version check helpers exist in source
foreach ($name in @('Get-ArkuzoVersionNumber', 'Test-ArkuzoUpdateAvailable', 'Update-ArkuzoVersionCheck')) {
    $definition=@($definitions | Where-Object {$_.Name -ceq $name})
    Assert ($definition.Count -eq 1) ($name+' is missing from Arkuzo-Memory-Saver.ps1')
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

# 1. Version parsing tests
$v1 = Get-ArkuzoVersionNumber 'v1.0.5'
Assert ($null -ne $v1 -and $v1.Major -eq 1 -and $v1.Minor -eq 0 -and $v1.Build -eq 5) 'v1.0.5 must parse correctly'
$v2 = Get-ArkuzoVersionNumber '1.0.6'
Assert ($null -ne $v2 -and $v2.Major -eq 1 -and $v2.Minor -eq 0 -and $v2.Build -eq 6) '1.0.6 without v prefix must parse correctly'
Assert ($null -eq (Get-ArkuzoVersionNumber 'invalid')) 'Invalid version string must return $null'
Assert ($null -eq (Get-ArkuzoVersionNumber '')) 'Empty version string must return $null'

# 2. Update available detection
$mockNewer = { '{"tag_name": "v1.0.6", "draft": false, "prerelease": false}' }
$res = Test-ArkuzoUpdateAvailable -CurrentVersion '1.0.5' -FetchDelegate $mockNewer
Assert ($res.available -eq $true) 'Newer version v1.0.6 over 1.0.5 must be marked available'
Assert ($res.latestVersion -eq 'v1.0.6') 'Latest version must match tag'
Assert ($res.message -match 'UPDATE.*v1\.0\.6.*restart to update') 'Update message must prompt to restart to update'

# 3. Same or older version must NOT trigger update
$mockSame = { '{"tag_name": "v1.0.5", "draft": false, "prerelease": false}' }
$resSame = Test-ArkuzoUpdateAvailable -CurrentVersion '1.0.5' -FetchDelegate $mockSame
Assert ($resSame.available -eq $false) 'Same version must not trigger update'

$mockOlder = { '{"tag_name": "v1.0.4", "draft": false, "prerelease": false}' }
$resOlder = Test-ArkuzoUpdateAvailable -CurrentVersion '1.0.5' -FetchDelegate $mockOlder
Assert ($resOlder.available -eq $false) 'Older version must not trigger update'

# 4. Draft and prerelease ignored
$mockDraft = { '{"tag_name": "v1.0.7", "draft": true, "prerelease": false}' }
$resDraft = Test-ArkuzoUpdateAvailable -CurrentVersion '1.0.5' -FetchDelegate $mockDraft
Assert ($resDraft.available -eq $false) 'Draft release must be ignored'

$mockPrerelease = { '{"tag_name": "v1.0.7", "draft": false, "prerelease": true}' }
$resPre = Test-ArkuzoUpdateAvailable -CurrentVersion '1.0.5' -FetchDelegate $mockPrerelease
Assert ($resPre.available -eq $false) 'Prerelease must be ignored'

# 5. Network / parsing error resilience (fail-soft, silent)
$mockError = { throw 'Simulated network timeout' }
$resErr = Test-ArkuzoUpdateAvailable -CurrentVersion '1.0.5' -FetchDelegate $mockError
Assert ($resErr.available -eq $false) 'Network error must fail soft with available=false'
Assert ($resErr.error -match 'Simulated network timeout') 'Error must be captured in error property'

# 6. Status tracking integration (badge replaces dashboard issues)
$script:dashboardIssues = @{}
$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:diagnosticCalls = @()
function Write-Diagnostic($kind, $data) { $script:diagnosticCalls += @{ kind = $kind; data = $data } }

Update-ArkuzoVersionCheck -FetchDelegate $mockNewer -CurrentVersion '1.0.5'
Assert ($null -ne $script:updateAvailableStatus -and $script:updateAvailableStatus.available) 'updateAvailableStatus must be available for newer version'
Assert (-not $script:dashboardIssues.ContainsKey('update-available')) 'Dashboard issues must NOT contain update-available banner'
Assert ($script:updateAvailableStatus.latestVersion -eq 'v1.0.6') 'Latest version must match tag'

Write-Output 'PASS: Version check tests passed completely.'
