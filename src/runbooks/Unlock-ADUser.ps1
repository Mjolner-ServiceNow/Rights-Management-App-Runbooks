#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.2.1' }
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Unlocks a locked-out Active Directory user from the ServiceNow command queue.
.DESCRIPTION
    The reference for Active Directory runbooks, as Create-EntraUser is for Entra ID. The
    shape is the same: a fixed setup, then a body that Invoke-RmaQueueLoop runs once per
    job it wins.

    What is particular to Active Directory:
      - The service account's password comes from Key Vault, once, before the loop. Every
        AD cmdlet gets -Server and -Credential: a Hybrid Worker job runs as SYSTEM, whose
        own identity is not the service account.
      - ActiveDirectory is a Windows feature, not a gallery module, so it is required
        without a version. scripts/Initialize-RmaWorker.ps1 installs it.

    Unlocking is idempotent. A user who is not locked out is logged and the job completes:
    the outcome ServiceNow asked for is already true.
.PARAMETER DomainController
    Host name or IP address of a domain controller for the domain.
.PARAMETER AdUserName
    The AD service account the runbook acts as.
.PARAMETER AdSecretName
    The Key Vault secret holding that account's password.
.NOTES
    Payload: user, the account to unlock, as any identity Get-ADUser accepts:
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Unlock-ADUser' -Body {
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
        $user = Get-ADUser -Identity $identity -Properties LockedOut @server
    } catch {
        # Matched by name: a typed catch needs the ActiveDirectory assembly loaded to
        # resolve, and every other failure (DC unreachable, access denied) is rethrown as is.
        if ($_.Exception.GetType().Name -ne 'ADIdentityNotFoundException') { throw }
        throw "No Active Directory user '$identity' on $($server.Server). Correct the ServiceNow record."
    }

    $fields = @{ samAccountName = $user.SamAccountName; objectGuid = "$($user.ObjectGUID)"; queueSysId = $job.sys_id }

    if (-not $user.LockedOut) {
        Write-RmaLog -Level Information -Message 'AD user is not locked out; nothing to unlock' -Data $fields
        return
    }

    Unlock-ADAccount -Identity $user @server
    Write-RmaLog -Level Information -Message 'AD user unlocked' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
