#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                     RequiredVersion = '2.6.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication';   RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';            RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Identity.SignIns'; RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Sets an Entra ID user's mobile phone authentication method from the ServiceNow command
    queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the Microsoft Graph application permissions
    UserAuthenticationMethod.ReadWrite.All and User.Read.All.

    As in 1.0, only the mobile phone type is set. A user without a mobile method gets one.
    A user whose mobile method already holds the number completes the job with a log
    record and nothing is written; Graph stores numbers in its own spelling
    (+1 5555550100), so the two are compared on the plus sign, digits and extension. A
    user whose mobile method holds another number has it changed in place, which 1.0
    could not do: it failed every job for a user who already had a mobile method. An
    empty number fails the job, as in 1.0; it never removes the method. A user who does
    not exist fails the job: there is nothing to set (docs/DECISIONS.md D15 covers
    deletes only).

    A user created moments ago can be found before Graph's authentication-methods
    endpoint knows it; that job fails with a message saying to queue it again.

    The phone number is personal data. It goes to Graph and nowhere else: not into a log
    record, and not into the reason written back to ServiceNow.
.NOTES
    Payload: useridforauth, the user as its user principal name or its object id;
    mobile, the number in a form Graph accepts, such as +1 5555550100.
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Set-EntraUserAuthenticationPhoneMethod' -Body {
    param($job, $p)

    # Read through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $identity = "$($p.PSObject.Properties['useridforauth']?.Value)".Trim()
    if (-not $identity -or $identity -match '[\x00-\x1F]') {
        throw "Payload field 'useridforauth' is empty or contains control characters. Correct the ServiceNow record."
    }
    # The value goes into the request path, and Microsoft.Graph does not escape '/' in
    # -UserId, so it is held to the two forms -UserId means: an object id, or a user
    # principal name in the character set Entra accepts.
    $isObjectId = $identity -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    if (-not $isObjectId -and $identity -notmatch '^[A-Za-z0-9._!#^~''-]{1,113}@[A-Za-z0-9.-]{1,255}$') {
        throw "Payload field 'useridforauth' is neither an object id nor a user principal name. Correct the ServiceNow record."
    }

    # Personal data: no message below quotes it. Its format is left to Graph, which
    # accepts many spellings and refuses the rest with a reason of its own.
    $number = "$($p.PSObject.Properties['mobile']?.Value)".Trim()
    if (-not $number -or $number -match '[\x00-\x1F]') {
        throw "Payload field 'mobile' is empty or contains control characters. Correct the ServiceNow record."
    }

    try {
        $user = Get-MgUser -UserId $identity -Property 'id', 'userPrincipalName' -ErrorAction Stop
    } catch {
        # Matched on Graph's error code, which leads the error id; the exception itself is a
        # plain System.Exception. Every other failure (throttling, access denied) is
        # rethrown as is. Not found is retried: a job queued straight after Create-EntraUser
        # was run before Get-MgUser knew the new user (#146). A user that never arrives
        # fails the job with this reason once the retries are used.
        if ($_.FullyQualifiedErrorId -notlike 'Request_ResourceNotFound,*') { throw }
        Request-RmaJobRetry -Reason "No Entra ID user '$identity'. Correct the ServiceNow record."
    }

    # The user acted on must be the user asked for, whatever the request path made of it.
    if ($user.Id -ne $identity -and $user.UserPrincipalName -ne $identity) {
        throw "Graph returned a different user than '$identity' asked for. Nothing was changed."
    }

    $fields = @{ userPrincipalName = $user.UserPrincipalName; id = $user.Id; phoneType = 'mobile'; queueSysId = $job.sys_id }

    # The authentication-methods endpoint has its own error code for a missing user, and
    # lags behind the directory: for a user created moments ago, Get-MgUser above finds it
    # while this endpoint still says resourceNotFound, on a read or, after a read that
    # returned nothing, on the write.
    $notYet = "Entra ID user '$($user.UserPrincipalName)' exists, but Graph's authentication methods do not know it yet. A user created moments ago takes a while to reach them; queue the job again."

    try {
        $mobile = Get-MgUserAuthenticationPhoneMethod -UserId $user.Id -ErrorAction Stop |
        Where-Object PhoneType -EQ 'mobile' | Select-Object -First 1
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'resourceNotFound,*') { throw }
        Request-RmaJobRetry -Reason $notYet
    }

    # Graph stores its own spelling (+1 5555550100 x12), so both sides are reduced to the
    # plus sign, digits and extension before they are compared.
    $normalise = { param([string] $Value) $Value.ToLowerInvariant() -replace '[^+0-9x]', '' }
    if ($mobile -and (& $normalise $mobile.PhoneNumber) -eq (& $normalise $number)) {
        Write-RmaLog -Level Information -Message 'Entra user already has this mobile phone authentication method; nothing to do' -Data $fields
        return
    }

    $body = @{ phoneType = 'mobile'; phoneNumber = $number }
    try {
        if ($mobile) {
            # By the method's id, so the mobile method changed is the one read above.
            $null = Update-MgUserAuthenticationPhoneMethod -UserId $user.Id -PhoneAuthenticationMethodId $mobile.Id -BodyParameter $body -ErrorAction Stop
            $done = 'Mobile phone authentication method changed'
        } else {
            $null = New-MgUserAuthenticationPhoneMethod -UserId $user.Id -BodyParameter $body -ErrorAction Stop
            $done = 'Mobile phone authentication method added'
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'resourceNotFound,*') { Request-RmaJobRetry -Reason $notYet }
        # Graph's refusals (invalidPhoneNumber) do not quote the number. Should one ever do,
        # it is cut out here, so it reaches neither the job log nor ServiceNow; any other
        # error is rethrown as is.
        if (-not $_.Exception.Message.Contains($number)) { throw }
        throw $_.Exception.Message.Replace($number, '<mobile>')
    }
    Write-RmaLog -Level Information -Message $done -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
