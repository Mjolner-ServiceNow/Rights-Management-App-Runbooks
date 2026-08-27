function Get-RmaDomainConfig {
    <#
    .SYNOPSIS
        Reads and validates the ServiceNow domain record.
    .DESCRIPTION
        The domain record is configuration only. Under the managed-identity model it no
        longer carries credential pointers, so a missing thumbprint or secret name is not
        an error here.

        Every field the runbooks depend on is validated up front, so a misconfigured
        record fails with a precise message instead of a null-reference several hundred
        lines later.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Context,

        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string] $DomainId,

        # Fields that must be present and non-empty for this runbook to function.
        [ValidateSet('TenantId', 'DomainControllerIp', 'ForestName', 'ApplicationId')]
        [string[]] $Require = @()
    )

    $uri = "$($Context.BaseUri)/api/now/table/x_autps_active_dir_domain/$($DomainId)" +
    '?sysparm_display_value=true&sysparm_limit=1'

    $response = Invoke-RmaRestMethod -Uri $uri -Method GET -Headers $Context.Headers

    if (-not $response.result) {
        throw "ServiceNow domain record '$DomainId' was not found on instance '$($Context.Instance)'."
    }
    $r = $response.result

    $get = {
        param($name)
        if ($r.PSObject.Properties.Name -notcontains $name) { return $null }
        $v = $r.$name
        if ($v -is [pscustomobject] -and $v.PSObject.Properties.Name -contains 'display_value') { $v = $v.display_value }
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        "$v".Trim()
    }

    $config = [pscustomobject]@{
        DomainId           = $DomainId
        TenantId           = & $get 'tenant_azure_active_directory'
        ApplicationId      = & $get 'applicationid'
        ForestName         = & $get 'forest_name'
        DomainControllerIp = & $get 'domain_controller_ip'
        SysDomain          = & $get 'sys_domain'
    }

    $missing = @($Require | Where-Object { -not $config.$_ })
    if ($missing.Count -gt 0) {
        throw "ServiceNow domain record '$DomainId' is missing required field(s): $($missing -join ', '). " +
        'Correct the record before running this runbook.'
    }

    Write-RmaLog -Level Information -Message 'Domain configuration loaded' -Data @{
        domainId = $DomainId; forest = $config.ForestName; tenantId = $config.TenantId
    }
    $config
}
