#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.6.0'  }
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
    user looked up. A cloud-only account is disabled before its sessions are revoked, so
    no new sign-in can fall between the two.

    Repeating the job is safe and completes. A user who is already disabled is not
    updated again, and the revoke still runs: revoking has no state that could already
    be true, so every run is a fresh revoke that moves signInSessionsValidFromDateTime to
    now. A disabled user cannot have obtained a token since the last one, so the repeat
    changes nothing a user could notice. A user who does not exist fails the job, once the
    retries Invoke-RmaQueueLoop gives a user Graph may not have replicated yet are used
    (docs/DECISIONS.md D18).

    A user synchronised from on-premises Active Directory cannot be disabled in Entra ID:
    the account is mastered on-premises. For such a user the sessions are revoked, which
    is the part that cuts access off at once, and the job then fails, saying that the
    sessions were revoked but the account was not disabled and that Disable-ADUser is the
    runbook for it (docs/DECISIONS.md D17). A synchronised user who is already disabled is
    in the asked-for state: the sessions are revoked and the job completes. If the revoke
    itself fails, the job fails with Graph's error rather than the message above.

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
        # accountEnabled and onPremisesSyncEnabled are not in Graph's default property set;
        # without -Property both come back null and every user would look disabled.
        $user = Get-MgUser -UserId $identity -Property 'id', 'userPrincipalName', 'accountEnabled', 'onPremisesSyncEnabled' -ErrorAction Stop
    } catch {
        # The Graph SDK throws a plain System.Exception; only the error id says what Graph
        # answered. Every other failure (throttling, access denied) is rethrown as is.
        if ($_.FullyQualifiedErrorId -notlike 'Request_ResourceNotFound,*') { throw }
        # Not found is retried: a job queued straight after the create can be run before
        # Graph knows the user (D18). One that never arrives fails once the retries are used.
        Request-RmaJobRetry -Reason "No Entra ID user '$identity' in the tenant. Correct the ServiceNow record."
    }

    $fields = @{ userPrincipalName = $user.UserPrincipalName; id = $user.Id; queueSysId = $job.sys_id }

    # A synchronised account is mastered in AD, so Entra cannot disable it. Its sessions
    # are still revoked, and the job then fails so that someone disables it there.
    $syncedAndEnabled = $user.AccountEnabled -and $user.OnPremisesSyncEnabled

    if (-not $user.AccountEnabled) {
        Write-RmaLog -Level Information -Message 'Entra user is already disabled; revoking sessions only' -Data $fields
    } elseif ($syncedAndEnabled) {
        Write-RmaLog -Level Warning -Message 'Entra user is synchronised from on-premises AD and cannot be disabled in Entra ID; revoking sessions only' -Data $fields
    } else {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false -ErrorAction Stop
        Write-RmaLog -Level Information -Message 'Entra user disabled' -Data $fields
    }

    # Returns true; Graph answers an error, not false, when it cannot revoke. That error
    # fails the job as it is, before the message below could claim a revoke.
    $null = Revoke-MgUserSignInSession -UserId $user.Id -ErrorAction Stop
    Write-RmaLog -Level Information -Message 'Entra user sign-in sessions revoked' -Data $fields

    if ($syncedAndEnabled) {
        throw "The sign-in sessions of Entra ID user '$($user.UserPrincipalName)' were revoked, but the account is synchronised from on-premises Active Directory and was not disabled. Disable it there with Disable-ADUser."
    }
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
