#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                        RequiredVersion = '1.0.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication';      RequiredVersion = '2.25.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';               RequiredVersion = '2.25.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Identity.DirectoryManagement'; RequiredVersion = '2.25.0' }

<#
.SYNOPSIS
    Creates an Entra ID user from the ServiceNow command queue.
.DESCRIPTION
    Reference implementation for the migrated runbooks. Compare against the original:
    365 lines became roughly 70, because claiming, terminal state, bounds, retry, logging
    and authentication all moved into RMA.Runbooks.

    What is different beyond the size:
      - No module installation. Dependencies are asserted above, before the body runs.
      - No credential handling. The identity is the workload's own.
      - The payload is never logged wholesale. Only named, non-secret fields are.
      - The job cannot be executed twice, and cannot be stranded.
      - Creation is idempotent: an existing UPN is reported, not retried into a failure.
.NOTES
    Every other runbook follows this shape. Only the scriptblock body differs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ApplicationId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$context = Test-RmaPrerequisite -Instance $Instance -DomainId $DomainId -VaultName $VaultName `
    -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName `
    -RequireDomainField @('TenantId')

Connect-RmaGraph -Context $context -ApplicationId $ApplicationId

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Create-EntraUser' -Body {
    param($job, $p)

    $domain = (Get-MgDomain -All | Where-Object { $_.IsDefault }).Id
    if (-not $domain) { throw 'No default verified domain found in the tenant.' }

    $userName = "$($p.username)".Trim()
    if (-not $userName) { throw 'Payload field "username" is empty.' }
    $upn = "$userName@$domain"

    # Idempotency. A duplicate execution, or a retry after a partial failure, must not
    # produce a second user or a spurious failure.
    if (Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue) {
        Write-RmaLog -Level Warning -Message 'User already exists; treating as success' -Data @{ upn = $upn }
        return
    }

    $given   = "$($p.givenname)".Trim()
    $surname = "$($p.surname)".Trim()
    $display = if ($given -and $surname) { "$given $surname" } elseif ($given) { $given } else { $userName }

    $newUser = @{
        AccountEnabled    = $true
        UserPrincipalName = $upn
        MailNickname      = $userName
        DisplayName       = $display
        PasswordProfile   = @{ Password = $p.password; ForceChangePasswordNextSignIn = $true }
    }

    # Optional attributes, added only when supplied. Sending an empty string where Graph
    # expects null is rejected, which is why each is guarded rather than assigned blindly.
    $optional = @{
        GivenName      = $given
        Surname        = $surname
        City           = "$($p.city)".Trim()
        CompanyName    = "$($p.company)".Trim()
        Department     = "$($p.department)".Trim()
        JobTitle       = "$($p.title)".Trim()
        PostalCode     = "$($p.postalcode)".Trim()
        StreetAddress  = "$($p.streetaddress)".Trim()
        MobilePhone    = "$($p.mobilephone)".Trim()
        EmployeeId     = "$($p.employeeid)".Trim()
        OfficeLocation = "$($p.physicaldelofficename)".Trim()
    }
    foreach ($key in $optional.Keys) {
        if (-not [string]::IsNullOrWhiteSpace($optional[$key])) { $newUser[$key] = $optional[$key] }
    }

    # BusinessPhones is a string array. The singular form is not a valid parameter and
    # caused every job in the previous version to fail at binding.
    $businessPhone = "$($p.businessphone)".Trim()
    if ($businessPhone) { $newUser['BusinessPhones'] = @($businessPhone) }

    $created = New-MgUser @newUser

    # Named fields only. Never the payload object: it carries the password.
    Write-RmaLog -Level Information -Message 'Entra user created' -Data @{
        upn = $upn; id = $created.Id; displayName = $display; queueSysId = $job.sys_id
    }

    $writeBack = @{
        sysid             = $p.usersysid
        userprincipalname = $created.UserPrincipalName
        displayname       = $created.DisplayName
        objectguid        = $created.Id
        enabled           = $created.AccountEnabled
    } | ConvertTo-Json

    Invoke-RmaRestMethod -Method PUT -Headers $context.Headers -Body $writeBack `
        -Uri "$($context.BaseUri)/api/x_autps_active_dir/domain/$DomainId/user" | Out-Null
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
