#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                        RequiredVersion = '2.5.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication';      RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';               RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Identity.DirectoryManagement'; RequiredVersion = '2.39.0' }

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
      - A refused create fails the job with Graph's reason and nothing else. Microsoft.Graph
        puts the whole request body, initial password included, into the TargetObject of
        the error it raises, so that error is not rethrown as is.
.NOTES
    Every other runbook follows this shape. Only the scriptblock body differs.

    Payload:
      username      required; the local part of the user principal name, in the
                    character set Entra accepts there. The domain is the tenant's default.
      password      required; the initial password, changed at first sign-in
      givenname, surname, city, company, department, title, postalcode, streetaddress,
      mobilephone, employeeid, physicaldelofficename, businessphone
                    optional; an empty or absent field is not sent to Graph
      usersysid     the ServiceNow user record, passed back as it came in the write-back
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ApplicationId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The Automation job pane prints ANSI escape codes literally, which buries the text of
# every error record under colour sequences.
$PSStyle.OutputRendering = 'PlainText'

$context = Test-RmaPrerequisite -Instance $Instance -VaultName $VaultName `
    -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName

Connect-RmaGraph -Context $context -TenantId $TenantId -ApplicationId $ApplicationId

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Create-EntraUser' -Body {
    param($job, $p)

    # Every field is read through PSObject. Under StrictMode, $p.city on a payload without
    # 'city' throws a property-not-found that names no ServiceNow field (#121); read this
    # way, a missing field is empty, so an optional one is skipped and a required one fails
    # with the field's name. The payload is a parameter of the reader, not read from the
    # enclosing scope, or the analyzer reports $p as unused.
    $field = {
        param($Payload, [string] $Name)
        "$($Payload.PSObject.Properties[$Name]?.Value)".Trim()
    }

    # Everything the payload must get right is checked before Graph is asked anything.

    # Validated, not just trimmed. This value comes straight from the ServiceNow payload
    # and goes into the UPN. The set is the local part Entra accepts, apostrophe included:
    # O'Brien is a real name and rejecting it would be a worse bug than the one below.
    $userName = & $field $p 'username'
    if ($userName -notmatch '^[A-Za-z0-9._!#^~''-]{1,64}$') {
        throw "Payload field 'username' is empty or contains characters Entra does not " +
        "accept in a user principal name. Correct the ServiceNow record."
    }

    # The password goes straight into a SecureString, character by character, and the
    # plain copy is dropped. It is not trimmed: spaces are characters of the password.
    # Nothing below may log it or put it into a message.
    $plain = "$($p.PSObject.Properties['password']?.Value)"
    if (-not $plain -or $plain -match '[\x00-\x1F]') {
        $plain = $null
        throw "Payload field 'password' is empty or contains control characters. Correct the ServiceNow record."
    }
    $password = [securestring]::new()
    foreach ($character in $plain.ToCharArray()) { $password.AppendChar($character) }
    $password.MakeReadOnly()
    $plain = $null

    # Passed back to ServiceNow as it came, as before: null when the payload has none.
    $userSysId = $p.PSObject.Properties['usersysid']?.Value

    # -ErrorAction Stop: the runbook's preference does not reach the Graph cmdlets, and a
    # failed lookup would otherwise read as "no default domain" (#157). Select-Object, not
    # (...).Id: under StrictMode .Id on an empty result throws a property-not-found before
    # the check below can name the cause (#156).
    $domain = Get-MgDomain -All -ErrorAction Stop | Where-Object { $_.IsDefault } |
    Select-Object -First 1 -ExpandProperty Id
    if (-not $domain) { throw 'No default verified domain found in the tenant.' }
    $upn = "$userName@$domain"

    # An OData string literal escapes a single quote by doubling it. Without this, the one
    # legitimate character that can appear in a name changes what the filter matches, and
    # the idempotency check below silently stops being a check.
    $upnFilter = $upn -replace "'", "''"

    # Idempotency. A duplicate execution, or a retry after a partial failure, must not
    # produce a second user or a spurious failure. A filter that matches nothing returns
    # an empty result; it does not throw for not-found. So any error here, throttling,
    # access denied or an expired token, fails the job with Graph's own reason rather than
    # reading as "no such user" (#144). The request carries no password, so the error is
    # passed on as Graph raised it.
    if (Get-MgUser -Filter "userPrincipalName eq '$upnFilter'" -ErrorAction Stop) {
        Write-RmaLog -Level Warning -Message 'User already exists; treating as success' -Data @{ upn = $upn }
        return
    }

    $given   = & $field $p 'givenname'
    $surname = & $field $p 'surname'
    $display = if ($given -and $surname) { "$given $surname" } elseif ($given) { $given } else { $userName }

    $newUser = @{
        AccountEnabled    = $true
        UserPrincipalName = $upn
        MailNickname      = $userName
        DisplayName       = $display
    }

    # Optional attributes, added only when supplied. Sending an empty string where Graph
    # expects null is rejected, which is why each is guarded rather than assigned blindly.
    $optional = @{
        GivenName      = $given
        Surname        = $surname
        City           = & $field $p 'city'
        CompanyName    = & $field $p 'company'
        Department     = & $field $p 'department'
        JobTitle       = & $field $p 'title'
        PostalCode     = & $field $p 'postalcode'
        StreetAddress  = & $field $p 'streetaddress'
        MobilePhone    = & $field $p 'mobilephone'
        EmployeeId     = & $field $p 'employeeid'
        OfficeLocation = & $field $p 'physicaldelofficename'
    }
    foreach ($key in $optional.Keys) {
        if (-not [string]::IsNullOrWhiteSpace($optional[$key])) { $newUser[$key] = $optional[$key] }
    }

    # BusinessPhones is a string array. The singular form is not a valid parameter and
    # caused every job in the previous version to fail at binding.
    $businessPhone = & $field $p 'businessphone'
    if ($businessPhone) { $newUser['BusinessPhones'] = @($businessPhone) }

    try {
        # The password is text only inside this hashtable, for the length of the call,
        # because Graph's passwordProfile takes plain text in the request body. -ErrorAction
        # Stop because the runbook's preference does not reach the Graph cmdlets, which run
        # in their own module's scope: without it a refused create is a non-terminating
        # error, and the job fails on $created.Id with a property-not-found instead (#157).
        $created = New-MgUser @newUser -ErrorAction Stop -PasswordProfile @{
            Password                      = [pscredential]::new('rma', $password).GetNetworkCredential().Password
            ForceChangePasswordNextSignIn = $true
        }
    } catch {
        # The SDK's error record holds the request body, password included, as its
        # TargetObject. Only Graph's message, which does not repeat the password, leaves
        # this block.
        throw [System.Exception]::new($_.Exception.Message)
    }

    # Named fields only. Never the payload object: it carries the password.
    Write-RmaLog -Level Information -Message 'Entra user created' -Data @{
        upn = $upn; id = $created.Id; displayName = $display; queueSysId = $job.sys_id
    }

    $writeBack = @{
        sysid             = $userSysId
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
