function Test-RmaDeletedDirectoryObject {
    <#
    .SYNOPSIS
        Says whether an Entra ID object id is in the directory's deleted items.
    .DESCRIPTION
        A lookup that finds nothing cannot tell an object that is gone from one Graph has not
        replicated yet: a job queued straight after the create was told by Get-MgUser that a
        user created within the same second did not exist (#146, #173). A deleted user,
        group or administrative unit stays in deleted items, found by its id, until it is
        purged or 30 days have passed. So an id found there was deleted and is gone, and an
        id found neither there nor live may still be on its way (docs/DECISIONS.md D19).

        Needs a Graph connection (Connect-RmaGraph) and read permission on the object's type,
        which the runbooks that delete it already have. Returns $true or $false; any error
        other than not found, such as access denied or throttling, is thrown as is.
    .PARAMETER Id
        The object id. A user principal name cannot be looked up here: Entra rewrites a
        deleted user's.
    .EXAMPLE
        if (Test-RmaDeletedDirectoryObject -Id $groupId) { 'deleted' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')]
        [string] $Id
    )

    try {
        $null = Invoke-MgGraphRequest -Method GET -Uri "v1.0/directory/deletedItems/$Id" -ErrorAction Stop
        $true
    } catch {
        # Invoke-MgGraphRequest reports a 404 as an HttpResponseException whose Response
        # carries the status, unlike the generated cmdlets' Request_ResourceNotFound error id
        # (worker, SDK 2.39.0). Read through Get-RmaProperty: a transport failure has no
        # Response, and reading it unguarded would throw under StrictMode.
        $response = Get-RmaProperty -InputObject $_.Exception -Name 'Response'
        if ("$(Get-RmaProperty -InputObject $response -Name 'StatusCode')" -ne 'NotFound') { throw }
        $false
    }
}
