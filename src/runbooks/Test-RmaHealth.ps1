#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '1.0.0' }

<#
.SYNOPSIS
    Read-only health check. Run by the deployment pipeline before any schedule is enabled.
.DESCRIPTION
    Proves every dependency of the platform works end to end without mutating anything:
    managed identity, Key Vault, ServiceNow, the domain record, Graph, and (optionally)
    Active Directory.

    This is what turns "the deployment succeeded" into "the deployment works". A green
    infrastructure deployment with a broken identity looks identical to a working one
    until the first real job fails.
.NOTES
    Safe to run at any time. Performs no writes.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'These parameters are used inside the Add-Check scriptblocks. PSScriptAnalyzer does not resolve variable use across a scriptblock closure.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ApplicationId,

    [switch] $IncludeActiveDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name, [scriptblock]$Test)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Test
        $checks.Add([pscustomobject]@{ Check = $Name; Status = 'Pass'; Ms = $sw.ElapsedMilliseconds; Detail = "$detail" })
    } catch {
        $checks.Add([pscustomobject]@{ Check = $Name; Status = 'FAIL'; Ms = $sw.ElapsedMilliseconds; Detail = $_.Exception.Message })
    }
}

Write-RmaLog -Level Information -Message 'Health check started' -Data @{ instance = $Instance; domainId = $DomainId }

$context = $null

Add-Check 'Managed identity token' {
    $null = Get-RmaAccessToken -Resource 'https://vault.azure.net' -ManagedIdentityClientId $ManagedIdentityClientId
    'acquired'
}

Add-Check 'Key Vault + ServiceNow + domain record' {
    $script:context = Test-RmaPrerequisite -Instance $Instance -DomainId $DomainId -VaultName $VaultName `
        -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName `
        -RequireDomainField @('TenantId')
    "tenant $($script:context.Domain.TenantId)"
}

Add-Check 'Microsoft Graph token exchange' {
    if (-not $script:context) { throw 'Skipped: prerequisite check did not complete.' }
    $null = Get-RmaAccessToken -Federated -Resource 'https://graph.microsoft.com/.default' `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -ApplicationId $ApplicationId -TenantId $script:context.Domain.TenantId
    'federated token acquired'
}

Add-Check 'ServiceNow command queue readable' {
    if (-not $script:context) { throw 'Skipped: prerequisite check did not complete.' }
    $jobs = Get-RmaPendingJob -Context $script:context -DomainId $DomainId -Command 'Test-RmaHealth' -Limit 1
    "queue reachable ($($jobs.Count) pending for this command)"
}

if ($IncludeActiveDirectory) {
    Add-Check 'Active Directory reachable' {
        if (-not $script:context) { throw 'Skipped: prerequisite check did not complete.' }
        $dc = $script:context.Domain.DomainControllerIp
        if (-not $dc) { throw 'domain_controller_ip is not set on the domain record.' }
        $null = Get-ADRootDSE -Server $dc
        "contacted $dc"
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
