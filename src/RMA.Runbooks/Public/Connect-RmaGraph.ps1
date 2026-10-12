function Connect-RmaGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph as the app registration, via the workload's managed identity.
    .DESCRIPTION
        No client secret and no certificate. The managed identity token is exchanged for an
        app token using the federated identity credential configured on the app registration.

        Connect-MgGraph keeps the token it is given for the life of the session and has no
        way to renew a federated one, so the session expires with the token. The connection
        is therefore registered with the token's expiry, and Update-RmaConnection connects
        again before it runs out. Invoke-RmaQueueLoop calls that before every job (#30).
    .PARAMETER Force
        Mint a new token instead of reusing the cached one. Update-RmaConnection uses it,
        because the cache would otherwise hand back the token that is about to expire.
    .EXAMPLE
        Connect-RmaGraph -Context $context -TenantId $TenantId -ApplicationId $ApplicationId
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Connect-MgGraph -AccessToken requires a SecureString, and the federated token arrives from the token endpoint as a plain string. There is no API that accepts it any other way.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Rma.Context')] $Context,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')] [string] $TenantId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')] [string] $ApplicationId,
        [string] $Scope = 'https://graph.microsoft.com/.default',
        [switch] $Force
    )

    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication is not available. Declare it with #Requires in the runbook.'
    }

    $token = Get-RmaAccessToken -Federated -Resource $Scope `
        -ManagedIdentityClientId $Context.ManagedIdentityClientId `
        -ApplicationId $ApplicationId -TenantId $TenantId -Force:$Force

    Connect-MgGraph -AccessToken ($token | ConvertTo-SecureString -AsPlainText -Force) -NoWelcome

    $expiresOn = Get-RmaTokenExpiry -AccessToken $token
    $script:RmaSessions['Graph'] = [pscustomobject]@{
        Name       = 'Microsoft Graph'
        ExpiresOn  = $expiresOn
        Parameters = @{ Context = $Context; TenantId = $TenantId; ApplicationId = $ApplicationId; Scope = $Scope }
    }

    Write-RmaLog -Level Information -Message 'Connected to Microsoft Graph' -Data @{
        applicationId = $ApplicationId; tenantId = $TenantId; expiresOn = $expiresOn.ToString('o')
    }
}
