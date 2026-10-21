#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.6.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Imports the Entra ID users created in the last day into ServiceNow from the ServiceNow
    command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks, and on
    Initial-Import-ADUsers, which writes to ServiceNow the same way. The app registration
    needs to read every user (User.Read.All, which User.ReadWrite.All includes).

    The ServiceNow application sends this command every hour. One job is one incremental
    import, as 1.0 did it: the users Entra ID created in the last CreatedWithinHours hours,
    24 by default, so a run that is missed or fails is caught up by the next. A change to
    an older user is not imported; Initial-Import-EntraUsers imports every user.
      - The domain's sync state is set to 'updating', and to 'ready' through
        /syncstate/ready when the import ends, also when it fails. 1.0 left it at
        'updating' after a failure.
      - Users are read from Graph a page of ImportBatchSize at a time, and each page is
        written to /entraiduser/insertMultiple as one batch, which upserts on objectguid,
        the user's Graph object id. 1.0 wrote one PUT per user to /aduser, which is now
        Active Directory's (docs/DECISIONS.md D14).
      - A page Graph or the endpoint refuses fails the job at once, after the retries of
        the Graph SDK and of Invoke-RmaRestMethod. A user the endpoint reports as failed is
        logged, the import continues, and the job fails at the end.
      - No cleanup. 1.0 called /aduser/cleanup after writing only the new users, and a
        cleanup removes every record not imported since the previous run, so it would
        delete every older user. Cleanup belongs to Initial-Import-EntraUsers.
      - No user created in the window is a normal outcome: the job completes.

    The fields are those Initial-Import-EntraUsers sends, so a user reads the same whichever
    import wrote it last. Against 1.0's they differ in these ways. The MFA phone (mfasms) is
    not sent: Import-EntraMFA owns it (D12), reading it cost one Graph call per user, and a
    field left out keeps its value. description is not sent, since a Graph user has no such
    property and 1.0 always sent it empty. mobile is the user's mobilePhone: 1.0 read a
    Mobile property Graph does not have, so it was always empty. employeetype,
    preferredlanguage and office_phone, the first business phone, are added, as 1.0's
    Initial-Import-EntraUsers sent them. employeehiredate is ServiceNow Date/Time (UTC,
    'yyyy-MM-dd HH:mm:ss').

    Every value that is empty in Entra ID is sent as an empty string, never as null. The
    endpoint clears a field given an empty string, but leaves a field given null as it was
    (#106), so a value cleared in Entra ID would otherwise stay in ServiceNow for ever.
.PARAMETER CreatedWithinHours
    How far back a user's creation counts as new. The default overlaps the hourly cadence,
    so the users of a missed run are imported by a later one; writing a user twice updates
    the same record.
.PARAMETER ImportBatchSize
    Users per Graph page and per /entraiduser/insertMultiple request. Graph returns at most
    999 users a page. The endpoint's own limit is not yet known (#106); a request must
    finish within Invoke-RmaRestMethod's 60-second timeout.
.NOTES
    Payload: none besides action. The job imports the tenant's new users.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CreatedWithinHours',
    Justification = 'Used inside the Invoke-RmaQueueLoop body. PSScriptAnalyzer does not resolve variable use across a scriptblock closure.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ImportBatchSize',
    Justification = 'Used inside the Invoke-RmaQueueLoop body. PSScriptAnalyzer does not resolve variable use across a scriptblock closure.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ApplicationId,
    [ValidateRange(1, 8760)]                                    [int]    $CreatedWithinHours = 24,
    [ValidateRange(1, 999)]                                     [int]    $ImportBatchSize = 200
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The Automation job pane prints ANSI escape codes literally, which buries the text of
# every error record under colour sequences.
$PSStyle.OutputRendering = 'PlainText'

$context = Test-RmaPrerequisite -Instance $Instance -VaultName $VaultName `
    -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName

Connect-RmaGraph -Context $context -TenantId $TenantId -ApplicationId $ApplicationId

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Import-EntraUsers' -Body {
    # The payload carries nothing but the action, which the loop has already checked.
    param($job)

    $domainUri = "$($context.BaseUri)/api/x_autps_active_dir/domain/$DomainId"
    $select = @(
        'accountEnabled', 'businessPhones', 'city', 'companyName', 'country', 'department', 'displayName',
        'employeeHireDate', 'employeeId', 'employeeType', 'givenName', 'id', 'jobTitle', 'mail', 'mailNickname',
        'mobilePhone', 'officeLocation', 'postalCode', 'preferredLanguage', 'streetAddress', 'surname',
        'userPrincipalName', 'userType'
    ) -join ','
    $since = [datetime]::UtcNow.AddHours(-$CreatedWithinHours).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)

    # ServiceNow Date/Time: UTC, 'yyyy-MM-dd HH:mm:ss'. ISO 8601 would be stored as midnight.
    $glide = {
        param($date)
        if ($null -eq $date -or "$date" -eq '') { return $null }
        ([datetime] $date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    }

    Invoke-RmaRestMethod -Method PATCH -Headers $context.Headers -Uri "$domainUri/syncstate/updating" | Out-Null

    $read = 0; $inserted = 0; $updated = 0; $failed = 0; $batches = 0
    try {
        $filter = [uri]::EscapeDataString("createdDateTime ge $since")
        $uri = "v1.0/users?`$filter=$filter&`$select=$select&`$top=$ImportBatchSize"
        while ($uri) {
            # -ErrorAction Stop: the runbook's preference does not reach the Graph cmdlets.
            $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable -ErrorAction Stop
            $uri = $page['@odata.nextLink']

            $batch = @(foreach ($user in @($page['value'])) {
                    $upn = "$($user['userPrincipalName'])"
                    $record = [ordered]@{
                        city              = $user['city']
                        company           = $user['companyName']
                        country           = $user['country']
                        department        = $user['department']
                        domain            = $DomainId
                        email             = $user['mail']
                        employeehiredate  = & $glide $user['employeeHireDate']
                        employeeid        = $user['employeeId']
                        employeetype      = $user['employeeType']
                        enabled           = $user['accountEnabled']
                        givenname         = $user['givenName']
                        mailnickname      = $user['mailNickname']
                        mobile            = $user['mobilePhone']
                        name              = $user['displayName']
                        objectguid        = "$($user['id'])"
                        officelocation    = $user['officeLocation']
                        # office_phone, the field's own name. The endpoint also takes
                        # officephone, but does not clear the field when given it empty.
                        # Select-Object, not [0]: under StrictMode [0] of an empty array throws.
                        office_phone      = @($user['businessPhones']) | Select-Object -First 1
                        postalcode        = $user['postalCode']
                        preferredlanguage = $user['preferredLanguage']
                        streetaddress     = $user['streetAddress']
                        surname           = $user['surname']
                        title             = $user['jobTitle']
                        userprincipalname = $upn
                        username          = $upn.Split('@')[0]
                        usertype          = $user['userType']
                    }
                    # An empty string clears the field in ServiceNow; null would leave it as it was.
                    foreach ($key in @($record.Keys)) { if ($null -eq $record[$key]) { $record[$key] = '' } }
                    $record
                })
            if ($batch.Count -eq 0) { continue }
            $offset = $read
            $read += $batch.Count

            $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $batch -Depth 3 -Compress))
            # PUT is safe to retry: the endpoint upserts on objectguid.
            $answer = Invoke-RmaRestMethod -Method PUT -Headers $context.Headers -Body $body `
                -Uri "$domainUri/entraiduser/insertMultiple"
            $batches++

            $result = if ($null -ne $answer) { $answer.PSObject.Properties['result']?.Value }
            $counted = if ($null -ne $result) { $result.PSObject.Properties['inserted']?.Value }
            if ($null -eq $counted) {
                throw "/entraiduser/insertMultiple answered without result.inserted for the batch at user $offset. " +
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
                    Write-RmaLog -Level Warning -Message 'ServiceNow did not write an Entra ID user' -Data @{
                        userPrincipalName = $user['userprincipalname']; objectId = $user['objectguid']
                        status            = $entry.PSObject.Properties['status']?.Value
                        error             = $entry.PSObject.Properties['error']?.Value ?? $entry.PSObject.Properties['message']?.Value
                    }
                }
                if ($notWritten.Count -lt $batchFailed) {
                    Write-RmaLog -Level Warning -Message 'ServiceNow answered for fewer Entra ID users than were sent' -Data @{
                        sent = $batch.Count; answered = $entries.Count; firstUser = $offset
                    }
                }
            }
        }
    } finally {
        # Back to 'ready' even after a failure, so the domain is not shown as updating for
        # ever. A failure here is logged, not thrown, so it cannot hide the import's own.
        try {
            Invoke-RmaRestMethod -Method PATCH -Headers $context.Headers -Uri "$domainUri/syncstate/ready" | Out-Null
        } catch {
            Write-RmaLog -Level Error -Message 'Could not set the domain sync state back to ready' -Data @{ error = $_.Exception.Message }
        }
    }

    $fields = @{
        users = $read; inserted = $inserted; updated = $updated; failed = $failed; batches = $batches
        createdSince = $since; queueSysId = $job.sys_id
    }
    if ($failed -gt 0) {
        Write-RmaLog -Level Error -Message 'Entra ID user import incomplete' -Data $fields
        throw "$failed of $read new Entra ID user(s) were not written to ServiceNow."
    }
    Write-RmaLog -Level Information -Message 'New Entra ID users imported' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
