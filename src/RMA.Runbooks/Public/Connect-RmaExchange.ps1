function Connect-RmaExchange {
    <#
    .SYNOPSIS
        Connects to Exchange Online as the app registration, via the workload's managed identity.
    .DESCRIPTION
        Exchange Online has no client-secret authentication method. Certificate-based auth
        requires a certificate to install and rotate on the worker, and Hybrid Worker jobs
        run as SYSTEM while the documented certificate location is the user store.

        This uses -AccessToken with a federated token instead, which removes both problems.
        Requires ExchangeOnlineManagement 3.1.0 or later.

        Like Connect-RmaGraph, the session keeps its token and expires with it, so the
        connection is registered for Update-RmaConnection to renew (#30).
    .PARAMETER Organization
        The tenant's *.onmicrosoft.com domain. Leave it out to have it read from Microsoft
        Graph, which needs Connect-RmaGraph first and Domain.Read.All; that is how the
        runbooks connect, so the ServiceNow domain record needs no field for it
        (docs/DECISIONS.md D20). The domain found is kept for renewals.
    .PARAMETER Force
        Mint a new token instead of reusing the cached one, and close the existing session
        first. Update-RmaConnection uses it.
    .EXAMPLE
        Connect-RmaExchange -Context $context -TenantId $TenantId -ApplicationId $ApplicationId
    .EXAMPLE
        Connect-RmaExchange -Context $context -TenantId $TenantId -ApplicationId $ApplicationId -Organization 'contoso.onmicrosoft.com'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Rma.Context')] $Context,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')] [string] $TenantId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')] [string] $ApplicationId,
        [ValidatePattern('^[A-Za-z0-9-]+\.onmicrosoft\.com$')] [string] $Organization,
        [switch] $Force
    )

    if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        throw 'ExchangeOnlineManagement is not available. Declare it with #Requires in the runbook.'
    }

    if (-not $Organization) { $Organization = Get-RmaInitialDomain }

    $token = Get-RmaAccessToken -Federated -Resource 'https://outlook.office365.com/.default' `
        -ManagedIdentityClientId $Context.ManagedIdentityClientId `
        -ApplicationId $ApplicationId -TenantId $TenantId -Force:$Force

    # A second Connect-ExchangeOnline opens a second session alongside the first rather
    # than replacing it, so a renewal closes the old one before opening the new.
    if ($Force -and $script:RmaSessions.Contains('Exchange') -and
        (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        Disconnect-ExchangeOnline -Confirm:$false
    }

    Connect-ExchangeOnline -AccessToken $token -Organization $Organization -ShowBanner:$false

    $expiresOn = Get-RmaTokenExpiry -AccessToken $token
    $script:RmaSessions['Exchange'] = [pscustomobject]@{
        Name       = 'Exchange Online'
        ExpiresOn  = $expiresOn
        Parameters = @{ Context = $Context; TenantId = $TenantId; ApplicationId = $ApplicationId; Organization = $Organization }
    }

    Write-RmaLog -Level Information -Message 'Connected to Exchange Online' -Data @{
        organization = $Organization; expiresOn = $expiresOn.ToString('o')
    }
}
