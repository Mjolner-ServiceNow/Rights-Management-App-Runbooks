#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                     RequiredVersion = '2.6.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication';   RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';            RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Identity.SignIns'; RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Imports Entra ID users' SMS phone numbers into ServiceNow from the ServiceNow command
    queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks, with the batching of
    Initial-Import-ADUsers. The app registration needs the Microsoft Graph application
    permissions UserAuthenticationMethod.Read.All and User.Read.All;
    UserAuthenticationMethod.ReadWrite.All, which Set-EntraUserAuthenticationPhoneMethod
    needs, covers the first.

    The runbook owns one field of the ServiceNow Entra ID user record, mfasms
    (docs/DECISIONS.md D12), and writes nothing else:
      - mfasms is the number of the user's mobile phone authentication method, the one
        Entra sends SMS codes to. A user without one gets an empty string, which clears
        the field. 1.0 sent every phone method's number, so a user with an office or
        alternate mobile phone as well got all of them in one field.
      - Each record is the user's object id, as objectguid, and mfasms, written through
        PUT /domain/{DomainId}/entraiduser/insertMultiple. The endpoint upserts on
        objectguid and keeps every field a record leaves out (#106), so the users' other
        fields, which the user imports own, stay as they are. 1.0 sent the whole user
        again, to the endpoint that now means Active Directory (D14).
      - A user ServiceNow has no record of yet gets one with only these two fields. The
        next user import fills in the rest. The job logs how many there were.
      - No cleanup is called. Cleanup removes the users not imported since the previous
        run, and which users exist is the user imports' business, not this runbook's.
        1.0 called it after every single user.
      - The domain's sync state is left alone, for the same reason. 1.0 set it to
        'updating' and back to 'ready' for every single user.

    Without Id in the payload, the job imports every user in the tenant. Users are read
    from Graph a page of ImportBatchSize at a time, their phone methods one user at a
    time, and each page is written in one request before the next is read, so memory
    stays flat at any size. The Graph connection is renewed between pages, and
    Invoke-RmaQueueLoop's heartbeat holds the claim for as long as the import runs.
    A user who is gone by the time their phone methods are read, or too new for the
    authentication methods endpoint to know, is skipped with a warning; the next import
    picks them up. A user ServiceNow reports as not written is logged, the import goes on,
    and the job fails at the end.

    With Id, as in 1.0, the job imports that one user. A user Graph does not know yet, as
    straight after Create-EntraUser, is retried by the loop before the job fails.

    Graph throttles the authentication methods endpoint per tenant. The SDK waits out a
    429 itself, honouring Retry-After; one that outlasts its retries asks the loop to run
    the job again shortly (docs/DECISIONS.md D18). An import that is run again starts from
    the first page, which is safe, since each write is an upsert.

    The phone number is personal data. It goes to ServiceNow and nowhere else: not into a
    log record, and not into the reason written back to ServiceNow.
.PARAMETER ImportBatchSize
    Users per Graph page and per /entraiduser/insertMultiple request. Graph returns at
    most 999 users per page. The endpoint's own limit is not yet known (#106); a request
    must finish within Invoke-RmaRestMethod's 60-second timeout.
.NOTES
    Payload: Id, optional; one user, as their object id or user principal name. Left out,
    every user in the tenant is imported.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Import-EntraMFA' -Body {
    param($job, $p)

    $endpoint = "$($context.BaseUri)/api/x_autps_active_dir/domain/$DomainId/entraiduser/insertMultiple"

    # Read through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload. Absent or null means every
    # user; present but empty is a mistake, not a request for every user.
    $rawId = $p.PSObject.Properties['Id']?.Value
    $identity = $null
    if ($null -ne $rawId) {
        $identity = "$rawId".Trim()
        if (-not $identity -or $identity -match '[\x00-\x1F]') {
            throw "Payload field 'Id' is empty or contains control characters. Leave it out to import every user, or correct the ServiceNow record."
        }
        # The value goes into the request path, and Microsoft.Graph does not escape '/' in
        # -UserId, so it is held to the two forms -UserId means.
        $isObjectId = $identity -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
        if (-not $isObjectId -and $identity -notmatch '^[A-Za-z0-9._!#^~''-]{1,113}@[A-Za-z0-9.-]{1,255}$') {
            throw "Payload field 'Id' is neither an object id nor a user principal name. Correct the ServiceNow record."
        }
    }

    # Graph's own wait for a 429 is used up. Matched on the generated cmdlets' error id and
    # on Invoke-MgGraphRequest's response status, which is how each reports it.
    $throttled = {
        param($record)
        if ($record.FullyQualifiedErrorId -like 'TooManyRequests,*') { return $true }
        $response = $record.Exception.PSObject.Properties['Response']?.Value
        $null -ne $response -and "$($response.PSObject.Properties['StatusCode']?.Value)" -eq 'TooManyRequests'
    }
    $throttledReason = 'Microsoft Graph is throttling the tenant and its retries are used up. The import is run again from the start shortly; if it still fails, queue it again later.'

    # The number Entra sends SMS codes to, or an empty string, which clears the field.
    $readMobile = {
        param([string] $UserId)
        $mobile = Get-MgUserAuthenticationPhoneMethod -UserId $UserId -ErrorAction Stop |
        Where-Object PhoneType -EQ 'mobile' | Select-Object -First 1
        if ($mobile) { "$($mobile.PhoneNumber)" } else { '' }
    }

    $counts = [ordered]@{ users = 0; inserted = 0; updated = 0; skipped = 0; failed = 0; batches = 0 }

    # Writes one batch and adds ServiceNow's answer to $counts. A user the endpoint does not
    # report as written counts as failed, whether it is listed as failed or missing from
    # the answer. Users are logged by object id only: their records carry the number.
    $write = {
        param([System.Collections.Generic.List[object]] $Batch)
        $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Batch.ToArray() -Depth 3 -Compress))
        # PUT is safe to retry: the endpoint upserts on the object id.
        $answer = Invoke-RmaRestMethod -Method PUT -Headers $context.Headers -Body $body -Uri $endpoint
        $counts.batches++

        $result = if ($null -ne $answer) { $answer.PSObject.Properties['result']?.Value }
        $counted = if ($null -ne $result) { $result.PSObject.Properties['inserted']?.Value }
        if ($null -eq $counted) {
            throw '/entraiduser/insertMultiple answered without result.inserted. The endpoint has changed; check it against #106.'
        }
        $counts.inserted += [int] $counted
        $counts.updated += [int] $result.PSObject.Properties['updated']?.Value

        $entries = @($result.PSObject.Properties['results']?.Value | Where-Object { $null -ne $_ })
        $notWritten = @($entries | Where-Object { $_.PSObject.Properties['status']?.Value -notin 'inserted', 'updated' })
        $batchFailed = $Batch.Count - ($entries.Count - $notWritten.Count)
        if ($batchFailed -le 0) { return }
        $counts.failed += $batchFailed
        foreach ($entry in $notWritten) {
            $index = $entry.PSObject.Properties['index']?.Value
            $user = if ($index -is [ValueType] -and $index -ge 0 -and $index -lt $Batch.Count) { $Batch[[int] $index] } else { @{} }
            Write-RmaLog -Level Warning -Message 'ServiceNow did not write an Entra user''s SMS phone number' -Data @{
                objectGuid = $user['objectguid']
                status     = $entry.PSObject.Properties['status']?.Value
                error      = $entry.PSObject.Properties['error']?.Value ?? $entry.PSObject.Properties['message']?.Value
            }
        }
        if ($notWritten.Count -lt $batchFailed) {
            Write-RmaLog -Level Warning -Message 'ServiceNow answered for fewer Entra users than were sent' -Data @{
                sent = $Batch.Count; answered = $entries.Count
            }
        }
    }

    # The object id and the number. Nothing else, so the fields the user imports own keep
    # their values; the endpoint takes the domain from the path.
    $record = {
        param([string] $Id, [string] $Number)
        [ordered]@{ objectguid = $Id; mfasms = $Number }
    }

    $batch = [System.Collections.Generic.List[object]]::new()
    if ($identity) {
        try {
            $user = Get-MgUser -UserId $identity -Property 'id', 'userPrincipalName' -ErrorAction Stop
        } catch {
            if (& $throttled $_) { Request-RmaJobRetry -Reason $throttledReason }
            # A job queued straight after Create-EntraUser can run before Graph knows the
            # new user (#146); one that never arrives fails the job once the retries are used.
            if ($_.FullyQualifiedErrorId -notlike 'Request_ResourceNotFound,*') { throw }
            Request-RmaJobRetry -Reason "No Entra ID user '$identity'. Correct the ServiceNow record."
        }
        # The user written must be the user asked for, whatever the request path made of it.
        if ($user.Id -ne $identity -and $user.UserPrincipalName -ne $identity) {
            throw "Graph returned a different user than '$identity' asked for. Nothing was written."
        }

        try {
            $number = & $readMobile $user.Id
        } catch {
            if (& $throttled $_) { Request-RmaJobRetry -Reason $throttledReason }
            # The authentication methods endpoint lags behind the directory for a new user.
            if ($_.FullyQualifiedErrorId -notlike 'resourceNotFound,*') { throw }
            Request-RmaJobRetry -Reason "Entra ID user '$($user.UserPrincipalName)' exists, but Graph's authentication methods do not know it yet. A user created moments ago takes a while to reach them; queue the job again."
        }
        $counts.users = 1
        $batch.Add((& $record $user.Id $number))
        & $write $batch
    } else {
        $next = "v1.0/users?`$select=id,userPrincipalName&`$top=$ImportBatchSize"
        while ($next) {
            # A full import outlives the Graph token, and the loop renews it only between
            # jobs. It costs nothing while the token has time left.
            Update-RmaConnection

            try {
                $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
            } catch {
                if (& $throttled $_) { Request-RmaJobRetry -Reason $throttledReason }
                throw
            }
            $next = $page.PSObject.Properties['@odata.nextLink']?.Value

            $batch.Clear()
            foreach ($user in @($page.PSObject.Properties['value']?.Value)) {
                $counts.users++
                try {
                    $number = & $readMobile $user.id
                } catch {
                    if (& $throttled $_) { Request-RmaJobRetry -Reason $throttledReason }
                    if ($_.FullyQualifiedErrorId -notlike 'resourceNotFound,*') { throw }
                    # Deleted since the page was read, or created too recently for the
                    # authentication methods endpoint. Its record is left as it is.
                    $counts.skipped++
                    Write-RmaLog -Level Warning -Message 'Entra user not known to Graph''s authentication methods; skipped' -Data @{
                        id = $user.id; userPrincipalName = $user.userPrincipalName
                    }
                    continue
                }
                $batch.Add((& $record $user.id $number))
            }
            if ($batch.Count -eq 0) { continue }

            & $write $batch
            if ($counts.batches % 25 -eq 0) {
                Write-RmaLog -Level Information -Message 'Entra MFA import in progress' -Data @{
                    users = $counts.users; skipped = $counts.skipped; failed = $counts.failed
                }
            }
        }
    }

    $fields = @{ queueSysId = $job.sys_id }
    foreach ($key in $counts.Keys) { $fields[$key] = $counts[$key] }
    if ($counts.failed -gt 0) {
        Write-RmaLog -Level Error -Message 'Entra MFA import incomplete' -Data $fields
        throw "$($counts.failed) of $($counts.users) Entra user(s)' SMS phone numbers were not written to ServiceNow."
    }
    if ($counts.inserted -gt 0) {
        Write-RmaLog -Level Warning -Message 'ServiceNow had no record of some Entra users; created with the SMS phone number only, the next user import fills in the rest' -Data @{
            inserted = $counts.inserted
        }
    }
    Write-RmaLog -Level Information -Message 'Entra MFA imported' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
