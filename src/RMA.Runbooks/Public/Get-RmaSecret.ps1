function Get-RmaSecret {
    <#
    .SYNOPSIS
        Reads a secret from Key Vault using the workload's managed identity.
    .DESCRIPTION
        Uses the Key Vault REST API rather than Az.KeyVault so the worker needs no Az
        modules. Returns a SecureString by default; -AsPlainText is available for the few
        call sites that need a raw string, and is deliberately explicit so it shows up in
        review.
    .EXAMPLE
        $cred = Get-RmaSecret -VaultName kv-rma-prod -Name servicenow-api-password `
            -ManagedIdentityClientId $mi -AsCredential -UserName 'svc-rma'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'The Key Vault REST API returns secret values as plain strings. Converting here is what allows every caller to receive a SecureString or PSCredential instead.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'AsPlainText and AsCredential select a parameter set; the branch is taken on $PSCmdlet.ParameterSetName rather than by reading the switch.')]
    [CmdletBinding(DefaultParameterSetName = 'Secure')]
    [OutputType([securestring], [string], [pscredential])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]{3,24}$')]
        [string] $VaultName,

        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]{1,127}$')]
        [string] $Name,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $ManagedIdentityClientId,

        [Parameter(ParameterSetName = 'Plain')]
        [switch] $AsPlainText,

        [Parameter(Mandatory, ParameterSetName = 'Credential')]
        [switch] $AsCredential,

        [Parameter(Mandatory, ParameterSetName = 'Credential')][ValidateNotNullOrEmpty()]
        [string] $UserName,

        [string] $ApiVersion = '7.4'
    )

    $token = Get-RmaAccessToken -Resource 'https://vault.azure.net' -ManagedIdentityClientId $ManagedIdentityClientId

    $value = (Invoke-RmaRestMethod `
            -Uri "https://$VaultName.vault.azure.net/secrets/$($Name)?api-version=$ApiVersion" `
            -Method GET `
            -Headers @{ Authorization = "Bearer $token" }).value

    if ([string]::IsNullOrEmpty($value)) {
        throw "Key Vault secret '$Name' in vault '$VaultName' is empty or was not returned."
    }

    switch ($PSCmdlet.ParameterSetName) {
        'Plain'      { return $value }
        'Credential' { return [pscredential]::new($UserName, (ConvertTo-SecureString $value -AsPlainText -Force)) }
        default      { return ConvertTo-SecureString $value -AsPlainText -Force }
    }
}
