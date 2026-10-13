#Requires -Version 5.1

<#
.SYNOPSIS
    Delegates to the AD service account the rights the Active Directory runbooks use, on
    the OUs the solution manages. Idempotent.
.DESCRIPTION
    The AD runbooks act as one service account (AdUserName; its password is the Key Vault
    secret AdSecretName). A member of Domain Users can read the directory, which is all
    Test-RmaHealth and the Import-AD* runbooks need, but every write fails with
    'Access is denied' (#123). This grants the writes, on the managed OUs only, through
    inherited permissions on those OUs. It never adds the account to a group: not Domain
    Admins, not Account Operators.

    Three scopes, each granted on every OU given and inherited by everything below it:

      Users                Create and delete user objects; read and write all properties
                           of user objects; Reset Password on user objects.
      Groups               Create and delete group objects; read and write all properties
                           of group objects, member included.
      OrganizationalUnits  Create and delete OUs below the given ones; read and write all
                           properties of those OUs.

    No scope grants Write Permissions (WRITE_DAC). Clearing 'Protect object from accidental
    deletion' is a permission change, so Remove-ADOrganizationalUnit cannot remove a
    protected OU; that stays an administrator's decision.

    Accounts protected by AdminSDHolder (adminCount=1: Domain Admins and the other
    privileged groups) do not inherit these permissions, so delegating on an OU that holds
    them does not let the service account reset their passwords. Keep them out of the
    managed OUs anyway.

    Each grant is written as one dsacls.exe call. Run this as a domain administrator, on a
    domain controller or a machine with the AD DS tools (RSAT-ADDS-Tools). Every grant is
    also returned as an object, so -WhatIf shows exactly what would be written.
.PARAMETER ServiceAccount
    The AD service account, as DOMAIN\sAMAccountName.
.PARAMETER OrganizationalUnit
    Distinguished names of the OUs whose objects the runbooks manage.
.PARAMETER Scope
    Which rights to grant. Grant only what the runbooks the customer uses need; see the
    table in docs/INSTALLATION.md.
.PARAMETER Server
    A domain controller to write to. Defaults to whichever dsacls finds.
.EXAMPLE
    ./Grant-RmaAdDelegation.ps1 -ServiceAccount 'CONTOSO\svc-rma' -OrganizationalUnit 'OU=Staff,DC=contoso,DC=com' -Scope Users -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^\\]+\\[^\\]+$')]
    [string] $ServiceAccount,

    [Parameter(Mandatory)][ValidatePattern('^(OU|CN)=.+,DC=.+$')]
    [string[]] $OrganizationalUnit,

    [Parameter(Mandatory)][ValidateSet('Users', 'Groups', 'OrganizationalUnits')]
    [string[]] $Scope,

    [ValidateNotNullOrEmpty()]
    [string] $Server
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dsacls grant syntax: <account>:<rights>;<object type or property>;<inherited object type>.
# /I:T applies to the OU and everything below it, /I:S only to the objects below it.
$grants = @{
    Users               = @(
        @{ Inherit = 'T'; Rights = 'CCDC;user'; Purpose = 'create and delete user objects' }
        @{ Inherit = 'S'; Rights = 'RPWP;;user'; Purpose = 'read and write all properties of user objects' }
        @{ Inherit = 'S'; Rights = 'CA;Reset Password;user'; Purpose = 'reset the password of user objects' }
    )
    Groups              = @(
        @{ Inherit = 'T'; Rights = 'CCDC;group'; Purpose = 'create and delete group objects' }
        @{ Inherit = 'S'; Rights = 'RPWP;;group'; Purpose = 'read and write all properties of group objects' }
    )
    OrganizationalUnits = @(
        @{ Inherit = 'T'; Rights = 'CCDC;organizationalUnit'; Purpose = 'create and delete OUs' }
        @{ Inherit = 'S'; Rights = 'RPWP;;organizationalUnit'; Purpose = 'read and write all properties of OUs' }
    )
}

$dsacls = $null
foreach ($ou in $OrganizationalUnit) {
    $target = if ($Server) { "\\$Server\$ou" } else { $ou }
    foreach ($name in ($Scope | Select-Object -Unique)) {
        foreach ($grant in $grants[$name]) {
            $arguments = @($target, "/I:$($grant.Inherit)", '/G', "$($ServiceAccount):$($grant.Rights)")
            $result = [pscustomobject]@{
                OrganizationalUnit = $ou
                Scope              = $name
                Purpose            = $grant.Purpose
                Arguments          = $arguments
                Applied            = $false
            }

            if ($PSCmdlet.ShouldProcess($ou, "Grant $ServiceAccount the right to $($grant.Purpose)")) {
                if (-not $dsacls) {
                    $dsacls = Get-Command dsacls.exe -ErrorAction SilentlyContinue
                    if (-not $dsacls) {
                        throw 'dsacls.exe not found. Run this on a domain controller or install the AD DS tools (RSAT-ADDS-Tools).'
                    }
                }
                $output = & $dsacls.Source @arguments 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "dsacls failed for '$ou' ($($grant.Purpose)): $($output | Select-Object -Last 3 | Out-String)"
                }
                $result.Applied = $true
            }
            $result
        }
    }
}
