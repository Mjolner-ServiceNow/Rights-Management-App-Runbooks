#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.2.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';          RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users.Actions';  RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Disables an Entra ID user and revokes their sign-in sessions, from the ServiceNow
    command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The queue command is Revoke-SignInTokens, not the file name.

    The user is looked up first and then changed by object id, so the user changed is the
    user looked up. The account is disabled before the sessions are revoked, so no new
    sign-in can fall between the two.

    Repeating the job is safe and completes. A user who is already disabled is not
    updated again, and the revoke still runs: revoking has no state that could already
    be true, so every run is a fresh revoke that moves signInSessionsValidFromDateTime to
    now. A disabled user cannot have obtained a token since the last one, so the repeat
    changes nothing a user could notice. A user who does not exist fails the job.

    Needs the Microsoft Graph application permissions User.ReadWrite.All and
    User.RevokeSessions.All (docs/AZURE-RESOURCES.md). Graph refuses to disable a user who
    holds an administrator role unless the application has a matching directory role;
    that refusal, and every other Graph error, fails the job unchanged.
.NOTES
    Payload: user, the account to disable, as its user principal name or object id.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ApplicationId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The Automation job pane prints ANSI escape codes literally, which buries the text of
# every error record under colour sequences.
$PSStyle.OutputRendering = 'PlainText'

$context = Test-RmaPrerequisite -Instance $Instance -VaultName $VaultName `
    -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName

Connect-RmaGraph -Context $context -TenantId $TenantId -ApplicationId $ApplicationId

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Revoke-SignInTokens' -Body {
    param($job, $p)

    # Passed to -UserId, which the Graph SDK escapes into the request path, never into a
    # filter, so it cannot widen the lookup. Only emptiness and control characters are
    # rejected here; anything else that names no user is reported by Get-MgUser below.
    # Read through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $identity = "$($p.PSObject.Properties['user']?.Value)".Trim()
    if (-not $identity -or $identity -match '[\x00-\x1F]') {
        throw "Payload field 'user' is empty or contains control characters. Correct the ServiceNow record."
    }

    try {
        $user = Get-MgUser -UserId $identity -Property 'id', 'userPrincipalName', 'accountEnabled' -ErrorAction Stop
    } catch {
        # The Graph SDK throws a plain System.Exception; only the error id says what Graph
        # answered. Every other failure (throttling, access denied) is rethrown as is.
        if ($_.FullyQualifiedErrorId -notlike 'Request_ResourceNotFound,*') { throw }
        throw "No Entra ID user '$identity' in the tenant. Correct the ServiceNow record."
    }

    $fields = @{ userPrincipalName = $user.UserPrincipalName; id = $user.Id; queueSysId = $job.sys_id }

    if ($user.AccountEnabled) {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false -ErrorAction Stop
        Write-RmaLog -Level Information -Message 'Entra user disabled' -Data $fields
    } else {
        Write-RmaLog -Level Information -Message 'Entra user is already disabled; revoking sessions only' -Data $fields
    }

    # Returns true; Graph answers an error, not false, when it cannot revoke.
    $null = Revoke-MgUserSignInSession -UserId $user.Id -ErrorAction Stop
    Write-RmaLog -Level Information -Message 'Entra user sign-in sessions revoked' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
