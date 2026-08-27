function Get-RmaImdsToken {
    <#
    .SYNOPSIS
        Requests a managed identity token from the host's identity endpoint.
    .DESCRIPTION
        Handles both execution contexts:
          - Hybrid Runbook Worker on an Azure VM, which exposes IMDS at 169.254.169.254.
          - Azure Automation cloud sandbox, which exposes IDENTITY_ENDPOINT / IDENTITY_HEADER.

        The Hybrid Worker path is used when a ClientId is supplied, because a user-assigned
        identity on the VM must be selected explicitly. A VM running the Hybrid Worker
        extension always has a system-assigned identity as well, and omitting ClientId
        silently returns that one instead.
    .NOTES
        Internal. Callers should use Get-RmaAccessToken, which adds caching.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $Resource,

        # Client ID (not Principal ID) of the user-assigned managed identity.
        [string] $ClientId,

        [ValidateRange(1, 300)]
        [int] $TimeoutSeconds = 30
    )

    $useSandbox = -not [string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT)

    if ($useSandbox) {
        $uri = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($Resource)
        if ($ClientId) { $uri += "&client_id=$ClientId" }
        $headers = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' }
    } else {
        $uri = 'http://169.254.169.254/metadata/identity/oauth2/token' +
        '?api-version=2018-02-01' +
        '&resource=' + [uri]::EscapeDataString($Resource)
        if ($ClientId) { $uri += "&client_id=$ClientId" }
        $headers = @{ Metadata = 'true' }
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET -TimeoutSec $TimeoutSeconds
    } catch {
        throw ("Unable to acquire a managed identity token for '{0}' from the {1} endpoint. " -f
            $Resource, $(if ($useSandbox) { 'cloud sandbox' } else { 'IMDS' })) +
        "Verify the identity is attached and, on a Hybrid Worker, that the Automation " +
        "account has no managed identity of its own. Underlying error: $($_.Exception.Message)"
    }

    # expires_on is a Unix timestamp on IMDS and may be a string.
    $expiresOn = if ($response.PSObject.Properties.Name -contains 'expires_on') {
        [DateTimeOffset]::FromUnixTimeSeconds([int64] $response.expires_on).UtcDateTime
    } else {
        (Get-Date).ToUniversalTime().AddMinutes(55)
    }

    [pscustomobject]@{
        AccessToken = $response.access_token
        ExpiresOn   = $expiresOn
        Resource    = $Resource
    }
}
