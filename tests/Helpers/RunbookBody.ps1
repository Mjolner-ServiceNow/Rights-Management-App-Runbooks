# Dot-sourced by runbook tests. Not a test file itself: Pester discovers only *.Tests.ps1.
#
# A runbook that declares '#Requires -Modules ActiveDirectory' (or any module CI does not
# have) cannot be run in a test, because #Requires is checked before the first line. Its
# body can: it is the scriptblock passed to Invoke-RmaQueueLoop -Body, and these helpers
# take it, and the -Command it handles, from the runbook's AST.

function Get-RunbookQueueLoop {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.CommandAst])]
    param([Parameter(Mandatory)][string] $Path)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $null)
    $loop = $ast.Find({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Invoke-RmaQueueLoop'
        }, $true)
    if (-not $loop) { throw "No Invoke-RmaQueueLoop call in $Path." }
    $loop
}

function Get-RunbookArgument {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.CommandAst] $Command,
        [Parameter(Mandatory)][string] $ParameterName
    )

    $elements = $Command.CommandElements
    for ($i = 0; $i -lt $elements.Count - 1; $i++) {
        if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
            $elements[$i].ParameterName -eq $ParameterName) {
            return $elements[$i + 1]
        }
    }
    throw "Invoke-RmaQueueLoop has no -$ParameterName argument."
}

function Get-RunbookBody {
    <#
    .SYNOPSIS
        The scriptblock a runbook passes to Invoke-RmaQueueLoop -Body. Invoke it as
        & $body $job $payload, with the variables the runbook sets before the loop
        defined in the calling scope.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param([Parameter(Mandatory)][string] $Path)

    (Get-RunbookArgument -Command (Get-RunbookQueueLoop -Path $Path) -ParameterName 'Body').ScriptBlock.GetScriptBlock()
}

function Get-RunbookCommand {
    <#
    .SYNOPSIS
        The ServiceNow command a runbook passes to Invoke-RmaQueueLoop -Command.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    (Get-RunbookArgument -Command (Get-RunbookQueueLoop -Path $Path) -ParameterName 'Command').Value
}
