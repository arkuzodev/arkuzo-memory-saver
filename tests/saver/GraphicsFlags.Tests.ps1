#requires -Version 5.1
param(
    [string]$ScriptPath=(Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'),
    [string]$FixtureRoot=([IO.Path]::GetTempPath()),
    [string]$CaseFilter='*'
)
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'FAIL: Controller parse failure'}
# Load ONLY graphics helpers, never the controller/startup or native code.
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match '^(Merge-ArkuzoGraphicsFlags|Get-ArkuzoGraphicsInstallDirectories|Invoke-ArkuzoGraphicsSettings)$'},$false)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
function Assert([bool]$ok,[string]$message) { if(-not $ok){throw "FAIL: $message"} }
$script:passed=0
function Case([string]$name,[scriptblock]$body) {
    if($name -notlike $CaseFilter){return}
    & $body; $script:passed++; Write-Output "PASS: $name"
}
$fixture=Join-Path $FixtureRoot ('arkuzo-graphics-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function New-SettingsFixture([string]$Name,[string]$Json) {
    $dir=Join-Path $fixture $Name
    [void][IO.Directory]::CreateDirectory($dir)
    $file=Join-Path $dir 'ClientAppSettings.json'
    [IO.File]::WriteAllText($file,$Json,(New-Object Text.UTF8Encoding($false)))
    return $file
}
try {
    Case 'Numeric 15-FPS request preserves unknown JSON properties' {
        Assert ([bool](Get-Command Merge-ArkuzoGraphicsFlags -ErrorAction SilentlyContinue)) '15-FPS settings merger is missing'
        $file=New-SettingsFixture 'existing' '{"DFIntTaskSchedulerTargetFps":"120","UnknownFlag":"Keep","Nested":{"Enabled":false,"Items":[1,"two",null]},"DFFlagTextureQualityOverrideEnabled":"False"}'
        $result=Merge-ArkuzoGraphicsFlags -SettingsFile $file
        $settings=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        Assert ($settings.DFIntTaskSchedulerTargetFps -is [int] -and $settings.DFIntTaskSchedulerTargetFps -eq 15) 'FPS value must be numeric 15, not a string'
        Assert ($settings.UnknownFlag -ceq 'Keep' -and $settings.Nested.Enabled -eq $false) 'Unknown scalar and nested properties must survive'
        Assert ($settings.Nested.Items.Count -eq 3 -and $settings.Nested.Items[1] -ceq 'two' -and $null -eq $settings.Nested.Items[2]) 'Unknown arrays and null must survive'
        Assert ($settings.DFFlagTextureQualityOverrideEnabled -ceq 'True' -and $settings.DFIntTextureQualityOverride -ceq '0' -and $settings.FIntDebugForceMSAASamples -ceq '1') 'Existing texture/MSAA requests must remain'
        Assert ($result.RequestedFps -eq 15 -and $result.FpsStatus -ceq 'REQUESTED_ONLY') 'Result must not claim actual active FPS'
    }
    Case 'Invalid or non-object JSON remains byte-for-byte unchanged' {
        $index=0
        foreach($json in @('[]','[{}]','null','15','"text"','true','{broken','{"a":1} trailing','')) {
            $file=New-SettingsFixture ('invalid-'+$index) $json
            $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
            $rejected=$false
            try { $null=Merge-ArkuzoGraphicsFlags -SettingsFile $file } catch { $rejected=$true }
            Assert $rejected ("Invalid settings must be rejected: fixture {0}" -f $index)
            Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ceq $before) 'Invalid settings bytes must not change'
            Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $file) -Force).Count -eq 1) 'Invalid JSON must leave no backups or temporary files'
            $index++
        }
    }
    Case 'Safe replacement keeps unique exact-byte backups' {
        $file=New-SettingsFixture 'backup space' ("{`r`n  `"Unrelated`": 7`r`n}`r`n")
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
        $first=Merge-ArkuzoGraphicsFlags -SettingsFile $file
        Assert ($first.BackupPath -and [IO.File]::Exists($first.BackupPath)) 'Replacing existing settings must create a backup'
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($first.BackupPath)) -ceq $before) 'Backup must exactly preserve original bytes'
        [IO.File]::WriteAllText($file,'{"OtherUserChange":42}',(New-Object Text.UTF8Encoding($false)))
        $secondBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
        $second=Merge-ArkuzoGraphicsFlags -SettingsFile $file
        Assert ($second.BackupPath -cne $first.BackupPath) 'Repeated replacements must not overwrite an earlier backup'
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($second.BackupPath)) -ceq $secondBefore) 'Second backup must preserve its own preimage'
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($first.BackupPath)) -ceq $before) 'Earlier backup must remain intact'
        Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $file) -Filter '*.tmp' -Force).Count -eq 0) 'Successful replacement must clean temporary files'
    }
    Case 'Install discovery follows process images and supplied roots without hardcoded drives' {
        Assert ([bool](Get-Command Get-ArkuzoGraphicsInstallDirectories -ErrorAction SilentlyContinue)) 'Dynamic graphics installation discovery is missing'
        $versions=Join-Path $fixture 'custom profile/Roblox/Versions'
        $programData=Join-Path $fixture 'custom drive/roblox/roblox'
        $active=Join-Path $fixture 'active [build] Unicode'
        $versionA=Join-Path $versions 'version-a'
        $versionB=Join-Path $programData 'version-b'
        $notPlayer=Join-Path $versions 'studio-only'
        foreach($dir in @($versionA,$versionB,$active,$notPlayer)){[void][IO.Directory]::CreateDirectory($dir)}
        foreach($dir in @($versionA,$versionB,$active)){[IO.File]::WriteAllBytes((Join-Path $dir 'RobloxPlayerBeta.exe'),[byte[]]@(0))}
        [IO.File]::WriteAllBytes((Join-Path $notPlayer 'RobloxStudioBeta.exe'),[byte[]]@(0))
        $dirs=@(Get-ArkuzoGraphicsInstallDirectories -SearchRoots @($versions,$programData,$active,$versions,$null,(Join-Path $fixture 'missing')) -ProcessImagePaths @((Join-Path $active 'RobloxPlayerBeta.exe'),(Join-Path $notPlayer 'RobloxStudioBeta.exe')))
        Assert ($dirs.Count -eq 3) 'Exactly three unique Player directories must be discovered'
        foreach($dir in @($versionA,$versionB,$active)){Assert ($dirs -contains $dir) 'Process, profile and ProgramData fixtures must be included'}
        Assert (-not ($dirs -contains $notPlayer)) 'Studio-only or wrong image name must not become a Player target'
        $none=@(Get-ArkuzoGraphicsInstallDirectories -SearchRoots @() -ProcessImagePaths @())
        Assert ($none.Count -eq 0) 'Empty explicit roots must not fall back to the real installation'
    }
    Case 'Startup requests are truthful and disabled or monitor-only modes never write' {
        Assert ([bool](Get-Command Invoke-ArkuzoGraphicsSettings -ErrorAction SilentlyContinue)) 'Guarded startup graphics merger is missing'
        $install=Join-Path $fixture 'startup image'
        [void][IO.Directory]::CreateDirectory($install)
        [IO.File]::WriteAllBytes((Join-Path $install 'RobloxPlayerBeta.exe'),[byte[]]@(0))
        $settingsFile=Join-Path $install 'ClientSettings/ClientAppSettings.json'
        $monitor=Invoke-ArkuzoGraphicsSettings -InstallDirectories @($install) -ApplyGraphicsFlags -MonitorOnly
        Assert ($monitor.Status -ceq 'SKIPPED_MONITOR_ONLY' -and -not [IO.File]::Exists($settingsFile)) 'Monitor-only must not create settings'
        $disabled=Invoke-ArkuzoGraphicsSettings -InstallDirectories @($install)
        Assert ($disabled.Status -ceq 'SKIPPED_DISABLED' -and -not [IO.Directory]::Exists((Split-Path -Parent $settingsFile))) 'Disabled graphics must not create ClientSettings directories'
        $report=Invoke-ArkuzoGraphicsSettings -InstallDirectories @($install) -ApplyGraphicsFlags
        Assert ($report.Status -ceq 'REQUESTED' -and $report.Files.Count -eq 1) 'One fixture installation must receive the request'
        Assert ($report.Message -cmatch 'REQUESTED' -and $report.Message -match 'ignored' -and $report.Message -match 'not.*allowlist') 'Startup must explicitly distinguish requested 15 FPS from an ignored Player flag'
        Assert ($report.Message -notmatch '15 FPS (active|applied|enabled|enforced)') 'Startup must never assert active 15 FPS'
        $json=Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        Assert ($json.DFIntTaskSchedulerTargetFps -is [int] -and $json.DFIntTaskSchedulerTargetFps -eq 15) 'Startup must use the numeric merger on new settings'
        Assert ($null -eq $report.Files[0].BackupPath) 'First-time settings must not invent a prior-file backup'
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsFile))
        $null=Invoke-ArkuzoGraphicsSettings -InstallDirectories @($install) -ApplyGraphicsFlags -MonitorOnly
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsFile)) -ceq $before) 'Monitor-only must also leave existing settings unchanged'
        $none=Invoke-ArkuzoGraphicsSettings -InstallDirectories @() -ApplyGraphicsFlags
        Assert ($none.Status -ceq 'SKIPPED_NO_INSTALLATIONS') 'No discovered Player must be reported as skipped'
        Assert ($ast.Extent.Text -match '\$graphicsReport = Invoke-ArkuzoGraphicsSettings') 'Actual startup block must use the tested guarded graphics helper'
    }
    Case 'Failed atomic replacement leaves original bytes intact and cleans staging' {
        $file=New-SettingsFixture 'locked' '{"Keep":"Original"}'
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
        # Permit reads but deny delete/replacement for the duration of this fixture operation.
        $lock=New-Object IO.FileStream($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $rejected=$false
        try { try {$null=Merge-ArkuzoGraphicsFlags -SettingsFile $file} catch {$rejected=$true} } finally {$lock.Dispose()}
        Assert $rejected 'A locked destination must refuse replacement'
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ceq $before) 'Failed replacement must not truncate or alter the original'
        Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $file) -Force).Count -eq 1) 'Failed replacement must leave no staging files or misleading backup'
        $mergerAst=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Merge-ArkuzoGraphicsFlags'},$false))[0]
        Assert ($mergerAst.Extent.Text -match '\[IO.File\]::Replace\(' -and $mergerAst.Extent.Text -match '\[IO.File\]::Move\(') 'Commit must use atomic replace/create, not target truncation'
    }
    Case 'UTF-8 BOM is preserved in backup and invalid UTF-8 is refused' {
        $file=New-SettingsFixture 'bom' '{}'
        $bomEncoding=New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($file,'{"UnknownDate":"2025-09-29T16:16:56.463Z","LargeInt":9007199254740993,"Unicode":"\u00e9"}',$bomEncoding)
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
        $result=Merge-ArkuzoGraphicsFlags -SettingsFile $file
        $json=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($result.BackupPath)) -ceq $before) 'BOM backup must be byte-exact'
        Assert ($json.UnknownDate -ceq '2025-09-29T16:16:56.463Z' -and $json.LargeInt -eq [long]9007199254740993 -and $json.Unicode -ceq ([char]0xE9).ToString()) 'Unknown dates, 64-bit integers and Unicode must survive'
        $invalid=New-SettingsFixture 'invalid-utf8' '{}'
        [IO.File]::WriteAllBytes($invalid,[byte[]]@(123,34,65,34,58,34,255,34,125))
        $badBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($invalid)); $rejected=$false
        try {$null=Merge-ArkuzoGraphicsFlags -SettingsFile $invalid} catch {$rejected=$true}
        Assert ($rejected -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($invalid)) -ceq $badBytes) 'Invalid UTF-8 must fail closed without lossy decoding'
    }
    Case 'Deep JSON is refused rather than truncating unknown properties' {
        $json='1'
        for($i=0;$i -lt 105;$i++){$json='{"Nested":'+$json+'}'}
        $file=New-SettingsFixture 'deep' $json
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file)); $rejected=$false
        try {$null=Merge-ArkuzoGraphicsFlags -SettingsFile $file} catch {$rejected=$true}
        Assert $rejected 'Object exceeding serializer depth must be refused, not converted into string values'
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ceq $before) 'Too-deep object must remain unchanged'
        Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $file) -Force).Count -eq 1) 'Depth refusal must happen before backup or staging'
    }
    Assert ($script:passed -gt 0) 'No graphics tests selected'
    Write-Output ("Graphics fixtures: {0} passed; real Roblox settings were not accessed." -f $script:passed)
} finally {
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
