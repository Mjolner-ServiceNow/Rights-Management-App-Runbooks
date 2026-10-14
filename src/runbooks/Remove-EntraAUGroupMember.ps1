#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                                 RequiredVersion = '2.3.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication';               RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Groups';                       RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Identity.DirectoryManagement'; RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Removes a group from an Entra ID administrative unit, from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the AdministrativeUnit.ReadWrite.All and Group.Read.All (or
    Group.ReadWrite.All) application permissions. An administrative unit with restricted
    management refuses the app unless it holds a role scoped to that unit; the job then
    fails with Graph's own reason.

    Removing is idempotent: when the membership does not exist, because the group is not a
    member or because the administrative unit or the group does not exist, the job
    completes with a Warning saying which, since the outcome ServiceNow asked for is true
    (docs/DECISIONS.md D15). 1.0 failed the job in all three cases.

    An administrative unit with dynamic membership fails the job before Graph is asked to
    change it, as 1.0 failed it and as Create-EntraAUUserMember and Remove-EntraAUUserMember
    do: a membership job naming a dynamic unit means the ServiceNow record names the wrong
    unit (#159).

    The administrative unit and the group are looked up first and the membership is
    removed by the two object ids that came back, so the removal cannot hit a different
    object. Graph is eventually consistent: a membership added seconds before can still be
    reported as not found, and that job completes with the warning and leaves the group in
    the administrative unit.
.NOTES
    Payload:
      ou      the administrative unit, as its object id
      group   the group to remove, as its object id
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-EntraAUGroupMember' -Body {
    param($job, $p)

    # Both values become segments of Graph URLs, so each must be an object id and nothing
    # else: a '/' would address a different resource, and Graph decodes '%23' to '#'. 1.0
    # passed both to Graph as ids. Read through PSObject: under StrictMode a missing field
    # would otherwise throw a property-not-found that says nothing about the payload.
    $field = {
        param($Payload, [string] $Name)
        $value = "$($Payload.PSObject.Properties[$Name]?.Value)".Trim()
        if ($value -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z') {
            throw "Payload field '$Name' is empty or is not an object id. Correct the ServiceNow record."
        }
        $value
    }
    $unitId = & $field $p 'ou'
    $groupId = & $field $p 'group'

    # Graph reports a missing object as a plain System.Exception; only the error id names
    # the reason. Every other failure (throttling past the SDK's retries, access denied, a
    # unit with restricted management) is rethrown as is.
    $isNotFound = { param($record) $record.FullyQualifiedErrorId -like 'Request_ResourceNotFound,*' }
    $absent = @{ administrativeUnit = $unitId; group = $groupId; queueSysId = $job.sys_id }

    try {
        $unit = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $unitId `
            -Property 'id', 'displayName', 'membershipType' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        Write-RmaLog -Level Warning -Message 'Entra administrative unit not found; the membership does not exist' -Data $absent
        return
    }
    # Refused as the two user runbooks refuse it (#159). Graph would answer a group with the
    # same not-found as any other non-member (test tenant), which would hide that the record
    # names the wrong unit. Assigned membership is reported as null or 'Assigned'.
    if ($unit.MembershipType -eq 'Dynamic') {
        throw "The administrative unit that payload field 'ou' names has dynamic membership; its members follow its rule and cannot be removed. Correct the ServiceNow record."
    }
    try {
        $group = Get-MgGroup -GroupId $groupId -Property 'id', 'displayName' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        Write-RmaLog -Level Warning -Message 'Entra group not found; the membership does not exist' -Data $absent
        return
    }

    # The objects changed are the objects the payload named, not ones Graph resolved some
    # other way. PowerShell's -ne ignores case, as object ids do.
    if ($unit.Id -ne $unitId) {
        throw "Graph returned an administrative unit other than the one payload field 'ou' names; nothing was removed."
    }
    if ($group.Id -ne $groupId) {
        throw "Graph returned a group other than the one payload field 'group' names; nothing was removed."
    }

    $fields = @{
        administrativeUnit = $unit.DisplayName; administrativeUnitId = $unit.Id
        group = $group.DisplayName; groupId = $group.Id; queueSysId = $job.sys_id
    }

    # A group that is not a member is reported with the same not-found as a missing unit,
    # immediately after a removal as well as later (test tenant, SDK 2.39.0). Group
    # membership, the same kind of reference, also answers a just-removed member with a
    # 400 Request_BadRequest whose message alone says why (Remove-EntraGroupMember); the
    # unit endpoint was not seen to, but that answer means the same here. Both objects
    # were read above, so either means the membership does not exist, or that another
    # execution of the same row removed it, or deleted one of the two, since the lookup.
    # Any other bad request is rethrown.
    $isNotMember = {
        param($record)
        (& $isNotFound $record) -or (
            $record.FullyQualifiedErrorId -like 'Request_BadRequest,*' -and
            $record.Exception.Message -like '*removed object references do not exist*')
    }

    try {
        Remove-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $unit.Id -DirectoryObjectId $group.Id `
            -Confirm:$false -ErrorAction Stop
    } catch {
        if (-not (& $isNotMember $_)) { throw }
        Write-RmaLog -Level Warning -Message 'Entra group is not a member of the administrative unit; nothing to remove' -Data $fields
        return
    }
    Write-RmaLog -Level Information -Message 'Entra group removed from administrative unit' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
