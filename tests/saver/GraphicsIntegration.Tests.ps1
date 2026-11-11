#requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false))
$initialize=@($functions|Where-Object{$_.Name -ceq 'Initialize-ArkuzoGraphicsSettings'})
if($initialize.Count -ne 1){throw 'FAIL: graphics bootstrap must be an isolated guarded controller function'}
. ([scriptblock]::Create($initialize[0].Extent.Text))
function Assert([bool]$Ok,[string]$Message){if(-not $Ok){throw ('FAIL: '+$Message)}}
# No real installation discovery or settings writes. Exercise only the bootstrap/error seam.
function Get-ArkuzoGraphicsInstallDirectories {param($SearchRoots,$ProcessImagePaths);$script:graphicsTestReads++;$script:graphicsTestRoots=@($SearchRoots);return @('FIXTURE')}
# Builds installed by the Roblox tab live in Arkuzo's own Versions folder (docs/roblox-versions.md).
function Get-ArkuzoManagedVersionsRoot($Vault) {return 'X:\ArkuzoManaged\Versions'}
function Invoke-ArkuzoVaultLocked([scriptblock]$Action) {return $null}
function Invoke-ArkuzoGraphicsSettings {param($InstallDirectories,[switch]$ApplyGraphicsFlags,[switch]$MonitorOnly);$script:graphicsTestWrites++;throw 'fixture graphics write refused'}
function Get-Process {return @()}
function Write-Diagnostic($Kind,$Data) {$script:graphicsTestDiagnostics+=@(@{kind=$Kind;data=$Data})}
function Warn-Throttled($Key,$Message) {$script:graphicsTestWarnings[$Key]=$Message}
$script:graphicsTestReads=0;$script:graphicsTestWrites=0;$script:graphicsTestDiagnostics=@();$script:graphicsTestWarnings=@{}
$script:ApplyGraphicsFlags=$true
foreach($gate in @(@{monitor=$true;owns=$true},@{monitor=$false;owns=$false})){
    $script:MonitorOnly=$gate.monitor;$script:ownsControllerMutex=$gate.owns
    Initialize-ArkuzoGraphicsSettings
}
Assert ($script:graphicsTestReads -eq 0 -and $script:graphicsTestWrites -eq 0) 'Monitor-only and non-owner must never discover/change graphics'
$script:MonitorOnly=$false;$script:ownsControllerMutex=$true
Initialize-ArkuzoGraphicsSettings
Assert ($script:graphicsTestWrites -eq 1 -and $script:graphicsStatus.Status -ceq 'FAILED') 'A graphics error must return FAILED without terminating the controller'
Assert ($script:graphicsTestWarnings['graphics-settings'] -match 'fixture graphics write refused') 'Graphics failure must reach the dashboard warning seam'
Assert (@($script:graphicsTestDiagnostics|Where-Object{$_.kind -ceq 'GRAPHICS_STATUS'}).Count -ge 1) 'Graphics error must reach diagnostics'
Assert ($script:graphicsTestRoots -contains 'X:\ArkuzoManaged\Versions') 'Graphics search roots must include the Roblox tab''s Versions folder'
# A build installed after start-up gets the flags before its first launch, once, and never blocks the launch.
$update=@($functions|Where-Object{$_.Name -ceq 'Update-ArkuzoGraphicsForInstall'})
Assert ($update.Count -eq 1) 'Update-ArkuzoGraphicsForInstall exists'
. ([scriptblock]::Create($update[0].Extent.Text))
$script:graphicsTestWrites=0;$script:graphicsAppliedDirectories=@{'x:\known'=$true}
Update-ArkuzoGraphicsForInstall 'X:\Known'
Assert ($script:graphicsTestWrites -eq 0) 'A folder handled at start-up is not written again'
Update-ArkuzoGraphicsForInstall 'X:\ArkuzoManaged\Versionsersion-0123456789abcdef'
Update-ArkuzoGraphicsForInstall 'X:\ArkuzoManaged\Versionsersion-0123456789abcdef'
Assert ($script:graphicsTestWrites -eq 1) 'A new build folder is handled once, and a failure does not throw'
$script:MonitorOnly=$true;$script:graphicsTestWrites=0
Update-ArkuzoGraphicsForInstall 'X:\Other'
Assert ($script:graphicsTestWrites -eq 0) 'Monitor-only never writes graphics flags'
$script:MonitorOnly=$false
$calls=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Initialize-ArkuzoGraphicsSettings'},$true))
Assert ($calls.Count -eq 1) 'Controller startup must invoke graphics bootstrap once'
$ancestor=$calls[0].Parent
while($null -ne $ancestor -and $ancestor -isnot [Management.Automation.Language.IfStatementAst]){$ancestor=$ancestor.Parent}
Assert ($null -ne $ancestor -and $ancestor.Clauses[0].Item1.Extent.Text -match '^\s*-not\s+\$MonitorOnly\s*$') 'Graphics bootstrap must run only in the non-monitor block'
$ownership=@($ancestor.Clauses[0].Item2.Statements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -match '^\s*-not\s+\$ownsControllerMutex\s*$'})
Assert ($ownership.Count -eq 1 -and $ownership[0].Extent.EndOffset -lt $calls[0].Extent.StartOffset) 'Graphics bootstrap must follow mutex ownership refusal'
Write-Output 'PASS: graphics bootstrap is owner-only, fail-soft, logged, and visible in dashboard diagnostics.'
