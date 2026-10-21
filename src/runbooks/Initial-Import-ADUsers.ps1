#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.6.0' }
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Imports every Active Directory user into ServiceNow from the ServiceNow command queue.
.DESCRIPTION
    Built on Unlock-ADUser, the reference for Active Directory runbooks. The service
    account needs read access to the users only; no delegation scope is needed.

    One job is one full import, rebuilt as docs/DECISIONS.md D12 agreed:
      - The domain's sync state is set to 'updating', and back to 'ready' with the domain
        and forest modes and whether PAM is enabled when the import ends, also when it
        fails. 1.0 wrote 'ready' before the import had started.
      - Every user is read from the directory first, then written in batches of
        ImportBatchSize to /aduser/insertMultiple, which upserts on objectguid. Reading
        first keeps the directory enumeration as short as 1.0's: Active Directory Web
        Services ends an enumeration that is held open for 30 minutes, and writing while
        it is open would hold it for the length of the import.
      - A batch the endpoint refuses fails the job at once, after Invoke-RmaRestMethod's
        retries. A user the endpoint reports as failed is logged, the import continues,
        and the job fails at the end.
      - /aduser/cleanup, which removes the users not imported since the previous run, is
        called only when every user was written and at least one was read. After a
        partial import it would delete good records.
      - The import holds the job for as long as it runs. Invoke-RmaQueueLoop's heartbeat
        keeps the claim, so the watchdog does not requeue it.

    The fields are 1.0's, with three corrections. Dates are sent as ServiceNow Date/Time
    (UTC, 'yyyy-MM-dd HH:mm:ss'): 1.0 sent ISO 8601, which ServiceNow stores as midnight.
    lastLogon is converted from the directory's FILETIME: 1.0 sent the number itself, which
    ServiceNow stored as a date in the year 9260. emailaddress is the mail attribute, which
    is what 1.0 meant by preferring mail over EmailAddress; they are the same attribute.

    extensionAttribute1 to 15 are sent as well, as extensionattribute1 to 15, which 1.0 did
    not. They exist only in a forest whose schema was extended for Exchange, and asking
    Get-ADUser for an attribute the schema lacks fails the whole read. So the schema is read
    first, and only the ones it has are asked for and sent. An attribute that is empty in AD
    is sent as null, so a value cleared in AD is cleared in ServiceNow.
.PARAMETER DomainController
    Host name or IP address of a domain controller for the domain.
.PARAMETER AdUserName
    The AD service account the runbook acts as.
.PARAMETER AdSecretName
    The Key Vault secret holding that account's password.
.PARAMETER ImportBatchSize
    Users per /aduser/insertMultiple request. The endpoint's own limit is not yet known
    (#106); a request must finish within Invoke-RmaRestMethod's 60-second timeout.
.NOTES
    Payload: none besides action. The job imports the whole domain.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ImportBatchSize',
    Justification = 'Used inside the Invoke-RmaQueueLoop body. PSScriptAnalyzer does not resolve variable use across a scriptblock closure.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $DomainController,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $AdUserName,
    [ValidateNotNullOrEmpty()]                                  [string] $AdSecretName = 'ad-service-account-password',
    [ValidateRange(1, 1000)]                                    [int]    $ImportBatchSize = 200
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Initial-Import-ADUsers' -Body {
    # The payload carries nothing but the action, which the loop has already checked.
    param($job)

    $domainUri = "$($context.BaseUri)/api/x_autps_active_dir/domain/$DomainId"
    $properties = @(
        'AccountExpirationDate', 'AccountLockoutTime', 'CannotChangePassword', 'City', 'Company', 'Country',
        'Department', 'Description', 'DisplayName', 'EmployeeID', 'EmployeeNumber', 'EmployeeType', 'lastLogon',
        'LockedOut', 'mail', 'MobilePhone', 'Office', 'OfficePhone', 'PasswordExpired', 'PasswordNeverExpires',
        'PostalCode', 'PreferredLanguage', 'StreetAddress', 'Title'
    )

    # ServiceNow Date/Time: UTC, 'yyyy-MM-dd HH:mm:ss'. ISO 8601 would be stored as midnight.
    $glide = {
        param($date)
        if ($null -eq $date) { return $null }
        ([datetime] $date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    }
    # lastLogon is a FILETIME: 0 for never, and the largest value for never as well.
    $maxFileTime = [datetime]::MaxValue.ToFileTimeUtc()
    $fromFileTime = {
        param($fileTime)
        if ($null -eq $fileTime -or $fileTime -le 0 -or $fileTime -gt $maxFileTime) { return $null }
        & $glide ([datetime]::FromFileTimeUtc($fileTime))
    }

    Invoke-RmaRestMethod -Method PATCH -Headers $context.Headers -Uri "$domainUri/syncstate/updating" | Out-Null

    $read = 0; $inserted = 0; $updated = 0; $failed = 0; $batches = 0
    $domainFields = $null
    try {
        $domain = Get-ADDomain @server
        $forest = Get-ADForest @server
        $pam = Get-ADOptionalFeature -Filter "Name -like 'Privileged*'" @server
        $domainFields = [ordered]@{
            domain_mode = "$($domain.DomainMode)"
            name        = $domain.Name
            forest_mode = "$($forest.ForestMode)"
            forest_name = $forest.Name
            pam_enabled = [bool] @($pam | Where-Object { @($_.PSObject.Properties['EnabledScopes']?.Value).Count -gt 0 }).Count
        }

        # Only the extension attributes this forest's schema has. See the help.
        $schema = (Get-ADRootDSE @server).schemaNamingContext
        $extensions = @(Get-ADObject -SearchBase $schema -LDAPFilter '(lDAPDisplayName=extensionAttribute*)' `
                -Properties lDAPDisplayName @server |
            ForEach-Object { $_.lDAPDisplayName } |
            Where-Object { $_ -match '^extensionAttribute([1-9]|1[0-5])$' } |
            Sort-Object { [int] ($_ -replace '\D') })
        Write-RmaLog -Level Information -Message 'Extension attributes in the schema' -Data @{ count = $extensions.Count }

        # Read everything first, as compact records, so the enumeration is not held open
        # while ServiceNow is written to. See the help.
        $records = [System.Collections.Generic.List[object]]::new()
        Get-ADUser -Filter * -Properties ($properties + $extensions) @server | ForEach-Object {
            $record = [ordered]@{
                accountexpirationdate = & $glide $_.AccountExpirationDate
                accountlockouttime    = & $glide $_.AccountLockoutTime
                cannotchangepassword  = $_.CannotChangePassword
                city                  = $_.City
                company               = $_.Company
                country               = $_.Country
                department            = $_.Department
                description           = $_.Description
                displayname           = $_.DisplayName
                distinguishedname     = $_.DistinguishedName
                domain                = $DomainId
                emailaddress          = $_.mail
                employeeid            = $_.EmployeeID
                employeenumber        = $_.EmployeeNumber
                employeetype          = $_.EmployeeType
                enabled               = $_.Enabled
                givenname             = $_.GivenName
                lastlogon             = & $fromFileTime $_.lastLogon
                lockedout             = $_.LockedOut
                mobilephone           = $_.MobilePhone
                name                  = $_.Name
                objectclass           = $_.ObjectClass
                objectguid            = "$($_.ObjectGUID)"
                office                = $_.Office
                officephone           = $_.OfficePhone
                passwordexpired       = $_.PasswordExpired
                passwordneverexpires  = $_.PasswordNeverExpires
                postalcode            = $_.PostalCode
                preferredlanguage     = $_.PreferredLanguage
                samaccountname        = $_.SamAccountName
                streetaddress         = $_.StreetAddress
                surname               = $_.Surname
                title                 = $_.Title
                userprincipalname     = $_.UserPrincipalName
            }
            foreach ($name in $extensions) { $record[$name.ToLowerInvariant()] = $_.$name }
            $records.Add($record)
        }
        $read = $records.Count
        Write-RmaLog -Level Information -Message 'AD users read' -Data @{ users = $read; queueSysId = $job.sys_id }

        for ($offset = 0; $offset -lt $read; $offset += $ImportBatchSize) {
            $batch = $records.GetRange($offset, [math]::Min($ImportBatchSize, $read - $offset))
            $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $batch.ToArray() -Depth 3 -Compress))

            # PUT is safe to retry: the endpoint upserts on objectguid.
            $answer = Invoke-RmaRestMethod -Method PUT -Headers $context.Headers -Body $body `
                -Uri "$domainUri/aduser/insertMultiple"
            $batches++

            $result = if ($null -ne $answer) { $answer.PSObject.Properties['result']?.Value }
            $counted = if ($null -ne $result) { $result.PSObject.Properties['inserted']?.Value }
            if ($null -eq $counted) {
                throw "/aduser/insertMultiple answered without result.inserted for the batch at user $offset. " +
                'The endpoint has changed; check it against #106.'
            }
            $inserted += [int] $counted
            $updated += [int] $result.PSObject.Properties['updated']?.Value

            # A user the endpoint does not report as written counts as failed, whether it
            # is listed as failed or missing from the answer.
            $entries = @($result.PSObject.Properties['results']?.Value | Where-Object { $null -ne $_ })
            $notWritten = @($entries | Where-Object { $_.PSObject.Properties['status']?.Value -notin 'inserted', 'updated' })
            $batchFailed = $batch.Count - ($entries.Count - $notWritten.Count)
            if ($batchFailed -gt 0) {
                $failed += $batchFailed
                foreach ($entry in $notWritten) {
                    $index = $entry.PSObject.Properties['index']?.Value
                    $user = if ($index -is [ValueType] -and $index -ge 0 -and $index -lt $batch.Count) { $batch[[int] $index] } else { @{} }
                    Write-RmaLog -Level Warning -Message 'ServiceNow did not write an AD user' -Data @{
                        samAccountName = $user['samaccountname']; objectGuid = $user['objectguid']
                        status         = $entry.PSObject.Properties['status']?.Value
                        error          = $entry.PSObject.Properties['error']?.Value ?? $entry.PSObject.Properties['message']?.Value
                    }
                }
                if ($notWritten.Count -lt $batchFailed) {
                    Write-RmaLog -Level Warning -Message 'ServiceNow answered for fewer AD users than were sent' -Data @{
                        sent = $batch.Count; answered = $entries.Count; firstUser = $offset
                    }
                }
            }

            if ($batches % 25 -eq 0) {
                Write-RmaLog -Level Information -Message 'AD user import in progress' -Data @{
                    sent = $offset + $batch.Count; users = $read; failed = $failed
                }
            }
        }
    } finally {
        # Back to 'ready' even after a failure, so the domain is not shown as updating for
        # ever. A failure here is logged, not thrown, so it cannot hide the import's own.
        try {
            $ready = [ordered]@{ sync_state = 'ready' }
            if ($null -ne $domainFields) {
                foreach ($key in $domainFields.Keys) { $ready[$key] = $domainFields[$key] }
            }
            Invoke-RmaRestMethod -Method PATCH -Headers $context.Headers -Uri $domainUri `
                -Body ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $ready -Compress))) | Out-Null
        } catch {
            Write-RmaLog -Level Error -Message 'Could not set the domain sync state back to ready' -Data @{ error = $_.Exception.Message }
        }
    }

    $fields = @{
        users = $read; inserted = $inserted; updated = $updated; failed = $failed; batches = $batches
        queueSysId = $job.sys_id
    }
    if ($failed -gt 0) {
        Write-RmaLog -Level Error -Message 'AD user import incomplete; cleanup skipped' -Data $fields
        throw "$failed of $read AD user(s) were not written to ServiceNow. Cleanup was skipped, so no record was removed."
    }
    if ($read -eq 0) {
        throw 'No AD users were read, so nothing was imported and cleanup was skipped. Check the service account''s read access.'
    }

    Invoke-RmaRestMethod -Method PATCH -Headers $context.Headers -Uri "$domainUri/aduser/cleanup" | Out-Null
    Write-RmaLog -Level Information -Message 'AD users imported' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
