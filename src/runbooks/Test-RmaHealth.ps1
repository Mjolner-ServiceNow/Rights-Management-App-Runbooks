#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.0.0' }

<#
.SYNOPSIS
    Read-only health check. Run by the ServiceNow application, which surfaces the result
    in ServiceNow; also runnable by hand when that view is what is unavailable.
.DESCRIPTION
    Proves every dependency of the platform works end to end without mutating anything:
    managed identity, Key Vault, ServiceNow and the command queue always, then Graph and
    Active Directory for whichever of the two the domain uses.

    A domain can use Entra ID, Active Directory or both, so each of those checks runs when
    its parameters are passed and is left out otherwise. At least one of them is required:
    a health check that proves neither directory proves nothing a job depends on.

    Every value is a parameter, passed by the ServiceNow application exactly as it passes
    them to the command runbooks, so a passing health check proves the values the real
    jobs will receive.

    This is what turns "the deployment succeeded" into "the deployment works". A green
    infrastructure deployment with a broken identity looks identical to a working one
    until the first real job fails.
.PARAMETER TenantId
    Entra tenant ID. Passed with ApplicationId, adds the Microsoft Graph check.
.PARAMETER DomainController
    Host name or IP address of a domain controller for the domain. Passed with AdUserName,
    adds the Active Directory check.
.PARAMETER AdSecretName
    Key Vault secret holding the AD service account's password. One per AD domain when an
    installation serves more than one.
.NOTES
    Safe to run at any time. Performs no writes.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'These parameters are used inside the Add-Check scriptblocks. PSScriptAnalyzer does not resolve variable use across a scriptblock closure.')]
# Three parameter sets, so that which checks run is decided at binding: Entra, Active
# Directory, or both. A parameter in two sets carries one attribute per set. Passing half
# of a pair fails binding and names the missing half, rather than silently skipping the
# check the caller evidently meant to run.
[CmdletBinding(DefaultParameterSetName = 'Entra')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,

    [Parameter(Mandatory, ParameterSetName = 'Entra')]
    [Parameter(Mandatory, ParameterSetName = 'EntraAndActiveDirectory')]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $TenantId,

    [Parameter(Mandatory, ParameterSetName = 'Entra')]
    [Parameter(Mandatory, ParameterSetName = 'EntraAndActiveDirectory')]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $ApplicationId,

    [Parameter(Mandatory, ParameterSetName = 'ActiveDirectory')]
    [Parameter(Mandatory, ParameterSetName = 'EntraAndActiveDirectory')]
    [ValidateNotNullOrEmpty()]
    [string] $DomainController,

    [Parameter(Mandatory, ParameterSetName = 'ActiveDirectory')]
    [Parameter(Mandatory, ParameterSetName = 'EntraAndActiveDirectory')]
    [ValidateNotNullOrEmpty()]
    [string] $AdUserName,

    [Parameter(ParameterSetName = 'ActiveDirectory')]
    [Parameter(ParameterSetName = 'EntraAndActiveDirectory')]
    [ValidateNotNullOrEmpty()]
    [string] $AdSecretName = 'ad-service-account-password'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checks = [System.Collections.Generic.List[object]]::new()
$checkEntra = $PSCmdlet.ParameterSetName -in 'Entra', 'EntraAndActiveDirectory'
$checkActiveDirectory = $PSCmdlet.ParameterSetName -in 'ActiveDirectory', 'EntraAndActiveDirectory'

function Add-Check {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Test
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Test
        $checks.Add([pscustomobject]@{ Check = $Name; Status = 'Pass'; Ms = $sw.ElapsedMilliseconds; Detail = "$detail" })
    } catch {
        $checks.Add([pscustomobject]@{ Check = $Name; Status = 'FAIL'; Ms = $sw.ElapsedMilliseconds; Detail = $_.Exception.Message })
    }
}

Write-RmaLog -Level Information -Message 'Health check started' -Data @{ instance = $Instance; domainId = $DomainId; checks = $PSCmdlet.ParameterSetName }

$context = $null

Add-Check 'Managed identity token' {
    $null = Get-RmaAccessToken -Resource 'https://vault.azure.net' -ManagedIdentityClientId $ManagedIdentityClientId
    'acquired'
}

Add-Check 'Key Vault + ServiceNow' {
    $script:context = Test-RmaPrerequisite -Instance $Instance -VaultName $VaultName `
        -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName
    "authenticated as $ServiceNowUserName"
}

if ($checkEntra) {
    Add-Check 'Microsoft Graph token exchange' {
        $null = Get-RmaAccessToken -Federated -Resource 'https://graph.microsoft.com/.default' `
            -ManagedIdentityClientId $ManagedIdentityClientId `
            -ApplicationId $ApplicationId -TenantId $TenantId
        "federated token acquired for tenant $TenantId"
    }
}

Add-Check 'ServiceNow command queue readable' {
    if (-not $script:context) { throw 'Skipped: prerequisite check did not complete.' }
    $jobs = Get-RmaPendingJob -Context $script:context -DomainId $DomainId -Command 'Test-RmaHealth' -Limit 1
    "queue reachable ($($jobs.Count) pending for this command)"
}

if ($checkActiveDirectory) {
    Add-Check 'Active Directory reachable' {
        # Authenticated, so a wrong AD username or an expired password fails here rather
        # than in the first real job.
        $credential = Get-RmaSecret -VaultName $VaultName -Name $AdSecretName `
            -ManagedIdentityClientId $ManagedIdentityClientId -AsCredential -UserName $AdUserName
        $adDomain = Get-ADDomain -Server $DomainController -Credential $credential
        "contacted $DomainController as $AdUserName ($($adDomain.DNSRoot))"
    }
}

Write-Output ''
Write-Output 'RMA health check'
Write-Output '================'
$checks | Format-Table -AutoSize | Out-String -Width 160 | Write-Output

$failed = @($checks | Where-Object Status -EQ 'FAIL')
Write-RmaLog -Level $(if ($failed) { 'Error' } else { 'Information' }) `
    -Message "Health check finished: $($checks.Count - $failed.Count)/$($checks.Count) passed" `
    -Data @{ failed = @($failed.Check) }

if ($failed) {
    throw "Health check failed: $($failed.Check -join ', ')"
}
Write-Output 'All checks passed.'
