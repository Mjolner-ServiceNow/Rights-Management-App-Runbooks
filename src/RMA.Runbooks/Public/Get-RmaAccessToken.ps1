function Get-RmaAccessToken {
    <#
    .SYNOPSIS
        Returns an access token for a resource, using the workload's managed identity.
    .DESCRIPTION
        Two modes:

        Direct    - a managed identity token for the resource (used for Key Vault).
        Federated - the managed identity token is exchanged for an app registration token
                    via a federated identity credential, which is how Graph and Exchange
                    Online are reached without a client secret or certificate.

        Tokens are cached in module scope and reused until five minutes before expiry. The
        queue loop is long-running, so re-minting per call would be wasteful and re-using a
        token to expiry would fail mid-job.
    .PARAMETER Resource
        For Direct: the resource, e.g. https://vault.azure.net
        For Federated: the scope, e.g. https://graph.microsoft.com/.default
    .EXAMPLE
        Get-RmaAccessToken -Resource 'https://vault.azure.net' -ManagedIdentityClientId $id
    .EXAMPLE
        Get-RmaAccessToken -Federated -Resource 'https://graph.microsoft.com/.default' `
            -ManagedIdentityClientId $mi -ApplicationId $app -TenantId $tid
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Federated selects the parameter set; the branch is taken on $PSCmdlet.ParameterSetName.')]
    [CmdletBinding(DefaultParameterSetName = 'Direct')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $Resource,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $ManagedIdentityClientId,

        [Parameter(Mandatory, ParameterSetName = 'Federated')]
        [switch] $Federated,

        [Parameter(Mandatory, ParameterSetName = 'Federated')][ValidateNotNullOrEmpty()]
        [string] $ApplicationId,

        [Parameter(Mandatory, ParameterSetName = 'Federated')][ValidateNotNullOrEmpty()]
        [string] $TenantId,

        [switch] $Force
    )

    $cacheKey = '{0}|{1}|{2}' -f $PSCmdlet.ParameterSetName, $Resource, $ManagedIdentityClientId
    $now = (Get-Date).ToUniversalTime()

    if (-not $Force -and $script:RmaTokenCache.ContainsKey($cacheKey)) {
        $cached = $script:RmaTokenCache[$cacheKey]
        if ($cached.ExpiresOn -gt $now.AddMinutes(5)) { return $cached.AccessToken }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Direct') {
        $token = Get-RmaImdsToken -Resource $Resource -ClientId $ManagedIdentityClientId
        $script:RmaTokenCache[$cacheKey] = $token
        return $token.AccessToken
    }

    # Federated: managed identity token becomes the client assertion for the app registration.
    $assertion = (Get-RmaImdsToken -Resource 'api://AzureADTokenExchange' -ClientId $ManagedIdentityClientId).AccessToken

    $response = Invoke-RmaRestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method POST `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
        client_id             = $ApplicationId
        scope                 = $Resource
        grant_type            = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $assertion
    }

    $script:RmaTokenCache[$cacheKey] = [pscustomobject]@{
        AccessToken = $response.access_token
        ExpiresOn   = $now.AddSeconds([int] $response.expires_in)
        Resource    = $Resource
    }
    return $response.access_token
}
