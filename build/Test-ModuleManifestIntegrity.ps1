#Requires -Version 7.2
<#
.SYNOPSIS
    Verifies the module manifest is valid and its export list matches reality.
.DESCRIPTION
    A function present in Public/ but missing from FunctionsToExport is invisible to
    runbooks; a name in FunctionsToExport with no implementation makes the manifest
    unloadable in some hosts. Both are silent until deployment, so they are checked here.

    Functions are read from the AST, not from file names. Comparing file names let
    Get-RmaWorkerId sit in Public/Request-RmaJobClaim.ps1, unexported and unreachable from
    a runbook, while this script reported the manifest consistent. The help check is per
    function for the same reason: one .SYNOPSIS anywhere in a file used to satisfy it for
    every function in that file.
#>
[CmdletBinding()]
param(
    [string] $ManifestPath = "$PSScriptRoot/../src/RMA.Runbooks/RMA.Runbooks.psd1"
)

$ErrorActionPreference = 'Stop'
$manifestPath = (Resolve-Path $ManifestPath).Path
$moduleRoot   = Split-Path $manifestPath -Parent
$problems     = [System.Collections.Generic.List[string]]::new()

Write-Host "Validating $manifestPath"

$null = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Write-Host '  manifest is well formed'

$declared = (Import-PowerShellDataFile $manifestPath).FunctionsToExport

# Every function actually defined under Public/, with the file and help it carries.
$onDisk = foreach ($file in Get-ChildItem "$moduleRoot/Public" -Filter '*.ps1' -File) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)
    foreach ($function in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        [pscustomobject]@{
            Name = $function.Name
            File = $file.Name
            Help = $function.GetHelpContent()
            Body = $function.Body.Extent.Text
        }
    }
}

foreach ($function in $onDisk) {
    if ($function.Name -notin $declared) {
        $problems.Add("$($function.File) defines '$($function.Name)', which is not in FunctionsToExport. Move it to Private/ if it is internal.")
    }
}
foreach ($name in $declared) {
    if ($name -notin $onDisk.Name) { $problems.Add("FunctionsToExport lists '$name' but no function by that name is defined under Public/.") }
}

Import-Module $manifestPath -Force -ErrorAction Stop
$actual = (Get-Command -Module RMA.Runbooks).Name
foreach ($name in $declared) {
    if ($name -notin $actual) { $problems.Add("'$name' is declared but was not exported at import time.") }
}
Remove-Module RMA.Runbooks -Force -ErrorAction SilentlyContinue

# Every public function needs comment-based help and [CmdletBinding()]. The help is the
# only documentation an operator has at three in the morning.
foreach ($function in $onDisk) {
    if (-not $function.Help -or [string]::IsNullOrWhiteSpace($function.Help.Synopsis)) {
        $problems.Add("$($function.File): '$($function.Name)' has no .SYNOPSIS.")
    }
    if ($function.Body -notmatch '\[CmdletBinding') {
        $problems.Add("$($function.File): '$($function.Name)' has no [CmdletBinding()].")
    }
}

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "::error::$_" }
    throw "$($problems.Count) manifest integrity problem(s)."
}
Write-Host "  $($declared.Count) exported function(s), all consistent and documented"
Write-Host 'Manifest integrity OK.'
