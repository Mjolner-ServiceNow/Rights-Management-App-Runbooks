#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.2.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Groups';         RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Deletes an Entra ID group from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the Group.ReadWrite.All application permission. Deleting a
    role-assignable group needs a directory role on top of it, and fails with Graph's own
    reason without one.

    The delete is a soft delete, as in 1.0: the group moves to Deleted groups, where Entra
    keeps it for 30 days and then removes it. Nothing here deletes permanently. On the test
    tenant both a security group and a Microsoft 365 group landed there (2026-10-13);
    older Microsoft documentation says security groups were deleted for good at once.
    Deleting a group removes its memberships with it; the members themselves are
    untouched.

    Deleting is idempotent: a group that does not exist is logged as a warning and the job
    completes, because the outcome ServiceNow asked for is true (docs/DECISIONS.md D15).
    1.0 failed the job instead. A group already in Deleted groups counts as gone.

    A group synchronised from on-premises Active Directory cannot be deleted in Entra ID:
    it is mastered on-premises. The job fails with that reason before Graph is asked to
    delete anything; Remove-ADGroup is the runbook for such a group.

    The group is deleted by the object id Graph returned in the same job. Graph is
    eventually consistent: a group created seconds before can still be reported as not
    found, and that job completes with the warning and leaves the group in place.
.NOTES
    Payload: group, the group to delete, as its Entra object id, which is what 1.0 passed
    to Graph too. A display name is refused: group names are not unique.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-EntraGroup' -Body {
    param($job, $p)

    # The value becomes a segment of the Graph URL, and Microsoft.Graph does not escape
    # '/' in -GroupId, so it must be an object id and nothing else. Read through PSObject:
    # under StrictMode a missing field would otherwise throw a property-not-found that
    # says nothing about the payload.
    $identity = "$($p.PSObject.Properties['group']?.Value)".Trim()
    if ($identity -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z') {
        throw "Payload field 'group' is empty or is not an Entra object id. Correct the ServiceNow record."
    }

    # Graph reports a missing object as a plain System.Exception; only the error id names
    # the reason. Every other failure (throttling past the SDK's retries, access denied)
    # is rethrown as is.
    $isNotFound = { param($record) $record.FullyQualifiedErrorId -like 'Request_ResourceNotFound,*' }
    $gone = { param($fields) Write-RmaLog -Level Warning -Message 'Entra group not found; nothing to delete' -Data $fields }

    try {
        # onPremisesSyncEnabled is not in Graph's default property set; without -Property
        # it comes back null and a synchronised group would look cloud-only.
        $group = Get-MgGroup -GroupId $identity -Property 'id', 'displayName', 'onPremisesSyncEnabled' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        & $gone @{ group = $identity; queueSysId = $job.sys_id }
        return
    }

    $fields = @{ displayName = $group.DisplayName; id = $group.Id; queueSysId = $job.sys_id }

    if ($group.OnPremisesSyncEnabled) {
        throw "Entra ID group '$($group.Id)' is synchronised from on-premises Active Directory and can only be deleted there. Use Remove-ADGroup."
    }

    try {
        Remove-MgGroup -GroupId $group.Id -Confirm:$false -ErrorAction Stop
    } catch {
        # Another execution of the same row deleted it between the lookup and here.
        if (-not (& $isNotFound $_)) { throw }
        & $gone $fields
        return
    }
    Write-RmaLog -Level Information -Message 'Entra group deleted' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
