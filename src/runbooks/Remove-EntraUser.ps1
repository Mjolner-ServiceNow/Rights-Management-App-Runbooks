#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.2.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';          RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Deletes an Entra ID user from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the User.ReadWrite.All application permission. Deleting a
    user who holds an administrator role needs a directory role on top of it, and fails
    with Graph's own reason without one.

    The delete is a soft delete, as in 1.0: the user moves to Deleted users, where Entra
    keeps it restorable for 30 days and then removes it. Nothing here deletes permanently.

    Deleting is idempotent: a user who does not exist is logged as a warning and the job
    completes, because the outcome ServiceNow asked for is true (docs/DECISIONS.md D15).
    1.0 failed the job instead, which made every repeated execution fail after the first
    had succeeded. A user already in Deleted users counts as gone.

    The user is deleted by its object id, read in the same job, so the delete cannot hit a
    different object that took the name in between. Graph is eventually consistent: a user
    created seconds before can still be reported as not found, and that job completes with
    the warning and leaves the user in place.
.NOTES
    Payload: user, the user to delete, as its object id or its user principal name.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-EntraUser' -Body {
    param($job, $p)

    # The value becomes a segment of the Graph URL, so it must be an object id or a user
    # principal name and nothing else: a '/' would address a different resource, and Graph
    # decodes '%23' to '#'. The UPN set is the one Entra accepts, guest '#EXT#' included.
    # Read through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $identity = "$($p.PSObject.Properties['user']?.Value)".Trim()
    if ($identity -notmatch '^(?:[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|[A-Za-z0-9._!#^~''-]{1,64}@[A-Za-z0-9.-]{1,255})\z') {
        throw "Payload field 'user' is empty or is neither an object id nor a user principal name. Correct the ServiceNow record."
    }

    # Graph reports a missing object as a plain System.Exception; only the error id names
    # the reason. Every other failure (throttling past the SDK's retries, access denied)
    # is rethrown as is.
    $isNotFound = { param($record) $record.FullyQualifiedErrorId -like 'Request_ResourceNotFound,*' }
    $gone = { param($fields) Write-RmaLog -Level Warning -Message 'Entra user not found; nothing to delete' -Data $fields }

    try {
        $user = Get-MgUser -UserId $identity -Property 'id', 'userPrincipalName' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        & $gone @{ user = $identity; queueSysId = $job.sys_id }
        return
    }

    # The object deleted is the object the payload named, not one Graph resolved some
    # other way. PowerShell's -ne ignores case, as user principal names do.
    if ($user.Id -ne $identity -and $user.UserPrincipalName -ne $identity) {
        throw "Graph returned a user other than the one payload field 'user' names; nothing was deleted."
    }

    $fields = @{ upn = $user.UserPrincipalName; id = $user.Id; queueSysId = $job.sys_id }

    try {
        Remove-MgUser -UserId $user.Id -Confirm:$false -ErrorAction Stop
    } catch {
        # Another execution of the same row deleted it between the lookup and here.
        if (-not (& $isNotFound $_)) { throw }
        & $gone $fields
        return
    }
    Write-RmaLog -Level Information -Message 'Entra user deleted' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
