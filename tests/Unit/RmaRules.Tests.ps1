#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The five custom rules are the gate's teeth. They had no tests of their own, and a rule
# that quietly matches nothing is worse than no rule: the build goes green and the defect
# it exists to stop walks through. Every case below is expressed as source text, so the
# analyser is exercised exactly as it is in CI.

BeforeAll {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $script:RulePath = (Resolve-Path "$PSScriptRoot/../../build/rules/RmaRules.psm1").Path

    function Get-RmaFinding {
        param(
            [Parameter(Mandatory)][string] $Script,
            [Parameter(Mandatory)][string] $RuleName
        )
        # -CustomRulePath without -IncludeDefaultRules runs the RMA rules only.
        @(Invoke-ScriptAnalyzer -ScriptDefinition $Script -CustomRulePath $script:RulePath |
            Where-Object RuleName -EQ $RuleName)
    }
}

Describe 'RmaAvoidUnredactedObjectLogging' -Tag 'Unit', 'Security', 'Analyzer' {

    It 'flags <Name>, the name this repository actually uses' -ForEach @(
        @{ Name = '$parameters'; Script = '$parameters = @{}; Write-Output $parameters' }
        @{ Name = '$p'; Script = '$p = @{}; Write-Output $p' }
        @{ Name = '$job'; Script = '$job = @{}; Write-Host $job' }
        @{ Name = '$response'; Script = '$response = @{}; Write-Information $response' }
        @{ Name = '$Payload'; Script = '$Payload = @{}; Write-Output $Payload' }
    ) {
        # Invoke-RmaQueueLoop decodes the ServiceNow payload into $parameters and hands it
        # to the body as $p. Create-EntraUser.ps1 is the template every runbook copies, so
        # $p is the name a password is most likely to be logged under.
        (Get-RmaFinding -Script $Script -RuleName 'RmaAvoidUnredactedObjectLogging').Count |
        Should -Be 1 -Because "logging $Name whole can disclose a secret"
    }

    It 'leaves a named field and an unrelated variable alone' -ForEach @(
        @{ Case = 'interpolated named field'; Script = '$p = @{}; Write-Output "upn is $($p.upn)"' }
        @{ Case = 'the logger own output line'; Script = '$line = "x"; Write-Output $line' }
        @{ Case = 'a summary object'; Script = '$summary = @{}; Write-Output $summary' }
    ) {
        (Get-RmaFinding -Script $Script -RuleName 'RmaAvoidUnredactedObjectLogging').Count |
        Should -Be 0 -Because "$Case is not a whole payload"
    }
}

Describe 'RmaAvoidEmptyCatchBlock' -Tag 'Unit', 'Analyzer' {

    It 'flags a catch with no statements, comment or not' -ForEach @(
        @{ Case = 'bare'; Script = 'try { Get-Item x } catch { }' }
        @{ Case = 'comment only'; Script = 'try { Get-Item x } catch { <# nothing to do #> }' }
    ) {
        (Get-RmaFinding -Script $Script -RuleName 'RmaAvoidEmptyCatchBlock').Count |
        Should -Be 1 -Because "a $Case catch still discards the error"
    }

    It 'accepts a catch that rethrows' {
        (Get-RmaFinding -Script 'try { Get-Item x } catch { throw }' -RuleName 'RmaAvoidEmptyCatchBlock').Count |
        Should -Be 0
    }
}

Describe 'RmaAvoidRuntimeModuleInstall' -Tag 'Unit', 'Analyzer' {

    It 'flags <Cmdlet>' -ForEach @(
        @{ Cmdlet = 'Install-Module' }, @{ Cmdlet = 'Update-Module' }
        @{ Cmdlet = 'Save-Module' }, @{ Cmdlet = 'Install-WindowsFeature' }
    ) {
        (Get-RmaFinding -Script "$Cmdlet -Name Foo" -RuleName 'RmaAvoidRuntimeModuleInstall').Count |
        Should -Be 1
    }
}

Describe 'RmaRequirePinnedModuleVersion' -Tag 'Unit', 'Analyzer' {

    It 'flags an unpinned install' {
        (Get-RmaFinding -Script 'Install-Module -Name Foo -Scope AllUsers' -RuleName 'RmaRequirePinnedModuleVersion').Count |
        Should -Be 1
    }

    It 'accepts <Parameter>' -ForEach @(
        @{ Parameter = '-RequiredVersion' }, @{ Parameter = '-MaximumVersion' }
    ) {
        (Get-RmaFinding -Script "Install-Module -Name Foo $Parameter '1.2.3'" -RuleName 'RmaRequirePinnedModuleVersion').Count |
        Should -Be 0
    }
}

Describe 'RmaAvoidScriptScopeReturn' -Tag 'Unit', 'Analyzer' {

    It 'flags a return at script scope' {
        (Get-RmaFinding -Script 'if ($true) { return }' -RuleName 'RmaAvoidScriptScopeReturn').Count |
        Should -Be 1
    }

    It 'accepts a return inside a function' {
        (Get-RmaFinding -Script 'function Start-Thing { if ($true) { return } }' -RuleName 'RmaAvoidScriptScopeReturn').Count |
        Should -Be 0
    }

    It 'accepts the documented ShouldProcess guard' {
        # The one exemption: this idiom cannot be written any other way.
        $script = 'if (-not $PSCmdlet.ShouldProcess("thing", "do it")) { return }'
        (Get-RmaFinding -Script $script -RuleName 'RmaAvoidScriptScopeReturn').Count | Should -Be 0
    }

    It 'accepts a return inside a scriptblock argument' {
        # Create-EntraUser.ps1 returns from the Invoke-RmaQueueLoop body to report an
        # already-existing user as success. That exits the body, not the runbook.
        (Get-RmaFinding -Script '1..3 | ForEach-Object { if ($_ -eq 2) { return } }' -RuleName 'RmaAvoidScriptScopeReturn').Count |
        Should -Be 0
    }
}
