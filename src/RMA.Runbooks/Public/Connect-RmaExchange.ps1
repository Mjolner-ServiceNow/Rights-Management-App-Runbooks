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
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Context,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $ApplicationId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]+\.onmicrosoft\.com$')] [string] $Organization
    )

    if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        throw 'ExchangeOnlineManagement is not available. Declare it with #Requires in the runbook.'
    }

    $token = Get-RmaAccessToken -Federated -Resource 'https://outlook.office365.com/.default' `
        -ManagedIdentityClientId $Context.ManagedIdentityClientId `
        -ApplicationId $ApplicationId -TenantId $Context.Domain.TenantId

    Connect-ExchangeOnline -AccessToken $token -Organization $Organization -ShowBanner:$false
    Write-RmaLog -Level Information -Message 'Connected to Exchange Online' -Data @{ organization = $Organization }
}
