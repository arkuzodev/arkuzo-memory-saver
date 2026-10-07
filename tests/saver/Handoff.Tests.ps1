#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Controller does not parse'}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
    . ([scriptblock]::Create($f.Extent.Text))
}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
$script:recoveryPending=@{ 'account-test'=@{status='AwaitingReplacement';closedUtc=[datetime]::UtcNow.ToString('o')} }
$script:voltControlStatus=@{available=$true;globalMappingSafe=$true;accounts=@()};$script:voltControlCheckedUtc=[datetime]::UtcNow;$script:suspendedAccounts=@{}
# Backward compatibility fallback reproduces the old missing handoff gate.
$allowed=$true
if(Get-Command Test-ArkuzoRecoveryHandoff -ErrorAction SilentlyContinue){$allowed=Test-ArkuzoRecoveryHandoff}
Assert (-not $allowed) 'Unresolved closed account must block every further client closure'
$script:recoveryPending=@{ 'account-test'=@{status='AwaitingReplacement';closedUtc=[datetime]::UtcNow.ToString('o');nextRetryUtc=[datetime]::UtcNow.AddSeconds(360).ToString('o')} }
Assert (-not (Test-ArkuzoRecoveryHandoff 'account-test')) 'Failed replacement must respect persisted backoff'
$script:recoveryPending['account-test'].nextRetryUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o')
Assert (Test-ArkuzoRecoveryHandoff 'account-test') 'Only the same failed account may be retried while other accounts stay protected'
Assert (-not (Test-ArkuzoRecoveryHandoff 'other-account')) 'A different account cannot be closed while one is missing'
$script:recoveryPending=@{}
Assert (Test-ArkuzoRecoveryHandoff) 'All verified outcomes release the global handoff gate'
Write-Output 'PASS: unresolved outcome blocks destructive recovery'
