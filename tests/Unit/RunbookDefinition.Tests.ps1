#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Azure Automation validates a runbook's definition when it is published or test-started,
# and rejects some things PowerShell itself accepts. Nothing local catches that: the gate
# stayed green while Test-RmaHealth, with three parameter sets, could not be started at all
# ("The Runbook definition is invalid. Parameter sets in runbooks are not supported in this
# release."). These tests read each runbook's AST, so they need neither the modules it
# requires nor an Automation Account.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:Runbooks = @(Get-ChildItem (Join-Path $repoRoot 'src/runbooks') -Filter '*.ps1' -File |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

Describe 'Runbook <Name> is accepted by Azure Automation' -Tag 'Unit' -ForEach $script:Runbooks {

    BeforeAll {
        $tokens = $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
        $errors | Should -BeNullOrEmpty
        $script:ParamBlock = $ast.ParamBlock
        $script:Ast = $ast
    }

    It 'declares no parameter sets' {
        $named = @(
            if ($script:ParamBlock) {
                $script:ParamBlock.FindAll({
                        $args[0] -is [System.Management.Automation.Language.NamedAttributeArgumentAst] -and
                        $args[0].ArgumentName -in 'ParameterSetName', 'DefaultParameterSetName'
                    }, $true)
            }
        )
        $named.Extent.Text | Should -BeNullOrEmpty -Because 'Azure Automation refuses to start a runbook with parameter sets'
    }

    It 'renders its output as plain text' {
        # The job pane prints ANSI escape codes literally. With the default rendering a
        # failed health check buried its one useful line under colour sequences.
        $set = $script:Ast.FindAll({
                $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $args[0].Left.Extent.Text -eq '$PSStyle.OutputRendering' -and
                $args[0].Right.Extent.Text -eq "'PlainText'"
            }, $false)
        @($set).Count | Should -Be 1
    }
}
