#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.3.0' }
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Deletes an empty, unprotected Active Directory organizational unit from the ServiceNow command queue.
.DESCRIPTION
    Built on Unlock-ADUser, the reference for Active Directory runbooks; only the body
    differs. The service account needs the OrganizationalUnits scope of
    scripts/Grant-RmaAdDelegation.ps1 on the parent OU (docs/INSTALLATION.md, step 6a).

    Deleting is idempotent: an OU that does not exist is logged as a warning and the job
    completes, because the outcome ServiceNow asked for is true (docs/DECISIONS.md D15).

    Two refusals, each with a message an operator can act on, before anything is changed:
      - An OU protected from accidental deletion. 1.0 cleared the protection and deleted;
        that is a permission change, and the service account is deliberately not allowed
        to make one (#80, #123). An administrator removes the protection, or decides not to.
      - An OU that is not empty. The OU is never deleted as a tree: whatever it holds is
        moved or deleted first, by the runbooks for those objects.
.PARAMETER DomainController
    Host name or IP address of a domain controller for the domain.
.PARAMETER AdUserName
    The AD service account the runbook acts as.
.PARAMETER AdSecretName
    The Key Vault secret holding that account's password.
.NOTES
    Payload: organizationalunit, the OU to delete, as a distinguished name or objectGUID.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $DomainController,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $AdUserName,
    [ValidateNotNullOrEmpty()]                                  [string] $AdSecretName = 'ad-service-account-password'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The Automation job pane prints ANSI escape codes literally, which buries the text of
# every error record under colour sequences.
$PSStyle.OutputRendering = 'PlainText'

$context = Test-RmaPrerequisite -Instance $Instance -VaultName $VaultName `
    -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName

# Every AD cmdlet goes to this domain controller as the service account. The job runs as
# SYSTEM, whose own identity is not the service account.
$server = @{
    Server     = $DomainController
    Credential = Get-RmaSecret -VaultName $VaultName -Name $AdSecretName `
        -ManagedIdentityClientId $ManagedIdentityClientId -AsCredential -UserName $AdUserName
}

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-ADOrganizationalUnit' -Body {
    param($job, $p)

    # Passed to -Identity, never into an LDAP filter. Read through PSObject: under
    # StrictMode a missing field would otherwise throw a property-not-found that says
    # nothing about the payload.
    $identity = "$($p.PSObject.Properties['organizationalunit']?.Value)".Trim()
    if (-not $identity -or $identity -match '[\x00-\x1F]') {
        throw "Payload field 'organizationalunit' is empty or contains control characters. Correct the ServiceNow record."
    }

    try {
        $ou = Get-ADOrganizationalUnit -Identity $identity -Properties ProtectedFromAccidentalDeletion @server
    } catch {
        # Matched by name: a typed catch needs the ActiveDirectory assembly loaded to
        # resolve, and every other failure (DC unreachable, access denied) is rethrown as is.
        if ($_.Exception.GetType().Name -ne 'ADIdentityNotFoundException') { throw }
        Write-RmaLog -Level Warning -Message 'Organizational unit not found; nothing to delete' -Data @{
            organizationalUnit = $identity; server = $server.Server; queueSysId = $job.sys_id
        }
        return
    }

    $fields = @{ organizationalUnit = $ou.DistinguishedName; objectGuid = "$($ou.ObjectGUID)"; queueSysId = $job.sys_id }

    if ($ou.ProtectedFromAccidentalDeletion) {
        throw ("Organizational unit '$($ou.DistinguishedName)' is protected from accidental deletion. " +
            'An administrator must remove the protection before it can be deleted; the service account is not allowed to.')
    }

    # One level down and one object is enough to know it is not empty, whatever its size.
    $child = Get-ADObject -SearchBase $ou.DistinguishedName -SearchScope OneLevel -Filter * -ResultSetSize 1 @server
    if ($child) {
        throw ("Organizational unit '$($ou.DistinguishedName)' is not empty. " +
            'Move or delete what it holds first; it is never deleted as a tree.')
    }

    Remove-ADOrganizationalUnit -Identity $ou.ObjectGUID -Confirm:$false @server
    Write-RmaLog -Level Information -Message 'Organizational unit deleted' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
