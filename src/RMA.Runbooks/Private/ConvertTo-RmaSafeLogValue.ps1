function ConvertTo-RmaSafeLogValue {
    <#
    .SYNOPSIS
        Redacts values whose property name suggests they carry a secret.
    .DESCRIPTION
        Defence in depth for logging. A previous incident wrote a new user's password to the
        job log by emitting a whole payload object; anything routed through Write-RmaLog is
        scrubbed so that mistake cannot recur silently.
    .NOTES
        Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $InputObject,
        [int] $Depth = 0
    )

    $sensitive = @(
        'password', 'pwd', 'secret', 'clientsecret', 'token', 'accesstoken', 'refreshtoken',
        'apikey', 'authorization', 'credential', 'passwordprofile', 'thumbprint', 'assertion'
    )

    if ($null -eq $InputObject) { return $null }
    if ($Depth -ge 8) { return '<max-depth>' }

    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive -or
        $InputObject -is [datetime] -or $InputObject -is [guid]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $InputObject.Keys) {
            $out[$key] = if ($sensitive -contains "$key".ToLowerInvariant()) { '<redacted>' }
            else { ConvertTo-RmaSafeLogValue -InputObject $InputObject[$key] -Depth ($Depth + 1) }
        }
        return $out
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @(foreach ($item in $InputObject) { ConvertTo-RmaSafeLogValue -InputObject $item -Depth ($Depth + 1) })
    }

    $out = @{}
    foreach ($prop in $InputObject.PSObject.Properties) {
        $out[$prop.Name] = if ($sensitive -contains $prop.Name.ToLowerInvariant()) { '<redacted>' }
        else { ConvertTo-RmaSafeLogValue -InputObject $prop.Value -Depth ($Depth + 1) }
    }
    return $out
}
