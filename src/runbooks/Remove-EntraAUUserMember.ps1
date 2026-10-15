#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                                 RequiredVersion = '2.5.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication';               RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';                        RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Identity.DirectoryManagement'; RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Removes a user from an Entra ID administrative unit, from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs,
    and the body follows Remove-EntraGroupMember. The app registration needs the
    AdministrativeUnit.ReadWrite.All and User.Read.All application permissions. A
    restricted management administrative unit also needs a role assigned to the app at the
    scope of that unit; without one Graph refuses and the job fails with Graph's reason.

    Only a user is removed, as in 1.0; the payload has no field for a group or a device
    member.

    An administrative unit with dynamic membership is refused before Graph is asked to
    change it, as 1.0 refused it: its members follow its rule, and Graph's own answer to
    the removal is a misleading 'Insufficient privileges'.

    Removing is idempotent: when the membership does not exist, because the user is not a
    member or because the administrative unit or the user does not exist, the job
    completes with a Warning saying which, since the outcome ServiceNow asked for is true
    (docs/DECISIONS.md D15). 1.0 failed the job in all three cases.

    An administrative unit or user found neither live nor in deleted items may have been
    created moments ago and not have reached Graph yet: the job is retried, and completes
    with the warning only once the retries Invoke-RmaQueueLoop gives are used (D19). A user
    named by user principal name cannot be looked up in deleted items, so that case always
    waits out the retries.

    The administrative unit and the user are looked up first and the membership is removed
    by the two object ids that came back, so the removal cannot hit a different object that
    took the name in between. Graph is eventually consistent: a membership added seconds
    before can still be reported as not found, and that job completes with the warning and
    leaves the user in the administrative unit. Nothing tells that apart from a membership
    that never existed, so it is not retried (D19).
.NOTES
    Payload:
      ou      the administrative unit, as its object id
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-EntraAUUserMember' -Body {
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
    $unitId = & $field $p 'ou' ('^' + $objectId + '\z') 'an administrative unit object id'
    $userIdentity = & $field $p 'user' ('^(?:' + $objectId + '|[A-Za-z0-9._!#^~''-]{1,64}@[A-Za-z0-9.-]{1,255})\z') `
        'an object id or a user principal name'

    # Graph reports a missing object as a plain System.Exception; only the error id names
    # the reason. Every other failure (throttling past the SDK's retries, access denied, a
    # restricted management unit) is rethrown as is.
    $isNotFound = { param($record) $record.FullyQualifiedErrorId -like 'Request_ResourceNotFound,*' }
    $absent = @{ administrativeUnit = $unitId; user = $userIdentity; queueSysId = $job.sys_id }

    try {
        $unit = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $unitId `
            -Property 'id', 'displayName', 'membershipType' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        # Not found is either gone or not replicated yet (D19). One in deleted items was
        # deleted, and the job completes at once. Otherwise the loop runs the body again,
        # and completes the job once the retries are used.
        if (Test-RmaDeletedDirectoryObject -Id $unitId) {
            Write-RmaLog -Level Warning -Message 'Entra administrative unit not found; the membership does not exist' -Data ($absent + @{ inDeletedItems = $true })
            return
        }
        Request-RmaJobRetry -CompleteWhenExhausted -Reason "Entra administrative unit '$unitId' not found; the membership does not exist"
    }
    # The object changed is the object the payload named, not one Graph resolved some other
    # way. PowerShell's -ne ignores case, as object ids do.
    if ($unit.Id -ne $unitId) {
        throw "Graph returned an administrative unit other than the one payload field 'ou' names; nothing was removed."
    }
    # Assigned membership is reported as null or 'Assigned'.
    if ($unit.MembershipType -eq 'Dynamic') {
        throw "The administrative unit that payload field 'ou' names has dynamic membership; its members follow its rule and cannot be removed. Correct the ServiceNow record."
    }

    try {
        $user = Get-MgUser -UserId $userIdentity -Property 'id', 'userPrincipalName' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        # Not found is either gone or not replicated yet (D19). One in deleted items was
        # deleted, and the job completes at once. Otherwise the loop runs the body again,
        # and completes the job once the retries are used.
        # Only an object id can be looked up there: Entra rewrites a deleted user's UPN.
        if ($userIdentity -match '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z' -and
            (Test-RmaDeletedDirectoryObject -Id $userIdentity)) {
            Write-RmaLog -Level Warning -Message 'Entra user not found; the membership does not exist' -Data ($absent + @{ inDeletedItems = $true })
            return
        }
        Request-RmaJobRetry -CompleteWhenExhausted -Reason "Entra user '$userIdentity' not found; the membership does not exist"
    }
    if ($user.Id -ne $userIdentity -and $user.UserPrincipalName -ne $userIdentity) {
        throw "Graph returned a user other than the one payload field 'user' names; nothing was removed."
    }

    $fields = @{
        administrativeUnit = $unit.DisplayName; administrativeUnitId = $unit.Id
        upn = $user.UserPrincipalName; userId = $user.Id; queueSysId = $job.sys_id
    }

    # For a user who is not a member, Graph answers with the same not-found it gives for a
    # missing administrative unit, naming the unit; on the test tenant (SDK 2.39.0) also
    # immediately after the membership was removed. The group endpoint answers that case,
    # within seconds, with a 400 Request_BadRequest whose message alone says why, and the
    # same directory reference is removed here, so that answer is read the same way. Both
    # objects were read above, so either means the membership does not exist, or that
    # another execution of the same row removed it, or deleted one of the two, since the
    # lookup. Any other bad request is rethrown.
    $isNotMember = {
        param($record)
        (& $isNotFound $record) -or (
            $record.FullyQualifiedErrorId -like 'Request_BadRequest,*' -and
            $record.Exception.Message -like '*removed object references do not exist*')
    }

    try {
        Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -AdministrativeUnitId $unit.Id `
            -DirectoryObjectId $user.Id -Confirm:$false -ErrorAction Stop
    } catch {
        if (-not (& $isNotMember $_)) { throw }
        Write-RmaLog -Level Warning -Message 'Entra user is not a member of the administrative unit; nothing to remove' -Data $fields
        return
    }
    Write-RmaLog -Level Information -Message 'Entra administrative unit member removed' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
