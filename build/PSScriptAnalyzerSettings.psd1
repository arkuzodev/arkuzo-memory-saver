# PSScriptAnalyzer settings for build/lint.ps1 (report only: findings never fail a run).
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # A console program and build scripts: Write-Host is the output.
        'PSAvoidUsingWriteHost',
        # Internal functions, not cmdlets for other people.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        # The engine is one script that keeps its state in script scope by design (docs/architecture.md).
        'PSAvoidGlobalVars',
        'PSUseBOMForUnicodeEncodedFile'
    )
}
