function Get-RmaProperty {
    <#
    .SYNOPSIS
        Reads a property that may not exist, without tripping Set-StrictMode.
    .DESCRIPTION
        Under Set-StrictMode -Version Latest, reading an absent property throws. Responses
        from ServiceNow, IMDS and Graph are all shape-variable, so every access to them
        goes through here. Returns $null when the property is absent.
    .NOTES
        Internal. Added after unit tests showed that a missing 'Headers' property on an
        error response turned a retryable failure into a hard failure.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][AllowNull()] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $(if ($InputObject.Contains($Name)) { $InputObject[$Name] } else { $null })
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}
