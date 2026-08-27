#Requires -Version 7.2

<#
    Custom PSScriptAnalyzer rules for the Rights Management App.

    Every rule here corresponds to a defect that reached production in the previous
    runbook library. They are the difference between "we fixed it" and "it cannot
    come back".
#>

using namespace System.Management.Automation.Language
using namespace Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic

function Measure-RmaEmptyCatchBlock {
    <#
    .SYNOPSIS
        An empty catch block silently discards an error.
    .DESCRIPTION
        Create-ADGroup.ps1 wrapped its job-claim call in `catch {}`. When the claim
        failed the runbook executed the job anyway while the queue still believed it
        was pending, so the next poll picked up the same job and wrote to Active
        Directory again.
    .INPUTS
        [System.Management.Automation.Language.ScriptBlockAst]
    .OUTPUTS
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]
    #>
    [CmdletBinding()]
    [OutputType([DiagnosticRecord[]])]
    param( [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [ScriptBlockAst] $ScriptBlockAst )

    $results = [System.Collections.Generic.List[DiagnosticRecord]]::new()
    foreach ($catch in $ScriptBlockAst.FindAll({ $args[0] -is [CatchClauseAst] }, $true)) {
        if ($catch.Body.Statements.Count -eq 0) {
            $results.Add([DiagnosticRecord]@{
                    Message  = 'Empty catch block discards the error. Log it and set a failure flag, or rethrow.'
                    Extent   = $catch.Extent
                    RuleName = 'RmaAvoidEmptyCatchBlock'
                    Severity = 'Error'
                })
        }
    }
    return $results
}

function Measure-RmaRuntimeModuleInstall {
    <#
    .SYNOPSIS
        Runbooks must not install modules at run time.
    .DESCRIPTION
        Runtime Install-Module with no pinned version accumulated every published
        version on the Hybrid Worker and exhausted its disk. Dependencies belong in
        #Requires, and provisioning belongs in Initialize-RmaWorker.ps1.
    .INPUTS
        [System.Management.Automation.Language.ScriptBlockAst]
    .OUTPUTS
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]
    #>
    [CmdletBinding()]
    [OutputType([DiagnosticRecord[]])]
    param( [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [ScriptBlockAst] $ScriptBlockAst )

    $banned  = @('Install-Module', 'Install-WindowsFeature', 'Update-Module', 'Save-Module')
    $results = [System.Collections.Generic.List[DiagnosticRecord]]::new()

    foreach ($cmd in $ScriptBlockAst.FindAll({ $args[0] -is [CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if ($name -and $banned -contains $name) {
            $results.Add([DiagnosticRecord]@{
                    Message  = "'$name' must not run inside a runbook. Declare the dependency with #Requires and provision the worker with scripts/Initialize-RmaWorker.ps1."
                    Extent   = $cmd.Extent
                    RuleName = 'RmaAvoidRuntimeModuleInstall'
                    Severity = 'Error'
                })
        }
    }
    return $results
}

function Measure-RmaUnpinnedModuleInstall {
    <#
    .SYNOPSIS
        Install-Module in a provisioning script must pin a version.
    .DESCRIPTION
        Without -RequiredVersion the worker gets whatever is latest that day, so
        behaviour changes with no code change and no release.
    .INPUTS
        [System.Management.Automation.Language.ScriptBlockAst]
    .OUTPUTS
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]
    #>
    [CmdletBinding()]
    [OutputType([DiagnosticRecord[]])]
    param( [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [ScriptBlockAst] $ScriptBlockAst )

    $results = [System.Collections.Generic.List[DiagnosticRecord]]::new()

    foreach ($cmd in $ScriptBlockAst.FindAll({ $args[0] -is [CommandAst] }, $true)) {
        if ($cmd.GetCommandName() -ne 'Install-Module') { continue }

        $pinned = $false
        foreach ($element in $cmd.CommandElements) {
            if ($element -is [CommandParameterAst] -and
                $element.ParameterName -in @('RequiredVersion', 'MaximumVersion')) { $pinned = $true }
        }
        if (-not $pinned) {
            $results.Add([DiagnosticRecord]@{
                    Message  = 'Install-Module without -RequiredVersion. Pin the version so the module set is reproducible.'
                    Extent   = $cmd.Extent
                    RuleName = 'RmaRequirePinnedModuleVersion'
                    Severity = 'Error'
                })
        }
    }
    return $results
}

function Measure-RmaScriptScopeReturn {
    <#
    .SYNOPSIS
        A bare `return` at script scope exits the whole runbook.
    .DESCRIPTION
        Update-EntraUser.ps1 used `return` inside an if-block at script scope, intending
        to skip one step. It exited the entire runbook instead: no write-back to
        ServiceNow, the job left stranded in Work in Progress, and every remaining queued
        job abandoned.
    .INPUTS
        [System.Management.Automation.Language.ScriptBlockAst]
    .OUTPUTS
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]
    #>
    [CmdletBinding()]
    [OutputType([DiagnosticRecord[]])]
    param( [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [ScriptBlockAst] $ScriptBlockAst )

    $results = [System.Collections.Generic.List[DiagnosticRecord]]::new()

    foreach ($return in $ScriptBlockAst.FindAll({ $args[0] -is [ReturnStatementAst] }, $true)) {
        # Walk up. Three enclosures make a return legitimate:
        #   - a function or a scriptblock argument: the return is scoped to it
        #   - an `if (-not $PSCmdlet.ShouldProcess(...)) { return }` guard, which is the
        #     documented -WhatIf idiom and cannot be expressed any other way
        $parent   = $return.Parent
        $enclosed = $false
        while ($parent) {
            if ($parent -is [FunctionDefinitionAst] -or $parent -is [ScriptBlockExpressionAst]) {
                $enclosed = $true; break
            }
            if ($parent -is [IfStatementAst]) {
                foreach ($clause in $parent.Clauses) {
                    if ($clause.Item1.Extent.Text -match 'ShouldProcess') { $enclosed = $true; break }
                }
                if ($enclosed) { break }
            }
            $parent = $parent.Parent
        }
        if (-not $enclosed) {
            $results.Add([DiagnosticRecord]@{
                    Message  = 'Bare return at script scope exits the entire runbook, abandoning the queue. Use a guarded if, or move the logic into a function.'
                    Extent   = $return.Extent
                    RuleName = 'RmaAvoidScriptScopeReturn'
                    Severity = 'Error'
                })
        }
    }
    return $results
}

function Measure-RmaUnredactedObjectLogging {
    <#
    .SYNOPSIS
        Writing a whole payload object to the job log can disclose a secret.
    .DESCRIPTION
        Create-EntraUser.ps1 wrote the decoded ServiceNow payload to the job log with
        `Write-Output $ParameterObject`. That payload carried the new user's password,
        which was then retained in Automation job output.
    .INPUTS
        [System.Management.Automation.Language.ScriptBlockAst]
    .OUTPUTS
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]
    #>
    [CmdletBinding()]
    [OutputType([DiagnosticRecord[]])]
    param( [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [ScriptBlockAst] $ScriptBlockAst )

    $writers  = @('Write-Output', 'Write-Host', 'Write-Information')
    $suspect  = 'ParameterObject|Payload|JobQueueItem|JsonObject|Credential|Secret'
    $results  = [System.Collections.Generic.List[DiagnosticRecord]]::new()

    foreach ($cmd in $ScriptBlockAst.FindAll({ $args[0] -is [CommandAst] }, $true)) {
        if ($cmd.GetCommandName() -notin $writers) { continue }

        foreach ($element in $cmd.CommandElements | Select-Object -Skip 1) {
            # Only flag a bare variable. An interpolated string with a named property is fine.
            if ($element -is [VariableExpressionAst] -and $element.VariablePath.UserPath -match $suspect) {
                $results.Add([DiagnosticRecord]@{
                        Message  = "Logging '`$$($element.VariablePath.UserPath)' writes the whole object to the job log and may disclose a secret. Use Write-RmaLog, which redacts, or log named fields."
                        Extent   = $cmd.Extent
                        RuleName = 'RmaAvoidUnredactedObjectLogging'
                        Severity = 'Error'
                    })
            }
        }
    }
    return $results
}

Export-ModuleMember -Function Measure-Rma*
