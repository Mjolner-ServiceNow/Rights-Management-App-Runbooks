#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.2.1' }
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Deletes an Active Directory user from the ServiceNow command queue.
.DESCRIPTION
    Built on Unlock-ADUser, the reference for Active Directory runbooks; only the body
    differs. The service account needs the Users scope of scripts/Grant-RmaAdDelegation.ps1
    on the user's OU (docs/INSTALLATION.md, step 6a).

    Deleting is idempotent: a user who does not exist is logged as a warning and the job
    completes, because the outcome ServiceNow asked for is true (docs/DECISIONS.md D15).
    1.0 failed the job instead, which made every repeated execution fail after the first
    had succeeded.

    The user is deleted by its objectGUID, read in the same job, so the delete cannot hit
    a different object that took the name in between. A user that is protected from
    accidental deletion, or that has child objects (for example ActiveSync device
    containers), fails with the directory's own reason: the service account deletes leaf
    user objects only, and is not given the rights to do more.
.PARAMETER DomainController
    Host name or IP address of a domain controller for the domain.
.PARAMETER AdUserName
    The AD service account the runbook acts as.
.PARAMETER AdSecretName
    The Key Vault secret holding that account's password.
.NOTES
    Payload: user, the account to delete, as any identity Get-ADUser accepts:
    sAMAccountName, distinguished name, objectGUID or SID.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Remove-ADUser' -Body {
    param($job, $p)

    # Passed to -Identity, never into an LDAP filter, so it cannot widen the search. Only
    # emptiness and control characters are rejected here; anything else that names no
    # user is reported by Get-ADUser below.
    # Read through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $identity = "$($p.PSObject.Properties['user']?.Value)".Trim()
    if (-not $identity -or $identity -match '[\x00-\x1F]') {
        throw "Payload field 'user' is empty or contains control characters. Correct the ServiceNow record."
    }

    try {
        $user = Get-ADUser -Identity $identity @server
    } catch {
        # Matched by name: a typed catch needs the ActiveDirectory assembly loaded to
        # resolve, and every other failure (DC unreachable, access denied) is rethrown as is.
        if ($_.Exception.GetType().Name -ne 'ADIdentityNotFoundException') { throw }
        Write-RmaLog -Level Warning -Message 'AD user not found; nothing to delete' -Data @{
            user = $identity; server = $server.Server; queueSysId = $job.sys_id
        }
        return
    }

    $fields = @{ samAccountName = $user.SamAccountName; objectGuid = "$($user.ObjectGUID)"; queueSysId = $job.sys_id }

    Remove-ADUser -Identity $user.ObjectGUID -Confirm:$false @server
    Write-RmaLog -Level Information -Message 'AD user deleted' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
