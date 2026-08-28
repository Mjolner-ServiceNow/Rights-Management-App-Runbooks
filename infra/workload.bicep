targetScope = 'resourceGroup'

metadata description = '''
Rights Management App - the workload itself, deployed into an existing resource group.

Normally invoked by main.bicep, which creates the resource group first. Deploy this
directly with `az deployment group create` if you only hold Contributor on the resource
group rather than on the subscription.

Creates the Automation Account, the identity used by the Hybrid Worker, the Key Vault
holding the two credentials that cannot be federated, and the monitoring stack.

Every resource here is declarative: deploying against an existing installation converges
it rather than recreating anything. There is no "create if not exists" to write, because
that is what an ARM deployment already is.

Two constraints are deliberately encoded here and must not be "tidied up":

1. The Automation Account has NO managed identity of its own (identity.type = 'None').
   Enabling one overrides the Hybrid Worker VM's identity, and an Automation account
   user-assigned identity cannot be used from a Hybrid Worker at all. Turning it on
   silently breaks every runbook's authentication.

2. The Key Vault uses RBAC, not access policies, and denies public network access by
   default. Cloud Automation sandboxes cannot reach a firewalled vault; the Hybrid
   Worker's subnet can. This is one of the reasons the workload runs on the worker.
'''

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Workload short name. Used to build resource names.')
@minLength(2)
@maxLength(8)
param workload string = 'rma'

@description('Environment discriminator.')
@allowed(['dev', 'test', 'prod'])
param environment string

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Resource ID of the existing Hybrid Worker VM. The user-assigned identity is attached to it out of band; this is recorded for the Hybrid Worker Group registration.')
param hybridWorkerVmResourceId string

@description('Object IDs of principals that may manage Key Vault secrets (your operations group). Kept separate from the runtime identity, which is read-only.')
param secretsOfficerPrincipalIds array = []

@description('Email addresses notified by the alert action group.')
param alertEmailAddresses array = []

@description('Subnet resource ID permitted to reach the Key Vault. Leave empty only in dev.')
param allowedSubnetResourceId string = ''

@description('Log retention in days. 90 is the floor for a system with write access to AD and Entra ID.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

@description('Tags applied to every resource.')
param tags object = {}

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

var suffix       = '${workload}-${environment}'
var uniqueSuffix = uniqueString(resourceGroup().id, workload, environment)

var names = {
  automation:  'aa-${suffix}'
  identity:    'id-${suffix}'
  keyVault:    'kv-${workload}${environment}${take(uniqueSuffix, 6)}'   // globally unique, <=24 chars
  workspace:   'log-${suffix}'
  actionGroup: 'ag-${suffix}'
  workerGroup: 'hwg-${suffix}'
}

var commonTags = union(tags, {
  workload:    workload
  environment: environment
  managedBy:   'bicep'
  repository:  'Mjolner-ServiceNow/Rights-Management-App-Runbooks'
})

// Production must not expose the vault publicly.
var enforceVaultFirewall = environment == 'prod' || !empty(allowedSubnetResourceId)

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    workspaceName:    names.workspace
    actionGroupName:  names.actionGroup
    location:         location
    retentionDays:    logRetentionDays
    emailAddresses:   alertEmailAddresses
    tags:             commonTags
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    identityName: names.identity
    location:     location
    tags:         commonTags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    keyVaultName:              names.keyVault
    location:                  location
    tags:                      commonTags
    runtimeIdentityPrincipalId: identity.outputs.principalId
    secretsOfficerPrincipalIds: secretsOfficerPrincipalIds
    allowedSubnetResourceId:    allowedSubnetResourceId
    enforceFirewall:            enforceVaultFirewall
    workspaceId:                monitoring.outputs.workspaceId
    softDeleteRetentionDays:    environment == 'prod' ? 90 : 7
    enablePurgeProtection:      environment == 'prod'
  }
}

module automation 'modules/automation.bicep' = {
  name: 'automation'
  params: {
    automationAccountName:     names.automation
    hybridWorkerGroupName:     names.workerGroup
    location:                  location
    tags:                      commonTags
    hybridWorkerVmResourceId:  hybridWorkerVmResourceId
    workspaceId:               monitoring.outputs.workspaceId
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  params: {
    namePrefix:             suffix
    location:               location
    tags:                   commonTags
    workspaceId:            monitoring.outputs.workspaceId
    actionGroupId:          monitoring.outputs.actionGroupId
    automationAccountId:    automation.outputs.automationAccountId
    environment:            environment
  }
}

// ---------------------------------------------------------------------------
// Outputs - consumed by the deployment pipeline
// ---------------------------------------------------------------------------

output automationAccountName    string = automation.outputs.automationAccountName
output hybridWorkerGroupName    string = automation.outputs.hybridWorkerGroupName
output keyVaultName             string = keyVault.outputs.keyVaultName
output logAnalyticsWorkspaceId  string = monitoring.outputs.workspaceId

@description('Pass to runbooks as -ManagedIdentityClientId. This is the CLIENT id, used for IMDS token requests.')
output managedIdentityClientId  string = identity.outputs.clientId

@description('Use as the SUBJECT of the federated identity credential on the app registration. This is the PRINCIPAL id, and is a different GUID from the client id.')
output managedIdentityPrincipalId string = identity.outputs.principalId

output managedIdentityResourceId string = identity.outputs.resourceId
