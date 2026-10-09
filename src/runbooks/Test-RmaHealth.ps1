#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.1.0' }

<#
.SYNOPSIS
    Health check. Run by the ServiceNow application, which displays the result it posts
    back; also runnable by hand when that view is what is unavailable.
.DESCRIPTION
    Proves every dependency of the platform works end to end without mutating anything:
    managed identity, Key Vault, ServiceNow and the command queue always, then Graph and
    Active Directory for whichever of the two the domain uses.

    The result goes to ServiceNow as JSON, sent with PATCH to the domain's health endpoint
    (/api/x_autps_active_dir/domain/{DomainId}/health), and is printed to the job output
    as well. It is sent whether the checks passed or failed, since a failure is what the
    ServiceNow view is for. It cannot be sent when the Key Vault + ServiceNow check
    itself failed, because that check is what yields the connection; the job output is
    then the only record. A result that could not be sent fails the job.

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
    Safe to run at any time. Its one write is the result itself, to the health endpoint.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'These parameters are used inside the Add-Check scriptblocks. PSScriptAnalyzer does not resolve variable use across a scriptblock closure.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')] [string] $TenantId,
    [ValidatePattern('^[0-9a-fA-F-]{36}$')] [string] $ApplicationId,
    [ValidateNotNullOrEmpty()]              [string] $DomainController,
    [ValidateNotNullOrEmpty()]              [string] $AdUserName,
    [ValidateNotNullOrEmpty()]              [string] $AdSecretName = 'ad-service-account-password'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The Automation job pane prints ANSI escape codes literally, which buries the text of
# every error record under colour sequences.
$PSStyle.OutputRendering = 'PlainText'

# Which checks run is decided here, not by parameter sets: Azure Automation refuses to
# start a runbook that declares any ("Parameter sets in runbooks are not supported").
# Half of a pair fails and names the missing half, rather than silently skipping the
# check the caller evidently meant to run. $PSBoundParameters is captured because inside
# the Where-Object scriptblock it would be that scriptblock's own, which is empty.
$bound = $PSBoundParameters
$directories = [ordered]@{
    'Entra ID'         = @('TenantId', 'ApplicationId')
    'Active Directory' = @('DomainController', 'AdUserName')
}
$checked = @(
    foreach ($directory in $directories.Keys) {
        $pair = $directories[$directory]
        $passed = @($pair | Where-Object { $bound.ContainsKey($_) })
        if ($passed.Count -eq $pair.Count) {
            $directory
        } elseif ($passed.Count -gt 0) {
            $missing = @($pair | Where-Object { $_ -notin $passed })
            throw "The $directory check needs $($missing -join ', ') as well as $($passed -join ', '). Pass the whole pair, or none of it to skip the check."
        }
    }
)
if (-not $checked) {
    throw 'Pass TenantId and ApplicationId for the Entra ID check, DomainController and AdUserName for the Active Directory check, or all four. A health check that proves neither directory proves nothing a job depends on.'
}
if ($bound.ContainsKey('AdSecretName') -and 'Active Directory' -notin $checked) {
    throw 'AdSecretName is used only by the Active Directory check. Pass DomainController and AdUserName with it.'
}
$checkEntra = 'Entra ID' -in $checked
$checkActiveDirectory = 'Active Directory' -in $checked

$checks = [System.Collections.Generic.List[object]]::new()

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

Write-RmaLog -Level Information -Message 'Health check started' -Data @{ instance = $Instance; domainId = $DomainId; checks = $checked }

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
    $jobs = @(Get-RmaPendingJob -Context $script:context -DomainId $DomainId -Command 'Test-RmaHealth' -Limit 1)
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

$failed = @($checks | Where-Object Status -EQ 'FAIL')

# The time is UTC in the format ServiceNow keeps a Date/Time in. GlideDateTime given ISO
# 8601 keeps the date and stores midnight, which is how claimed_at once lost its time.
$report = [ordered]@{
    status     = $failed ? 'fail' : 'pass'
    checked_at = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    worker     = [Environment]::MachineName
    passed     = $checks.Count - $failed.Count
    total      = $checks.Count
    checks     = @(
        foreach ($check in $checks) {
            # Capped as Set-RmaJobState caps an exception: a long error is the detail most
            # likely to be wanted, and the one most likely to overrun a field and fail the request.
            $detail = $check.Detail.Length -gt 4000 ? $check.Detail.Substring(0, 3997) + '...' : $check.Detail
            [ordered]@{
                name        = $check.Check
                status      = $check.Status -eq 'Pass' ? 'pass' : 'fail'
                duration_ms = $check.Ms
                detail      = $detail
            }
        }
    )
}

$reportError = $null
if ($context) {
    try {
        # charset named explicitly: a detail can carry an AD or Graph error in Danish, and
        # without it PowerShell before 7.4 encodes a string body as ISO-8859-1.
        $null = Invoke-RmaRestMethod -Method PATCH -Headers $context.Headers `
            -Uri "$($context.BaseUri)/api/x_autps_active_dir/domain/$DomainId/health" `
            -ContentType 'application/json; charset=utf-8' `
            -Body ($report | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        $reportError = $_.Exception.Message
    }
} else {
    $reportError = 'there is no ServiceNow connection, because the Key Vault + ServiceNow check failed'
}

# One line per check with its detail on the next, never a table: Format-Table cuts the
# detail at the width of the pane, and the detail of a failed check is the error message,
# which is the one thing the reader came for.
Write-Output ''
Write-Output 'RMA health check'
Write-Output '================'
foreach ($check in $checks) {
    Write-Output ('{0,-4}  {1} ({2} ms)' -f $check.Status, $check.Check, $check.Ms)
    Write-Output "      $($check.Detail)"
}
Write-Output ''
Write-Output ($reportError ? "Not reported to ServiceNow: $reportError" : 'Reported to ServiceNow.')
Write-Output ''

# Information even when a check failed. The throw below is the error record a failed run
# produces; logging the same summary at Error as well wrote a second one, which the job
# pane interleaves with the output above.
Write-RmaLog -Level Information `
    -Message "Health check finished: $($checks.Count - $failed.Count)/$($checks.Count) passed" `
    -Data @{ failed = @($failed | ForEach-Object Check); reported = -not $reportError }

if ($failed) {
    $unreported = $reportError ? ' The result was not reported to ServiceNow.' : ''
    throw "Health check failed: $(@($failed | ForEach-Object Check) -join ', '). The reason for each is in the output above.$unreported"
}
if ($reportError) {
    # Every check passed, but ServiceNow still shows the last result it received, which
    # may be a failure, or nothing at all.
    throw "All checks passed, but the result could not be reported to ServiceNow: $reportError"
}
Write-Output 'All checks passed.'
