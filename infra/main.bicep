targetScope = 'subscription'

metadata description = '''
Rights Management App - entry point.

Creates the resource group if it does not exist, then deploys the workload into it.

Scope note. A resource-group-scoped template cannot create its own resource group, so this
file targets the subscription. That means deploying it needs Contributor at *subscription*
scope, which is a meaningful step up from Contributor on one resource group and is more
than some organisations will grant for an application deployment.

If subscription Contributor is not available, create the resource group by hand once and
deploy infra/workload.bicep directly instead:

    az group create --name rg-rma-prod --location westeurope
    az deployment group create -g rg-rma-prod \
        --template-file infra/workload.bicep \
        --parameters infra/main.parameters.prod.local.json

Both paths produce exactly the same resources; this one just also owns the resource group.

Re-running is safe. ARM converges an existing deployment rather than recreating it, so
neither the resource group nor the Automation Account is touched if it already matches.

The Automation Account deliberately has no managed identity, expressed by omitting the
identity property. The resource provider rejects an explicit `identity: { type: 'None' }`.
See the comment in modules/automation.bicep.
'''

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Resource group to create or reuse.')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('Location for the resource group and every resource in it.')
param location string

@description('Workload short name. Used to build resource names.')
@minLength(2)
@maxLength(8)
param workload string = 'rma'

@description('Environment discriminator.')
@allowed(['dev', 'test', 'prod'])
param environment string

@description('Resource ID of the existing Hybrid Worker VM.')
param hybridWorkerVmResourceId string

@description('Object IDs of principals that may manage Key Vault secrets.')
param secretsOfficerPrincipalIds array = []

@description('Email addresses notified by the alert action group.')
param alertEmailAddresses array = []

@description('Subnet resource ID permitted to reach the Key Vault. Leave empty only in dev.')
param allowedSubnetResourceId string = ''

@description('Log retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

@description('Tags applied to the resource group and every resource in it.')
param tags object = {}

// ---------------------------------------------------------------------------
// Resource group
//
// Idempotent. If the group already exists this is a no-op, with one exception worth
// knowing: a resource group cannot be moved, so if the existing group is in a different
// location than `location`, the deployment fails rather than silently ignoring it.
// ---------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name:     resourceGroupName
  location: location
  tags:     tags
}

// ---------------------------------------------------------------------------
// Workload
// ---------------------------------------------------------------------------

module platform 'workload.bicep' = {
  name:  'workload'
  scope: rg
  params: {
    workload:                   workload
    environment:                environment
    location:                   location
    hybridWorkerVmResourceId:   hybridWorkerVmResourceId
    secretsOfficerPrincipalIds: secretsOfficerPrincipalIds
    alertEmailAddresses:        alertEmailAddresses
    allowedSubnetResourceId:    allowedSubnetResourceId
    logRetentionDays:           logRetentionDays
    tags:                       tags
  }
}

// ---------------------------------------------------------------------------
// Outputs - consumed by the deployment script and the installation guide
// ---------------------------------------------------------------------------

output resourceGroupName        string = rg.name
output automationAccountName    string = platform.outputs.automationAccountName
output hybridWorkerGroupName    string = platform.outputs.hybridWorkerGroupName
output keyVaultName             string = platform.outputs.keyVaultName
output logAnalyticsWorkspaceId  string = platform.outputs.logAnalyticsWorkspaceId

@description('Pass to runbooks as -ManagedIdentityClientId. This is the CLIENT id, used for IMDS token requests.')
output managedIdentityClientId string = platform.outputs.managedIdentityClientId

@description('Use as the SUBJECT of the federated identity credential on the app registration. This is the PRINCIPAL id, and is a different GUID from the client id.')
output managedIdentityPrincipalId string = platform.outputs.managedIdentityPrincipalId

output managedIdentityResourceId string = platform.outputs.managedIdentityResourceId
