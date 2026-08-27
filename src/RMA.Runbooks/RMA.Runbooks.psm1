#Requires -Version 7.2

Set-StrictMode -Version Latest

# Dot-source Private first so Public functions can rely on them.
foreach ($scope in 'Private', 'Public') {
    $dir = Join-Path $PSScriptRoot $scope
    if (-not (Test-Path $dir)) { continue }
    foreach ($file in Get-ChildItem -Path $dir -Filter '*.ps1' -Recurse) {
        try {
            . $file.FullName
        } catch {
            throw "Failed to load $($file.FullName): $($_.Exception.Message)"
        }
    }
}

# Module-scoped state. Deliberately not exported.
$script:RmaCorrelationId = $null
$script:RmaTokenCache    = @{}
