#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.6.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';          RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Disables an Entra ID user from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs User.ReadWrite.All, or User.Read.All with
    User.EnableDisableAccount.All. Disabling a user who holds an administrator role also
    needs a privileged role for the app.

    Disabling is idempotent. A user who is already disabled is logged and the job
    completes: the outcome ServiceNow asked for is already true. A user who does not exist
    fails the job, once the retries Invoke-RmaQueueLoop gives a user Graph may not have
    replicated yet are used (docs/DECISIONS.md D18). Disabling does not end sessions the user already has; it stops new
    sign-ins.

    A user synchronised from on-premises Active Directory cannot be disabled in Entra ID:
    the account is mastered on-premises. The job fails with that reason before Graph is
    asked to change anything; Disable-ADUser is the runbook for such a user.
.NOTES
    Payload: user, the account to disable, as its Entra object id or its user principal
    name.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Disable-EntraUser' -Body {
    param($job, $p)

    # Read through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    # The value goes into the Graph request path, and Microsoft.Graph does not escape '/'
    # in -UserId, so it must be an object id or a user principal name and nothing else.
    # The UPN set is the one Entra accepts, which includes '#' for guests (#EXT#).
    $identity = "$($p.PSObject.Properties['user']?.Value)".Trim()
    if ($identity -notmatch '^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[A-Za-z0-9._!#^~''-]+@[A-Za-z0-9.-]+)\z') {
        throw "Payload field 'user' is empty or is neither an Entra object id nor a user principal name. Correct the ServiceNow record."
    }

    try {
        # accountEnabled and onPremisesSyncEnabled are not in Graph's default property set;
        # without -Property both come back null and every user would look disabled.
        $user = Get-MgUser -UserId $identity -Property 'id', 'userPrincipalName', 'accountEnabled', 'onPremisesSyncEnabled' -ErrorAction Stop
    } catch {
        # Matched by error id: Microsoft.Graph raises a plain System.Exception, so there is
        # no type to catch. Every other failure (throttling, access denied) is rethrown as is.
        if ($_.FullyQualifiedErrorId -notlike 'Request_ResourceNotFound,*') { throw }
        # Not found is retried: a job queued straight after the create can be run before
        # Graph knows the user (D18). One that never arrives fails once the retries are used.
        Request-RmaJobRetry -Reason "No Entra ID user '$identity'. Correct the ServiceNow record."
    }

    $fields = @{ userPrincipalName = $user.UserPrincipalName; id = $user.Id; queueSysId = $job.sys_id }

    if ($user.AccountEnabled -eq $false) {
        Write-RmaLog -Level Information -Message 'Entra user is already disabled; nothing to do' -Data $fields
        return
    }
    if ($user.OnPremisesSyncEnabled) {
        throw "Entra ID user '$($user.UserPrincipalName)' is synchronised from on-premises Active Directory and can only be disabled there. Use Disable-ADUser."
    }

    # By object id, so the user changed is the user looked up.
    Update-MgUser -UserId $user.Id -BodyParameter @{ accountEnabled = $false } -ErrorAction Stop
    Write-RmaLog -Level Information -Message 'Entra user disabled' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
