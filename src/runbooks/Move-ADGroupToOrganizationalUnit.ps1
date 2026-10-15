#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.4.0' }
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Moves an Active Directory group to another organizational unit, from the ServiceNow command queue.
.DESCRIPTION
    Built on Unlock-ADUser, the reference for Active Directory runbooks; only the body
    differs. A move deletes the group from one OU and creates it in the other, so the
    service account needs the Groups scope of scripts/Grant-RmaAdDelegation.ps1 on both
    (docs/INSTALLATION.md, step 6a).

    Moving is idempotent: a group that is already in the target OU completes the job
    unchanged. A group or a target OU that does not exist fails the job, because the move
    asked for has not happened. A group protected from accidental deletion cannot be moved
    out of its OU and fails with the directory's own reason.

    The group is moved by its objectGUID, read in the same job, into the target OU's
    distinguished name as the directory returns it.
.PARAMETER DomainController
    Host name or IP address of a domain controller for the domain.
.PARAMETER AdUserName
    The AD service account the runbook acts as.
.PARAMETER AdSecretName
    The Key Vault secret holding that account's password.
.NOTES
    Payload:
      group   the group, as any identity Get-ADGroup accepts: sAMAccountName,
              distinguished name, objectGUID or SID
      ou      the target organizational unit, as a distinguished name or objectGUID
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Move-ADGroupToOrganizationalUnit' -Body {
    param($job, $p)

    # Passed to -Identity, never into an LDAP filter, so neither can widen a search. Read
    # through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $field = {
        param($Payload, [string] $Name)
        $value = "$($Payload.PSObject.Properties[$Name]?.Value)".Trim()
        if (-not $value -or $value -match '[\x00-\x1F]') {
            throw "Payload field '$Name' is empty or contains control characters. Correct the ServiceNow record."
        }
        $value
    }
    $groupIdentity = & $field $p 'group'
    $ouIdentity = & $field $p 'ou'

    # Matched by name: a typed catch needs the ActiveDirectory assembly loaded to resolve.
    $isNotFound = { param($ErrorRecord) $ErrorRecord.Exception.GetType().Name -eq 'ADIdentityNotFoundException' }

    try {
        $target = Get-ADOrganizationalUnit -Identity $ouIdentity @server
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        throw "No organizational unit '$ouIdentity' on $($server.Server). Correct the ServiceNow record."
    }
    try {
        $group = Get-ADGroup -Identity $groupIdentity @server
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        throw "No Active Directory group '$groupIdentity' on $($server.Server). Correct the ServiceNow record."
    }

    # The parent is everything after the group's own RDN. A comma inside the RDN is
    # escaped as '\,', so the split is on the first unescaped comma.
    $parent = $group.DistinguishedName -replace '^(?:[^,\\]|\\.)+,', ''
    $fields = @{
        group = $group.SamAccountName; objectGuid = "$($group.ObjectGUID)"; queueSysId = $job.sys_id
        from = $parent; to = $target.DistinguishedName
    }

    if ($parent -eq $target.DistinguishedName) {
        Write-RmaLog -Level Information -Message 'AD group is already in the target OU; nothing to move' -Data $fields
        return
    }

    Move-ADObject -Identity $group.ObjectGUID -TargetPath $target.DistinguishedName @server
    Write-RmaLog -Level Information -Message 'AD group moved' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
