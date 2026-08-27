#Requires -Version 7.2
<#
.SYNOPSIS
    Verifies the module manifest is valid and its export list matches reality.
.DESCRIPTION
    A function present in Public/ but missing from FunctionsToExport is invisible to
    runbooks; a name in FunctionsToExport with no implementation makes the manifest
    unloadable in some hosts. Both are silent until deployment, so they are checked here.
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
$onDisk   = Get-ChildItem "$moduleRoot/Public" -Filter '*.ps1' | ForEach-Object { $_.BaseName }

foreach ($name in $onDisk) {
    if ($name -notin $declared) { $problems.Add("Public/$name.ps1 exists but is not in FunctionsToExport.") }
}
foreach ($name in $declared) {
    if ($name -notin $onDisk)   { $problems.Add("FunctionsToExport lists '$name' but Public/$name.ps1 does not exist.") }
}

Import-Module $manifestPath -Force -ErrorAction Stop
$actual = (Get-Command -Module RMA.Runbooks).Name
foreach ($name in $declared) {
    if ($name -notin $actual) { $problems.Add("'$name' is declared but was not exported at import time.") }
}
Remove-Module RMA.Runbooks -Force -ErrorAction SilentlyContinue

# Every public function needs comment-based help. It is the only documentation an
# operator has at three in the morning.
foreach ($file in Get-ChildItem "$moduleRoot/Public" -Filter '*.ps1') {
    $content = Get-Content $file.FullName -Raw
    if ($content -notmatch '\.SYNOPSIS')    { $problems.Add("$($file.Name) has no .SYNOPSIS.") }
    if ($content -notmatch '\[CmdletBinding') { $problems.Add("$($file.Name) has no [CmdletBinding()].") }
}

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "::error::$_" }
    throw "$($problems.Count) manifest integrity problem(s)."
}
Write-Host "  $($declared.Count) exported function(s), all consistent and documented"
Write-Host 'Manifest integrity OK.'
