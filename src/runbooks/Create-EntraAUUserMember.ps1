#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks';                                 RequiredVersion = '2.2.0'  }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication';               RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Users';                        RequiredVersion = '2.39.0' }
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Identity.DirectoryManagement'; RequiredVersion = '2.39.0' }

<#
.SYNOPSIS
    Adds a user to an Entra ID administrative unit, from the ServiceNow command queue.
.DESCRIPTION
    Built on Create-EntraUser, the reference for Entra ID runbooks; only the body differs.
    The app registration needs the AdministrativeUnit.ReadWrite.All and User.Read.All
    application permissions. An administrative unit with restricted management also needs
    a role assigned to the app on that unit; without one Graph refuses with
    Authorization_RequestDenied, and the job fails with that reason.

    Only a user is added, as in 1.0; the payload has no field for a group or a device
    member.

    Adding is idempotent: a user who is already a member is logged and the job completes,
    since the outcome ServiceNow asked for is already true. An administrative unit or a
    user that does not exist fails the job, as it did in 1.0: there is nothing to add to,
    or nothing to add (docs/DECISIONS.md D15 covers deletes only). So does an
    administrative unit with dynamic membership, also as in 1.0: its members come from its
    rule, and Graph would refuse the addition with an access-denied that names no reason.

    The administrative unit and the user are looked up first and the user is added by the
    two object ids that came back, so the addition cannot hit a different object that took
    the name in between.
.NOTES
    Payload:
      ou      the administrative unit, as its object id
      user    the member to add, as its object id or its user principal name
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

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Create-EntraAUUserMember' -Body {
    param($job, $p)

    # Both values become segments of Graph URLs, so each must be what Graph expects there
    # and nothing else: a '/' would address a different resource, and Graph decodes '%23'
    # to '#'. The UPN set is the one Entra accepts, guest '#EXT#' included. Read through
    # PSObject: under StrictMode a missing field would otherwise throw a property-not-found
    # that says nothing about the payload.
    $field = {
        param($Payload, [string] $Name, [string] $Pattern, [string] $Expected)
        $value = "$($Payload.PSObject.Properties[$Name]?.Value)".Trim()
        if ($value -notmatch $Pattern) {
            throw "Payload field '$Name' is empty or is not $Expected. Correct the ServiceNow record."
        }
        $value
    }
    $objectId = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    $unitId = & $field $p 'ou' ('^' + $objectId + '\z') 'an object id'
    $userIdentity = & $field $p 'user' ('^(?:' + $objectId + '|[A-Za-z0-9._!#^~''-]{1,64}@[A-Za-z0-9.-]{1,255})\z') `
        'an object id or a user principal name'

    # Graph reports a missing object as a plain System.Exception; only the error id names
    # the reason. Every other failure (throttling past the SDK's retries, access denied) is
    # rethrown as is.
    $isNotFound = { param($record) $record.FullyQualifiedErrorId -like 'Request_ResourceNotFound,*' }

    try {
        $unit = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $unitId `
            -Property 'id', 'displayName', 'membershipType' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        throw "No Entra ID administrative unit '$unitId'. Correct the ServiceNow record."
    }

    # Graph answers an addition to a dynamic unit with Authorization_RequestDenied and
    # 'Insufficient privileges' (test tenant, SDK 2.39.0), which sends whoever reads the
    # ServiceNow record to the app's permissions. Say what is actually wrong.
    if ($unit.MembershipType -eq 'Dynamic') {
        throw "Entra ID administrative unit '$($unit.DisplayName)' has dynamic membership; its members come from its rule and cannot be added. Correct the ServiceNow record."
    }

    try {
        $user = Get-MgUser -UserId $userIdentity -Property 'id', 'userPrincipalName' -ErrorAction Stop
    } catch {
        if (-not (& $isNotFound $_)) { throw }
        throw "No Entra ID user '$userIdentity'. Correct the ServiceNow record."
    }

    # The objects changed are the objects the payload named, not ones Graph resolved some
    # other way. PowerShell's -ne ignores case, as object ids and user principal names do.
    if ($unit.Id -ne $unitId) {
        throw "Graph returned an administrative unit other than the one payload field 'ou' names; nothing was added."
    }
    if ($user.Id -ne $userIdentity -and $user.UserPrincipalName -ne $userIdentity) {
        throw "Graph returned a user other than the one payload field 'user' names; nothing was added."
    }

    $fields = @{
        administrativeUnit = $unit.DisplayName; administrativeUnitId = $unit.Id
        upn = $user.UserPrincipalName; userId = $user.Id; queueSysId = $job.sys_id
    }

    # A user who is already a member is a 400 Request_BadRequest whose message alone says
    # why (test tenant, SDK 2.39.0): the generic directory conflict, not the 'added object
    # references already exist' a group gives. The request carries nothing but the member
    # reference, so the conflict is the membership. Any other bad request is rethrown.
    $isMember = {
        param($record)
        $record.FullyQualifiedErrorId -like 'Request_BadRequest,*' -and
        $record.Exception.Message -like '*conflicting object with one or more of the specified property values is present*'
    }

    try {
        New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $unit.Id `
            -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" -Confirm:$false -ErrorAction Stop
    } catch {
        if (-not (& $isMember $_)) { throw }
        Write-RmaLog -Level Information -Message 'Entra user is already a member of the administrative unit; nothing to do' -Data $fields
        return
    }
    Write-RmaLog -Level Information -Message 'Entra administrative unit member added' -Data $fields
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) {
    throw "$($summary.Failed) of $($summary.Processed) job(s) failed. Individual reasons are on the ServiceNow records."
}
