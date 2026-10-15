#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                                 RequiredVersion = '2.6.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication';               RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Identity.DirectoryManagement'; RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Deletes an Entra ID administrative unit from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the AdministrativeUnit.ReadWrite.All application permission,
    which Microsoft documents as the least privileged one for this delete.

    The delete is Graph's ordinary delete, as in 1.0, and nothing here deletes permanently.
    It is a soft delete: on the test tenant a deleted administrative unit moved to deleted
    items (directory/deletedItems) with its display name (2026-10-13), where Microsoft
    documents it as restorable for 30 days. Unlike a user or a group, it cannot be purged
    from there early: Graph answers not found to a permanent delete of an administrative
    unit, as Microsoft documents, and Entra removes it after the 30 days.

    An administrative unit with members is deleted like an empty one, as in 1.0: the
    members themselves are untouched and only their membership of the unit goes. Role
    assignments scoped to the unit go with it; nothing here looks at them first, as 1.0
    did not. A restricted management administrative unit has not been tried; if Graph
    refuses one, the job fails with Graph's reason.

    Deleting is idempotent: an administrative unit that does not exist is logged as a
    warning and the job completes, because the outcome ServiceNow asked for is true
    (docs/DECISIONS.md D15). 1.0 failed the job instead. One already in deleted items
    counts as gone. One found neither live nor in deleted items may have been created
    moments ago and not have reached Graph yet: the job is retried, and completes as gone
    only once the retries Invoke-RmaQueueLoop gives are used (D19).

    The administrative unit is deleted by the object id Graph returned in the same job.
.NOTES
    Payload: organizationalunit, the administrative unit to delete, as its Entra object id.
    That is the field and the value 1.0 passed to Graph. A display name is refused:
    administrative unit names are not unique.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-EntraAdministrativeUnit' -Body {
    param($job, $p)

    # The value becomes a segment of the Graph URL, and Microsoft.Graph does not escape
    # '/' in -AdministrativeUnitId, so it must be an object id and nothing else. Read
    # through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $identity = "$($p.PSObject.Properties['organizationalunit']?.Value)".Trim()
    if ($identity -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z') {
        throw "Payload field 'organizationalunit' is empty or is not an Entra object id. Correct the ServiceNow record."
    }

    # Graph reports a missing object as a plain System.Exception; only the error id names
    # the reason. Every other failure (throttling past the SDK's retries, access denied)
    # is rethrown as is.
    $isNotFound = { param($record) $record.FullyQualifiedErrorId -like 'Request_ResourceNotFound,*' }
    $gone = { param($fields) Write-RmaLog -Level Warning -Message 'Entra administrative unit not found; nothing to delete' -Data $fields }

    try {
        $unit = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $identity -Property 'id', 'displayName' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        # Not found is either gone or not replicated yet (D19). One in deleted items was
        # deleted, and the job completes at once. Otherwise the loop runs the body again,
        # and completes the job as gone once the retries are used.
        if (Test-RmaDeletedDirectoryObject -Id $identity) {
            & $gone @{ administrativeUnit = $identity; inDeletedItems = $true; queueSysId = $job.sys_id }
            return
        }
        Request-RmaJobRetry -CompleteWhenExhausted -Reason "Entra administrative unit '$identity' not found; nothing to delete"
    }

    $fields = @{ displayName = $unit.DisplayName; id = $unit.Id; queueSysId = $job.sys_id }

    try {
        Remove-MgDirectoryAdministrativeUnit -AdministrativeUnitId $unit.Id -Confirm:$false -ErrorAction Stop
    } catch {
        # Another execution of the same row deleted it between the lookup and here.
        if (-not (& $isNotFound $_)) { throw }
        & $gone $fields
        return
    }
    Write-RmaLog -Level Information -Message 'Entra administrative unit deleted' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
