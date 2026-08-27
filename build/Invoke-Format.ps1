#Requires -Version 7.2
<#
.SYNOPSIS
    Applies the repository formatting rules to every PowerShell file.
.DESCRIPTION
    Run before committing. CI checks formatting but does not fix it, so that a pull
    request diff shows only intentional changes.
.PARAMETER Check
    Report files that would change and exit non-zero, without writing. Used by CI.
#>
[CmdletBinding()]
param(
    [string] $Path = "$PSScriptRoot/..",
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -ErrorAction Stop

$settings = "$PSScriptRoot/PSScriptAnalyzerSettings.psd1"
$files = Get-ChildItem -Path (Resolve-Path $Path) -Include '*.ps1', '*.psm1' -Recurse -File |
Where-Object { $_.FullName -notmatch '[\\/](out|\.git|artifacts)[\\/]' }

$changed = [System.Collections.Generic.List[string]]::new()

foreach ($file in $files) {
    $original  = Get-Content $file.FullName -Raw
    $formatted = Invoke-Formatter -ScriptDefinition $original -Settings $settings

    if ($formatted -ne $original) {
        $changed.Add($file.FullName)
        if (-not $Check) {
            Set-Content -Path $file.FullName -Value $formatted -NoNewline -Encoding utf8
        }
    }
}

if ($changed.Count -eq 0) {
    Write-Host "All $($files.Count) file(s) already correctly formatted."
} elseif ($Check) {
    $changed | ForEach-Object { Write-Host "::error file=$_::Formatting differs. Run ./build/Invoke-Format.ps1" }
    throw "$($changed.Count) file(s) need formatting."
} else {
    Write-Host "Formatted $($changed.Count) file(s):"
    $changed | ForEach-Object { Write-Host "  $(Split-Path $_ -Leaf)" }
}
