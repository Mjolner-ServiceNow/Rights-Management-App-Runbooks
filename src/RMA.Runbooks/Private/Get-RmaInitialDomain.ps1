function Get-RmaInitialDomain {
    <#
    .SYNOPSIS
        Returns the tenant's initial *.onmicrosoft.com domain, read from Microsoft Graph.
    .DESCRIPTION
        Exchange Online's -Organization is that domain. Reading it from the tenant spares the
        ServiceNow domain record a field for it (docs/DECISIONS.md D20). Every tenant has
        exactly one initial domain, and it cannot be renamed or removed.

        Needs a Graph connection (Connect-RmaGraph) and Domain.Read.All.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication is not available. Declare it with #Requires in the runbook, and call Connect-RmaGraph first.'
    }

    $response = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/domains?$select=id,isInitial' -ErrorAction Stop
    $initial = @(@($response['value']) | Where-Object { $_['isInitial'] } | ForEach-Object { $_['id'] })
    if ($initial.Count -ne 1 -or $initial[0] -notmatch '^[A-Za-z0-9-]+\.onmicrosoft\.com$') {
        throw "Graph returned $($initial.Count) initial domain(s) for the tenant, where one *.onmicrosoft.com domain was expected; Exchange Online cannot be connected."
    }
    $initial[0]
}
