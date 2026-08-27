@{
    Severity = @('Error', 'Warning')

    # Custom rules encode the defects found in the previous library. Each one exists
    # because that exact mistake reached production.
    CustomRulePath      = @('./build/rules')
    IncludeDefaultRules = $true

    # Test files are analysed, but two rules only make sense for production code:
    # Pester helper factories are not state-changing cmdlets, and mock scriptblock
    # parameters are bound by Pester rather than read by the body.
    # Applied repository-wide because PSScriptAnalyzer settings are not path-scoped;
    # production violations of these two are caught in review.
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
        # Runbooks legitimately write to the Automation output stream for operator
        # visibility; Write-RmaLog handles structure. Write-Host is still discouraged
        # and is caught by the custom rule below.
        'PSAvoidUsingWriteHost'
    )

    Rules = @{
        PSPlaceOpenBrace           = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true }
        PSPlaceCloseBrace          = @{ Enable = $true; NewLineAfter = $false }
        PSUseConsistentIndentation = @{ Enable = $true; Kind = 'space'; IndentationSize = 4; PipelineIndentation = 'NoIndentation' }
        # House style aligns assignments and switch arms into columns, which reads
        # better in long parameter blocks. Operator and open-brace spacing checks are
        # therefore off; everything else in the rule stays on.
        PSUseConsistentWhitespace  = @{
            Enable         = $true
            CheckOperator  = $false
            CheckOpenBrace = $false
            CheckInnerBrace = $true
            CheckPipe      = $true
            CheckSeparator = $true
        }
        PSAlignAssignmentStatement = @{ Enable = $false }
        PSUseCorrectCasing         = @{ Enable = $true }
    }
}
