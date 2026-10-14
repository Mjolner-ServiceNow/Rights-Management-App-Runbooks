#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                   RequiredVersion = '2.3.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';          RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Resets an Entra ID user's password from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the Microsoft Graph application permission
    User-PasswordProfile.ReadWrite.All, with User.Read.All (or User.ReadWrite.All) for the
    lookup. Resetting the password of a user who holds an administrator role needs a
    privileged directory role for the app as well; without one Graph refuses with
    Authorization_RequestDenied, and the job fails with that reason.

    The payload carries the new password. It goes from the payload into a SecureString and
    is turned back into text only inside the Update-MgUser call, because Graph's
    passwordProfile takes plain text in the request body. No variable in the body holds it
    as text, and it never reaches a log record or a message. Microsoft.Graph puts the whole
    request body, password included, into the TargetObject of the error it raises, so a
    refused reset is not rethrown as is: the job fails with a new error that carries only
    Graph's message, for example that the password does not meet the complexity
    requirements. Graph's message does not contain the password.

    As in 1.0, the reset always sets forceChangePasswordNextSignIn: true when the payload's
    mustChange is true, false otherwise. A repeated job resets the password again, to the
    same value; there is no "already done" state to detect.

    A user synchronised from on-premises Active Directory cannot have its password reset
    in Entra ID: the password is mastered on-premises, and Graph refuses the change. The
    job fails with that reason before the password is sent; Set-ADUserPassword is the
    runbook for such a user. A user who does not exist fails the job.
.NOTES
    Payload:
      user        the account, as its user principal name or its object id
      password    the new password
      mustChange  true to require a change at next sign-in; false or absent does not
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Set-EntraUserPassword' -Body {
    param($job, $p)

    # Read through PSObject: under StrictMode a missing field would otherwise throw a
    # property-not-found that says nothing about the payload.
    $identity = "$($p.PSObject.Properties['user']?.Value)".Trim()
    if (-not $identity -or $identity -match '[\x00-\x1F]') {
        throw "Payload field 'user' is empty or contains control characters. Correct the ServiceNow record."
    }
    # The value goes into the request path, and Microsoft.Graph does not escape '/' in
    # -UserId, so it is held to the two forms -UserId means: an object id, or a user
    # principal name in the character set Entra accepts ('#' included, for guests).
    # Anything else, a '/', '?' or '%' for example, could address something other than a user.
    $isObjectId = $identity -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    if (-not $isObjectId -and $identity -notmatch '^[A-Za-z0-9._!#^~''-]{1,113}@[A-Za-z0-9.-]{1,255}$') {
        throw "Payload field 'user' is neither an object id nor a user principal name. Correct the ServiceNow record."
    }

    # The password goes straight into a SecureString, character by character, and the
    # plain copy is dropped. Nothing below may log it or put it into a message.
    $plain = "$($p.PSObject.Properties['password']?.Value)"
    if (-not $plain) { throw "Payload field 'password' is empty. Correct the ServiceNow record." }
    $newPassword = [securestring]::new()
    foreach ($character in $plain.ToCharArray()) { $newPassword.AppendChar($character) }
    $newPassword.MakeReadOnly()
    $plain = $null

    # true or false, as a JSON boolean or as text; absent is false, as in 1.0. Anything
    # else is rejected rather than guessed at, before the directory is touched.
    $mustChange = $p.PSObject.Properties['mustChange']?.Value
    if ($null -eq $mustChange -or "$mustChange" -eq '') {
        $mustChange = $false
    } elseif ($mustChange -isnot [bool]) {
        $mustChange = switch ("$mustChange".Trim().ToLowerInvariant()) {
            'true' { $true }
            'false' { $false }
            default { throw "Payload field 'mustChange' must be true or false. Correct the ServiceNow record." }
        }
    }

    try {
        # onPremisesSyncEnabled is not in Graph's default property set; without -Property
        # it comes back null and a synchronised user would look cloud-only.
        $user = Get-MgUser -UserId $identity -Property 'id', 'userPrincipalName', 'onPremisesSyncEnabled' -ErrorAction Stop
    } catch {
        # Matched on Graph's error code, which leads the error id; the exception itself is a
        # plain System.Exception. Every other failure (throttling, access denied) is
        # rethrown as is: the password has not been sent yet, so it cannot be in it.
        if ($_.FullyQualifiedErrorId -notlike 'Request_ResourceNotFound,*') { throw }
        throw "No Entra ID user '$identity'. Correct the ServiceNow record."
    }

    # The user acted on must be the user asked for, whatever the request path made of it.
    if ($user.Id -ne $identity -and $user.UserPrincipalName -ne $identity) {
        throw "Graph returned a different user than '$identity' asked for. Nothing was changed."
    }
    if ($user.OnPremisesSyncEnabled) {
        throw "Entra ID user '$($user.UserPrincipalName)' is synchronised from on-premises Active Directory; its password can only be reset there. Use Set-ADUserPassword."
    }

    $fields = @{ userPrincipalName = $user.UserPrincipalName; id = $user.Id; queueSysId = $job.sys_id; mustChange = $mustChange }

    try {
        # By object id, so the user changed is the user looked up. The password is text
        # only inside this hashtable, for the length of the call.
        Update-MgUser -UserId $user.Id -ErrorAction Stop -PasswordProfile @{
            forceChangePasswordNextSignIn = $mustChange
            password                      = [pscredential]::new('rma', $newPassword).GetNetworkCredential().Password
        }
    } catch {
        # The SDK's error record holds the request body, password included, as its
        # TargetObject. Only Graph's message, which does not repeat the password, leaves
        # this block.
        throw [System.Exception]::new($_.Exception.Message)
    }
    Write-RmaLog -Level Information -Message 'Entra user password reset' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
