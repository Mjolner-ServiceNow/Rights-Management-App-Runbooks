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

        Every configuration value arrives as a runbook parameter from the ServiceNow
        application, so nothing is read back from ServiceNow here beyond proving the
        credential works. The command queue is the only ServiceNow table the runbooks read.

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
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]             [string] $VaultName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]             [string] $ManagedIdentityClientId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]             [string] $ServiceNowUserName,

        [string] $ServiceNowSecretName = 'servicenow-api-password'
    )

    Write-RmaLog -Level Information -Message 'Prerequisite check started' -Data @{
        instance = $Instance; vault = $VaultName
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

    Write-RmaLog -Level Information -Message 'Prerequisite check passed'

    # Two context shapes flow through this module under the same parameter name, and
    # passing the wrong one used to surface as a property-not-found somewhere far away.
    # They are named now. This one is the full context: it carries the managed identity,
    # which is what Connect-RmaGraph and Connect-RmaExchange read.
    # It also answers to Rma.ServiceNowContext, because it carries BaseUri and Headers and
    # the queue functions legitimately take it.
    $result = [pscustomobject]@{
        PSTypeName              = 'Rma.Context'
        Instance                = $Instance
        BaseUri                 = $context.BaseUri
        Headers                 = $context.Headers
        VaultName               = $VaultName
        ManagedIdentityClientId = $ManagedIdentityClientId
    }
    $result.PSObject.TypeNames.Insert(1, 'Rma.ServiceNowContext')
    $result
}
