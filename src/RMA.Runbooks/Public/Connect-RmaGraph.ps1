function Connect-RmaGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph as the app registration, via the workload's managed identity.
    .DESCRIPTION
        No client secret and no certificate. The managed identity token is exchanged for an
        app token using the federated identity credential configured on the app registration.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Connect-MgGraph -AccessToken requires a SecureString, and the federated token arrives from the token endpoint as a plain string. There is no API that accepts it any other way.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Context,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $ApplicationId,
        [string] $Scope = 'https://graph.microsoft.com/.default'
    )

    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication is not available. Declare it with #Requires in the runbook.'
    }

    $token = Get-RmaAccessToken -Federated -Resource $Scope `
        -ManagedIdentityClientId $Context.ManagedIdentityClientId `
        -ApplicationId $ApplicationId -TenantId $Context.Domain.TenantId

    Connect-MgGraph -AccessToken ($token | ConvertTo-SecureString -AsPlainText -Force) -NoWelcome
    Write-RmaLog -Level Information -Message 'Connected to Microsoft Graph' -Data @{
        applicationId = $ApplicationId; tenantId = $Context.Domain.TenantId
    }
}
