@{
    Severity = @('Error', 'Warning')

    # Custom rules encode the defects found in the previous library. Each one exists
    # because that exact mistake reached production. They are loaded by
    # build/Invoke-Analysis.ps1, which passes -CustomRulePath explicitly.
    #
    # A CustomRulePath here would not work and used to be set anyway. A relative path in
    # a settings file resolves against the current directory, not the settings file, so
    # from anywhere but the repository root the run failed outright with "Cannot find
    # path .../build/rules"; and from the repository root the rules did not load at all.
    # Keep the one mechanism that is verified to work: the explicit parameter.
    IncludeDefaultRules = $true

    # Applied repository-wide, because PSScriptAnalyzer settings are not path-scoped.
    # Production violations of either are caught in review.
    ExcludeRules = @(
        # Pester helper factories and the queue functions are not state-changing cmdlets
        # in the sense this rule means. Set-RmaJobState declares SupportsShouldProcess on
        # its own merits, not because the analyzer asked.
        'PSUseShouldProcessForStateChangingFunctions'

        # Runbooks and build scripts legitimately write to the host for operator
        # visibility. Write-RmaLog, not the analyzer, is the enforcement point for
        # anything that belongs in the job log: it adds a level, a correlation id and
        # redaction, and RmaAvoidUnredactedObjectLogging covers the leak this rule does
        # not.
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
