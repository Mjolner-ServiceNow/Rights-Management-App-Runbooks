#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.5.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';          RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Enables an Entra ID user from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the Microsoft Graph application permission
    User.EnableDisableAccount.All with User.Read.All, or User.ReadWrite.All. Enabling a user
    who holds an administrator role needs more than that; Graph refuses it with
    Authorization_RequestDenied, and the job fails with that reason.

    Enabling is idempotent. A user who is already enabled is logged and the job completes:
    the outcome ServiceNow asked for is already true. A user who does not exist fails the
    job, as it did in 1.0: there is nothing to enable (docs/DECISIONS.md D15 covers deletes
    only). It fails once the retries Invoke-RmaQueueLoop gives a user Graph may not have
    replicated yet are used (D18).
.NOTES
    Payload: user, the account to enable, as its user principal name or its object id.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Enable-EntraUser' -Body {
    param($job, $p)

    # Read through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $identity = "$($p.PSObject.Properties['user']?.Value)".Trim()
    if (-not $identity -or $identity -match '[\x00-\x1F]') {
        throw "Payload field 'user' is empty or contains control characters. Correct the ServiceNow record."
    }
    # The value goes into the request path, so it is held to the two forms -UserId means:
    # an object id, or a user principal name in the character set Entra accepts. Anything
    # else, a '/' or a '?' for example, could address something other than a user.
    $isObjectId = $identity -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    if (-not $isObjectId -and $identity -notmatch '^[A-Za-z0-9._!#^~''-]{1,113}@[A-Za-z0-9.-]{1,255}$') {
        throw "Payload field 'user' is neither an object id nor a user principal name. Correct the ServiceNow record."
    }

    try {
        $user = Get-MgUser -UserId $identity -Property 'id', 'userPrincipalName', 'accountEnabled' -ErrorAction Stop
    } catch {
        # Matched on Graph's error code, which leads the error id; the exception itself is a
        # plain System.Exception. Every other failure (throttling, access denied) is
        # rethrown as is.
        if ($_.FullyQualifiedErrorId -notlike 'Request_ResourceNotFound,*') { throw }
        # Not found is retried: a job queued straight after the create can be run before
        # Graph knows the user (D18). One that never arrives fails once the retries are used.
        Request-RmaJobRetry -Reason "No Entra ID user '$identity'. Correct the ServiceNow record."
    }

    # The user acted on must be the user asked for, whatever the request path made of it.
    if ($user.Id -ne $identity -and $user.UserPrincipalName -ne $identity) {
        throw "Graph returned a different user than '$identity' asked for. Nothing was changed."
    }

    $fields = @{ userPrincipalName = $user.UserPrincipalName; id = $user.Id; queueSysId = $job.sys_id }

    if ($user.AccountEnabled) {
        Write-RmaLog -Level Information -Message 'Entra user is already enabled; nothing to do' -Data $fields
        return
    }

    Update-MgUser -UserId $user.Id -AccountEnabled -ErrorAction Stop
    Write-RmaLog -Level Information -Message 'Entra user enabled' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
