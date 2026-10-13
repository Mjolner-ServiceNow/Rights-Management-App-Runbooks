#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.2.0' }
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Removes a user from an Active Directory group, from the ServiceNow command queue.
.DESCRIPTION
    Built on Unlock-ADUser, the reference for Active Directory runbooks; only the body
    differs. The service account needs the Groups scope of scripts/Grant-RmaAdDelegation.ps1
    on the group's OU (docs/INSTALLATION.md, step 6a).

    Removing is idempotent: when the membership does not exist, because the user is not a
    member or because the group or the user does not exist, the job completes with a log
    record saying which, since the outcome ServiceNow asked for is true
    (docs/DECISIONS.md D15). 1.0 failed the job in all three cases.

    Membership is read from the user's memberOf, never by listing the group's members: a
    group can have hundreds of thousands. memberOf does not list the user's primary group,
    which cannot be removed this way anyway. The member is removed by objectGUID, read in
    the same job.
.PARAMETER DomainController
    Host name or IP address of a domain controller for the domain.
.PARAMETER AdUserName
    The AD service account the runbook acts as.
.PARAMETER AdSecretName
    The Key Vault secret holding that account's password.
.NOTES
    Payload:
      group   the group, as any identity Get-ADGroup accepts
      user    the member to remove, as any identity Get-ADUser accepts
    Both may be a sAMAccountName, distinguished name, objectGUID or SID.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-ADGroupMember' -Body {
    param($job, $p)

    # Passed to -Identity, never into an LDAP filter, so neither can widen a search. Read
    # through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $field = {
        param([string] $Name)
        $value = "$($p.PSObject.Properties[$Name]?.Value)".Trim()
        if (-not $value -or $value -match '[\x00-\x1F]') {
            throw "Payload field '$Name' is empty or contains control characters. Correct the ServiceNow record."
        }
        $value
    }
    $groupIdentity = & $field 'group'
    $userIdentity = & $field 'user'

    # Matched by name: a typed catch needs the ActiveDirectory assembly loaded to resolve.
    $isNotFound = { param($ErrorRecord) $ErrorRecord.Exception.GetType().Name -eq 'ADIdentityNotFoundException' }
    $absent = @{ group = $groupIdentity; user = $userIdentity; queueSysId = $job.sys_id }

    try {
        $group = Get-ADGroup -Identity $groupIdentity @server
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        Write-RmaLog -Level Warning -Message 'AD group not found; the membership does not exist' -Data $absent
        return
    }
    try {
        $user = Get-ADUser -Identity $userIdentity -Properties MemberOf @server
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        Write-RmaLog -Level Warning -Message 'AD user not found; the membership does not exist' -Data $absent
        return
    }

    $fields = @{
        group = $group.SamAccountName; groupGuid = "$($group.ObjectGUID)"
        user = $user.SamAccountName; userGuid = "$($user.ObjectGUID)"; queueSysId = $job.sys_id
    }

    if (@($user.MemberOf) -notcontains $group.DistinguishedName) {
        Write-RmaLog -Level Information -Message 'AD user is not a member of the group; nothing to remove' -Data $fields
        return
    }

    Remove-ADGroupMember -Identity $group.ObjectGUID -Members $user.ObjectGUID -Confirm:$false @server
    Write-RmaLog -Level Information -Message 'AD group member removed' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
