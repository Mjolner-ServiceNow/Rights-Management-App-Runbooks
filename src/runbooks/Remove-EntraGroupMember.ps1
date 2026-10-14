#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.3.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';          RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Groups';         RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Removes a user from an Entra ID group, from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the Group.ReadWrite.All (or GroupMember.ReadWrite.All) and
    User.Read.All application permissions. A role-assignable group also needs
    RoleManagement.ReadWrite.Directory. A group Graph cannot change, such as one synced
    from Active Directory, a dynamic group or a mail-enabled group, fails the job with
    Graph's own reason.

    Only a user is removed, as in 1.0; the payload has no field for a group or a device
    member.

    Removing is idempotent: when the membership does not exist, because the user is not a
    direct member or because the group or the user does not exist, the job completes with
    a Warning saying which, since the outcome ServiceNow asked for is true
    (docs/DECISIONS.md D15). 1.0 failed the job in all three cases.

    The group and the user are looked up first and the membership is removed by the two
    object ids that came back, so the removal cannot hit a different object that took the
    name in between. Graph is eventually consistent: a membership added seconds before can
    still be reported as not found, and that job completes with the warning and leaves
    the user in the group.
.NOTES
    Payload:
      group   the group, as its object id
      user    the member to remove, as its object id or its user principal name
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-EntraGroupMember' -Body {
    param($job, $p)

    # Both values become segments of Graph URLs, so each must be what Graph expects there
    # and nothing else: a '/' would address a different resource, and Graph decodes '%23'
    # to '#'. The UPN set is the one Entra accepts, guest '#EXT#' included. Read through
    # PSObject: under StrictMode a missing field would otherwise throw a property-not-found
    # that says nothing about the payload.
    $field = {
        param($Payload, [string] $Name, [string] $Pattern, [string] $Expected)
        $value = "$($Payload.PSObject.Properties[$Name]?.Value)".Trim()
        if ($value -notmatch $Pattern) {
            throw "Payload field '$Name' is empty or is not $Expected. Correct the ServiceNow record."
        }
        $value
    }
    $objectId = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    $groupId = & $field $p 'group' ('^' + $objectId + '\z') 'an object id'
    $userIdentity = & $field $p 'user' ('^(?:' + $objectId + '|[A-Za-z0-9._!#^~''-]{1,64}@[A-Za-z0-9.-]{1,255})\z') `
        'an object id or a user principal name'

    # Graph reports a missing object as a plain System.Exception; only the error id names
    # the reason. Every other failure (throttling past the SDK's retries, access denied, a
    # group Graph cannot change) is rethrown as is.
    $isNotFound = { param($record) $record.FullyQualifiedErrorId -like 'Request_ResourceNotFound,*' }
    $absent = @{ group = $groupId; user = $userIdentity; queueSysId = $job.sys_id }

    try {
        $group = Get-MgGroup -GroupId $groupId -Property 'id', 'displayName' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        Write-RmaLog -Level Warning -Message 'Entra group not found; the membership does not exist' -Data $absent
        return
    }
    try {
        $user = Get-MgUser -UserId $userIdentity -Property 'id', 'userPrincipalName' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        Write-RmaLog -Level Warning -Message 'Entra user not found; the membership does not exist' -Data $absent
        return
    }

    # The objects changed are the objects the payload named, not ones Graph resolved some
    # other way. PowerShell's -ne ignores case, as object ids and user principal names do.
    if ($group.Id -ne $groupId) {
        throw "Graph returned a group other than the one payload field 'group' names; nothing was removed."
    }
    if ($user.Id -ne $userIdentity -and $user.UserPrincipalName -ne $userIdentity) {
        throw "Graph returned a user other than the one payload field 'user' names; nothing was removed."
    }

    $fields = @{
        group = $group.DisplayName; groupId = $group.Id
        upn = $user.UserPrincipalName; userId = $user.Id; queueSysId = $job.sys_id
    }

    # Graph has two answers for a user who is not a direct member (test tenant, SDK
    # 2.39.0). Usually the same not-found it gives for a missing group, naming the group.
    # Within seconds of the membership being removed, a 400 Request_BadRequest whose
    # message alone says why. Both objects were read above, so either means the membership
    # does not exist, or that another execution of the same row removed it, or deleted one
    # of the two, since the lookup. Any other bad request is rethrown.
    $isNotMember = {
        param($record)
        (& $isNotFound $record) -or (
            $record.FullyQualifiedErrorId -like 'Request_BadRequest,*' -and
            $record.Exception.Message -like '*removed object references do not exist*')
    }

    try {
        Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id -Confirm:$false -ErrorAction Stop
    } catch {
        if (-not (& $isNotMember $_)) { throw }
        Write-RmaLog -Level Warning -Message 'Entra user is not a direct member of the group; nothing to remove' -Data $fields
        return
    }
    Write-RmaLog -Level Information -Message 'Entra group member removed' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
