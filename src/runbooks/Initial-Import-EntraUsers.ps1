#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.6.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Imports every Entra ID user into ServiceNow from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks, and on
    Initial-Import-ADUsers, the same import for Active Directory. The app registration
    needs to read every user (User.Read.All, which User.ReadWrite.All includes).

    One job is one full import, rebuilt as docs/DECISIONS.md D12 agreed:
      - The domain's sync state is set to 'updating', and to 'ready' through
        /syncstate/ready when the import ends, also when it fails. 1.0 never set it back.
      - Users are read from Graph a page of ImportBatchSize at a time, and each page is
        written to /entraiduser/insertMultiple as one batch, which upserts on objectguid,
        the user's Graph object id. 1.0 wrote one PUT per user, in four threads, and wrote
        them to /aduser, which is now Active Directory's (D14).
      - The Graph connection is renewed between pages with Update-RmaConnection: a tenant
        of 500,000 users takes longer to read than a token lives.
      - A page Graph or the endpoint refuses fails the job at once, after the retries of
        the Graph SDK and of Invoke-RmaRestMethod. A user the endpoint reports as failed is
        logged, the import continues, and the job fails at the end.
      - No cleanup yet, so a user deleted from Entra ID stays in ServiceNow. D12 has the
        import remove the users it did not write, through /entraiduser/cleanup and only
        when no user failed, but that endpoint does not exist (#192, probed on #106). #193
        adds the call once it does. 1.0 called /user/cleanup, which was Active Directory's.
      - The import holds the job for as long as it runs. Invoke-RmaQueueLoop's heartbeat
        keeps the claim, so the watchdog does not requeue it.

    The fields are 1.0's, with these corrections, and Import-EntraUsers sends the same ones,
    so a user reads the same whichever import wrote it last. The MFA phone (mfasms) is no
    longer sent: Import-EntraMFA owns it (D12), reading it cost one Graph call per user,
    and a field left out keeps its value. employeehiredate is sent as ServiceNow Date/Time
    (UTC, 'yyyy-MM-dd HH:mm:ss'): 1.0 sent whatever the SDK made of it. description is
    dropped, since a Graph user has no such property and 1.0 always sent it empty. The
    office location goes to officelocation, as 1.0's Import-EntraUsers sent it, not to
    location, a separate field 1.0's initial import used. The first business phone goes to
    office_phone, the field's own name: the endpoint also takes 1.0's officephone, but does
    not clear the field when given it empty (#106).

    Every value that is empty in Entra ID is sent as an empty string, never as null. The
    endpoint clears a field given an empty string, but leaves a field given null as it was
    (#186), so a value cleared in Entra ID, such as a job title, would otherwise stay in
    ServiceNow for ever.
.PARAMETER ImportBatchSize
    Users per Graph page and per /entraiduser/insertMultiple request. Graph returns at most
    999 users a page. The endpoint's own limit is not yet known (#106); a request must
    finish within Invoke-RmaRestMethod's 60-second timeout.
.NOTES
    Payload: none besides action. The job imports the whole tenant.
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
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ApplicationId,
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Initial-Import-EntraUsers' -Body {
    # The payload carries nothing but the action, which the loop has already checked.
    param($job)

    $domainUri = "$($context.BaseUri)/api/x_autps_active_dir/domain/$DomainId"
    $select = @(
        'accountEnabled', 'businessPhones', 'city', 'companyName', 'country', 'department', 'displayName',
        'employeeHireDate', 'employeeId', 'employeeType', 'givenName', 'id', 'jobTitle', 'mail', 'mailNickname',
        'mobilePhone', 'officeLocation', 'postalCode', 'preferredLanguage', 'streetAddress', 'surname',
        'userPrincipalName', 'userType'
    ) -join ','

    # ServiceNow Date/Time: UTC, 'yyyy-MM-dd HH:mm:ss'. ISO 8601 would be stored as midnight.
    $glide = {
        param($date)
        if ($null -eq $date -or "$date" -eq '') { return $null }
        ([datetime] $date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    }

    Invoke-RmaRestMethod -Method PATCH -Headers $context.Headers -Uri "$domainUri/syncstate/updating" | Out-Null

    $read = 0; $inserted = 0; $updated = 0; $failed = 0; $batches = 0
    try {
        # Paged by hand rather than with Get-MgUser -All, so the connection can be renewed
        # between pages. See the help.
        $uri = "v1.0/users?`$select=$select&`$top=$ImportBatchSize"
        while ($uri) {
            Update-RmaConnection
            # -ErrorAction Stop: the runbook's preference does not reach the Graph cmdlets.
            $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable -ErrorAction Stop
            $uri = $page['@odata.nextLink']

            $batch = @(foreach ($user in @($page['value'])) {
                    $upn = "$($user['userPrincipalName'])"
                    # Under StrictMode an index past the end throws, and most users have no
                    # business phone.
                    $phones = @($user['businessPhones'] | Where-Object { $_ })
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
                        office_phone      = $phones.Count -gt 0 ? $phones[0] : $null
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

            if ($batches % 25 -eq 0) {
                Write-RmaLog -Level Information -Message 'Entra ID user import in progress' -Data @{ sent = $read; failed = $failed }
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
        queueSysId = $job.sys_id
    }
    if ($failed -gt 0) {
        Write-RmaLog -Level Error -Message 'Entra ID user import incomplete' -Data $fields
        throw "$failed of $read Entra ID user(s) were not written to ServiceNow."
    }
    if ($read -eq 0) {
        throw 'No Entra ID users were read, so nothing was imported. Check the app registration''s User.Read.All permission.'
    }

    # No cleanup yet: /entraiduser/cleanup does not exist (#192). See the help.
    Write-RmaLog -Level Information -Message 'Entra ID users imported' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
