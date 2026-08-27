#Requires -Version 7.2
<#
.SYNOPSIS
    Runs PSScriptAnalyzer with the repository settings and the custom RMA rules.
#>
[CmdletBinding()]
param(
    [string]   $Path = "$PSScriptRoot/..",
    [string[]] $FailOn = @('Error'),
    [string]   $OutputSarif
)

$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -ErrorAction Stop

$root = (Resolve-Path $Path).Path
$targets = Get-ChildItem -Path $root -Include '*.ps1', '*.psm1', '*.psd1' -Recurse -File |
Where-Object { $_.FullName -notmatch '[\\/](out|\.git|artifacts)[\\/]' }

Write-Host "Analysing $($targets.Count) file(s)..."

# -Path takes a single item, so files are analysed individually. This also keeps one
# unparseable file from aborting the whole run.
$findings = @(
    foreach ($target in $targets) {
        Invoke-ScriptAnalyzer -Path $target.FullName `
            -Settings "$PSScriptRoot/PSScriptAnalyzerSettings.psd1" `
            -CustomRulePath "$PSScriptRoot/rules/RmaRules.psm1" `
            -ErrorAction Stop
    }
)

if ($findings) {
    $findings | Group-Object Severity | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0,-12} {1}" -f $_.Name, $_.Count)
    }
    Write-Host ''
    foreach ($f in $findings | Sort-Object Severity, ScriptName, Line) {
        $rel = $f.ScriptName
        Write-Host ("::{0} file={1},line={2}::[{3}] {4}" -f
            $(if ($f.Severity -eq 'Error') { 'error' } else { 'warning' }),
            $rel, $f.Line, $f.RuleName, $f.Message)
    }
} else {
    Write-Host '  no findings'
}

if ($OutputSarif) {
    # Minimal but valid SARIF 2.1.0 so GitHub code scanning can ingest the results.
    $rules = @($findings | Select-Object -ExpandProperty RuleName -Unique | ForEach-Object { @{ id = $_ } })
    $sarif = @{
        '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
        version   = '2.1.0'
        runs      = @(@{
                tool    = @{ driver = @{ name = 'PSScriptAnalyzer'; rules = $rules } }
                results = @($findings | ForEach-Object {
                        @{
                            ruleId  = $_.RuleName
                            level   = switch ($_.Severity) { 'Error' { 'error' } 'Warning' { 'warning' } default { 'note' } }
                            message = @{ text = $_.Message }
                            locations = @(@{ physicalLocation = @{
                                        artifactLocation = @{ uri = ($_.ScriptName -replace '\\', '/') }
                                        region           = @{ startLine = [Math]::Max(1, $_.Line) }
                                    } 
                                })
                        }
                    })
            })
    }
    $sarif | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputSarif -Encoding utf8
    Write-Host "SARIF written to $OutputSarif"
}

$blocking = @($findings | Where-Object { $_.Severity -in $FailOn })
if ($blocking.Count -gt 0) {
    throw "$($blocking.Count) finding(s) at severity [$($FailOn -join ', ')]. Build failed."
}
Write-Host 'Analysis passed.'
