#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.5.0' }
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Resets an Active Directory user's password from the ServiceNow command queue.
.DESCRIPTION
    Built on Unlock-ADUser, the reference for Active Directory runbooks; only the body
    differs. The service account needs the Users scope of scripts/Grant-RmaAdDelegation.ps1
    on the user's OU (docs/INSTALLATION.md, step 6a).

    The payload carries the new password. It is never logged and never put into a message:
    it goes from the payload into a SecureString and from there to Set-ADAccountPassword.
    A password the domain refuses, for example one that does not meet the policy, fails the
    job with the directory's own reason, which does not contain the password.

    After the reset, and only when the payload asks: the user must change the password at
    next logon, and the account is unlocked. A user who does not exist fails the job; a
    password cannot be reset on nothing.
.PARAMETER DomainController
    Host name or IP address of a domain controller for the domain.
.PARAMETER AdUserName
    The AD service account the runbook acts as.
.PARAMETER AdSecretName
    The Key Vault secret holding that account's password.
.NOTES
    Payload:
      user        the account, as any identity Get-ADUser accepts: sAMAccountName,
                  distinguished name, objectGUID or SID
      password    the new password
      mustChange  true to require a change at next logon; false or absent leaves it as is
      unlock      true to unlock the account as well; false or absent leaves it as is
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Set-ADUserPassword' -Body {
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

    # The password goes straight into a SecureString, character by character, and the
    # plain copy is dropped. Nothing below may log it or put it into a message.
    $plain = "$($p.PSObject.Properties['password']?.Value)"
    if (-not $plain) { throw "Payload field 'password' is empty. Correct the ServiceNow record." }
    $newPassword = [securestring]::new()
    foreach ($character in $plain.ToCharArray()) { $newPassword.AppendChar($character) }
    $newPassword.MakeReadOnly()
    $plain = $null

    # true or false, as a JSON boolean or as text; absent is false. Anything else is
    # rejected rather than guessed at, before the directory is touched.
    $flag = {
        param([string] $Name)
        $value = $p.PSObject.Properties[$Name]?.Value
        if ($null -eq $value -or "$value" -eq '') { return $false }
        if ($value -is [bool]) { return $value }
        switch ("$value".Trim().ToLowerInvariant()) {
            'true' { return $true }
            'false' { return $false }
        }
        throw "Payload field '$Name' must be true or false. Correct the ServiceNow record."
    }
    $mustChange = & $flag 'mustChange'
    $unlock = & $flag 'unlock'

    try {
        $user = Get-ADUser -Identity $identity @server
    } catch {
        # Matched by name: a typed catch needs the ActiveDirectory assembly loaded to
        # resolve, and every other failure (DC unreachable, access denied) is rethrown as is.
        if ($_.Exception.GetType().Name -ne 'ADIdentityNotFoundException') { throw }
        throw "No Active Directory user '$identity' on $($server.Server). Correct the ServiceNow record."
    }

    $fields = @{
        samAccountName = $user.SamAccountName; objectGuid = "$($user.ObjectGUID)"; queueSysId = $job.sys_id
        mustChange = $mustChange; unlock = $unlock
    }

    Set-ADAccountPassword -Identity $user.ObjectGUID -Reset -NewPassword $newPassword @server
    if ($mustChange) { Set-ADUser -Identity $user.ObjectGUID -ChangePasswordAtLogon $true @server }
    if ($unlock) { Unlock-ADAccount -Identity $user.ObjectGUID @server }

    Write-RmaLog -Level Information -Message 'AD user password reset' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
