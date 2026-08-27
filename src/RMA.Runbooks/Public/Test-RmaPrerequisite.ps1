function Test-RmaPrerequisite {
    <#
    .SYNOPSIS
        Fail-fast gate. Validates configuration and connectivity before any work begins.
    .DESCRIPTION
        Checks run in cost order, cheapest first, so the common misconfigurations fail in
        under a second:

          1. Managed identity reachable (local, no network beyond IMDS)
          2. Key Vault readable
          3. ServiceNow authenticated
          4. Domain record present and complete

        Previously module installation ran before any of this, so a runbook with a bad
        credential still spent minutes writing modules to disk before failing. Module
        presence is now asserted by #Requires at parse time, which is earlier still.
    .OUTPUTS
        A context object carrying everything the runbook needs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')] [string] $Instance,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]    [string] $DomainId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]             [string] $VaultName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]             [string] $ManagedIdentityClientId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]             [string] $ServiceNowUserName,

        [string]   $ServiceNowSecretName = 'servicenow-api-password',
        [string[]] $RequireDomainField   = @()
    )

    Write-RmaLog -Level Information -Message 'Prerequisite check started' -Data @{
        instance = $Instance; domainId = $DomainId; vault = $VaultName
    }

    # 1. Managed identity
    try {
        $null = Get-RmaAccessToken -Resource 'https://vault.azure.net' -ManagedIdentityClientId $ManagedIdentityClientId
    } catch {
        throw "Managed identity check failed. On a Hybrid Worker this usually means the Automation " +
        "account has its own managed identity enabled, which overrides the VM's. " +
        "Underlying error: $($_.Exception.Message)"
    }

    # 2 + 3. Key Vault and ServiceNow, in one step
    $context = Connect-RmaServiceNow -Instance $Instance -VaultName $VaultName `
        -UserName $ServiceNowUserName -SecretName $ServiceNowSecretName `
        -ManagedIdentityClientId $ManagedIdentityClientId

    # 4. Domain record
    $config = Get-RmaDomainConfig -Context $context -DomainId $DomainId -Require $RequireDomainField

    Write-RmaLog -Level Information -Message 'Prerequisite check passed'

    [pscustomobject]@{
        Instance                = $Instance
        BaseUri                 = $context.BaseUri
        Headers                 = $context.Headers
        DomainId                = $DomainId
        VaultName               = $VaultName
        ManagedIdentityClientId = $ManagedIdentityClientId
        Domain                  = $config
    }
}
