function Connect-RmaServiceNow {
    <#
    .SYNOPSIS
        Builds an authenticated ServiceNow context from a Key Vault secret.
    .DESCRIPTION
        Replaces Get-AutomationPSCredential. Verifies the credential actually works by
        making one cheap authenticated call, so a bad password fails here with a clear
        message rather than deep inside the queue loop.
    .OUTPUTS
        A context object carrying Instance, Headers and BaseUri, passed to the other
        Rma queue functions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')]
        [string] $Instance,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $VaultName,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $UserName,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $SecretName,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $ManagedIdentityClientId
    )

    $password = Get-RmaSecret -VaultName $VaultName -Name $SecretName `
        -ManagedIdentityClientId $ManagedIdentityClientId -AsPlainText

    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${UserName}:${password}"))
    $password = $null   # drop the plaintext as soon as the header exists

    $headers = @{
        Authorization  = "Basic $basic"
        Accept         = 'application/json'
        'Content-Type' = 'application/json; charset=utf-8'
    }

    $context = [pscustomobject]@{
        Instance = $Instance
        BaseUri  = "https://$Instance.service-now.com"
        Headers  = $headers
    }

    # Fail fast: prove the credential works before anything else is attempted.
    try {
        $null = Invoke-RmaRestMethod -Method GET -Headers $headers -MaxAttempts 2 `
            -Uri "$($context.BaseUri)/api/now/table/x_autps_active_dir_command_queue?sysparm_limit=1&sysparm_fields=sys_id"
    } catch {
        throw "ServiceNow authentication check failed for instance '$Instance' as '$UserName'. " +
        "Verify the Key Vault secret '$SecretName' is current and the account has read " +
        "access to the command queue table. Underlying error: $($_.Exception.Message)"
    }

    Write-RmaLog -Level Information -Message 'ServiceNow context established' -Data @{ instance = $Instance; user = $UserName }
    $context
}
