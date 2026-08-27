function Get-RmaPendingJob {
    <#
    .SYNOPSIS
        Returns the next pending job(s) for a command, oldest first.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Context,

        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string] $DomainId,

        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{2,63}$')]
        [string] $Command,

        [ValidateRange(1, 100)]
        [int] $Limit = 1
    )

    $query = 'domain={0}^command={1}^status=1^ORDERBYsys_created_on' -f $DomainId, $Command
    $uri = '{0}/api/now/table/x_autps_active_dir_command_queue?sysparm_query={1}&sysparm_limit={2}' -f
    $Context.BaseUri, [uri]::EscapeDataString($query), $Limit

    $response = Invoke-RmaRestMethod -Uri $uri -Method GET -Headers $Context.Headers
    if (-not $response.result) { return @() }
    @($response.result)
}
