#Requires -Version 7.2
<#
.SYNOPSIS
    Validates the PowerShell examples embedded in this skill's markdown.
.DESCRIPTION
    Every fenced ```powershell block is analysed unless its first line marks it as a
    deliberate counter-example (# WRONG) or as a fragment that cannot stand alone
    (# skip-validate). The skill must not teach code that fails to parse.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Path,
    [ValidateSet('Error', 'Warning')][string] $Severity = 'Error'
)

$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -ErrorAction Stop

$files = if (Test-Path -Path $Path -PathType Container) {
    Get-ChildItem -Path $Path -Filter '*.md' -Recurse -File -Force
}
else {
    Get-Item -Path $Path -Force
}

$failures = @(
    foreach ($file in $files) {
        $lines = Get-Content -Path $file.FullName
        $block = $null
        $index = 0

        foreach ($line in $lines) {
            if ($null -eq $block) {
                if ($line.TrimEnd() -eq '```powershell') {
                    $block = [System.Collections.Generic.List[string]]::new()
                    $index++
                }
                continue
            }

            if ($line.TrimEnd() -eq '```') {
                $first = ($block | Select-Object -First 1) ?? ''
                $skip = $first -match '^#\s*(WRONG|skip-validate)\b'

                if (-not $skip -and $block.Count -gt 0) {
                    $findings = Invoke-ScriptAnalyzer -ScriptDefinition ($block -join "`n") -Severity $Severity, 'ParseError'
                    foreach ($finding in $findings) {
                        "$($file.Name):block$($index): $($finding.RuleName): $($finding.Message)"
                    }
                }

                $block = $null
                continue
            }

            $block.Add($line)
        }
    }
)

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    Write-Output "FAILED: $($failures.Count) block(s)."
    exit 1
}

Write-Output 'All validated blocks are clean.'
exit 0
