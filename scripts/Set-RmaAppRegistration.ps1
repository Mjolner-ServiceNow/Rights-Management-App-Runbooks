#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Applications'; ModuleVersion = '2.39.0' }

<#
.SYNOPSIS
    Configures the app registration and its federated identity credential.
.DESCRIPTION
    This part of the platform cannot be expressed in Bicep, because app registrations,
    API permissions and federated credentials live in Microsoft Graph rather than ARM.

    Idempotent: safe to re-run. Existing objects are matched by name and updated rather
    than duplicated.

    Run once per environment, by a Cloud Application Administrator, after the Bicep
    deployment has produced the managed identity principal id.

    Three things it deliberately does NOT do:
      - Grant admin consent. That is a conscious human decision and is left to the portal
        or a separate approved step.
      - Assign the Entra directory role. Role assignment is privileged and is done by an
        identity administrator, not by a deployment script.
      - Create any secret or certificate. That is the entire point of the design.
.EXAMPLE
    ./Set-RmaAppRegistration.ps1 -DisplayName 'RMA Runbooks (prod)' `
        -ManagedIdentityPrincipalId (az deployment group show -g rg-rma-prod -n main --query properties.outputs.managedIdentityPrincipalId.value -o tsv) `
        -TenantId $env:AZURE_TENANT_ID
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'FederatedCredentialName',
    Justification = 'This names an Entra federated identity credential object; it is not a password. The rule matched the word Credential.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string] $DisplayName,

    # Principal (object) id of the user-assigned managed identity. NOT its client id.
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $ManagedIdentityPrincipalId,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $TenantId,

    [string] $FederatedCredentialName = 'rma-hybrid-worker'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Constant in every tenant.
$graphAppId    = '00000003-0000-0000-c000-000000000000'
$exchangeAppId = '00000002-0000-0ff1-ce00-000000000000'
$exchangeManageAsApp = 'dc50a0fb-09a3-484d-be87-e023b12c6440'

# Least privilege: only what the runbooks actually call.
$graphAppRoles = @(
    'User.ReadWrite.All'
    'Group.ReadWrite.All'
    'GroupMember.ReadWrite.All'
    'Directory.Read.All'
    'AdministrativeUnit.ReadWrite.All'
    'UserAuthenticationMethod.ReadWrite.All'
)

Write-Host "Connecting to Microsoft Graph in tenant $TenantId..."
Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All' -NoWelcome

# --- application ---------------------------------------------------------
$app = Get-MgApplication -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) {
    if ($PSCmdlet.ShouldProcess($DisplayName, 'Create app registration')) {
        $app = New-MgApplication -DisplayName $DisplayName -SignInAudience 'AzureADMyOrg'
        Write-Host "  created application $($app.AppId)"
    }
} else {
    Write-Host "  application already exists: $($app.AppId)"
}

# --- required resource access -------------------------------------------
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
$graphResourceAccess = @(
    foreach ($role in $graphAppRoles) {
        $definition = $graphSp.AppRoles | Where-Object { $_.Value -eq $role -and $_.AllowedMemberTypes -contains 'Application' }
        if (-not $definition) { throw "Graph application role '$role' not found." }
        @{ id = $definition.Id; type = 'Role' }
    }
)

$required = @(
    @{ resourceAppId = $graphAppId; resourceAccess = $graphResourceAccess }
    @{ resourceAppId = $exchangeAppId; resourceAccess = @(@{ id = $exchangeManageAsApp; type = 'Role' }) }
)

if ($PSCmdlet.ShouldProcess($DisplayName, 'Set required API permissions')) {
    Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess $required
    Write-Host "  set $($graphAppRoles.Count) Graph role(s) + Exchange.ManageAsApp"
}

# --- federated identity credential ---------------------------------------
$issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
$existing = Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -ErrorAction SilentlyContinue |
Where-Object { $_.Name -eq $FederatedCredentialName }

$ficParams = @{
    Name      = $FederatedCredentialName
    Issuer    = $issuer
    Subject   = $ManagedIdentityPrincipalId
    Audiences = @('api://AzureADTokenExchange')
    Description = 'Trusts the Hybrid Worker user-assigned managed identity. Subject is the identity PRINCIPAL id.'
}

if ($existing) {
    if ($existing.Subject -ne $ManagedIdentityPrincipalId) {
        Write-Warning "  federated credential subject differs. Existing: $($existing.Subject). Recreating."
        if ($PSCmdlet.ShouldProcess($FederatedCredentialName, 'Recreate federated credential')) {
            Remove-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -FederatedIdentityCredentialId $existing.Id
            New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter $ficParams | Out-Null
        }
    } else { Write-Host '  federated credential already correct' }
} elseif ($PSCmdlet.ShouldProcess($FederatedCredentialName, 'Create federated credential')) {
    New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter $ficParams | Out-Null
    Write-Host "  created federated credential '$FederatedCredentialName'"
}

# --- service principal ---------------------------------------------------
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $sp -and $PSCmdlet.ShouldProcess($app.AppId, 'Create service principal')) {
    $sp = New-MgServicePrincipal -AppId $app.AppId
    Write-Host "  created service principal $($sp.Id)"
}

Write-Host ''
Write-Host '=== Manual steps that intentionally remain ==='
Write-Host "  1. Grant tenant admin consent for the API permissions on app $($app.AppId)."
Write-Host '  2. Assign the Exchange Recipient Administrator directory role to the service principal.'
Write-Host '     (Recipient Administrator is sufficient for every Exchange cmdlet these runbooks call.)'
Write-Host ''
Write-Host "ApplicationId (pass to runbooks): $($app.AppId)"
