metadata description = '''
Key Vault holding the two credentials that cannot be federated: the ServiceNow API
password and the Active Directory service account password.

RBAC authorisation, not access policies. The runtime identity gets Secrets User (read
only) and never Secrets Officer, so a compromised worker can read the secrets it needs
but cannot rotate, add, or delete them.
'''

param keyVaultName string
param location string
param tags object
param runtimeIdentityPrincipalId string
param secretsOfficerPrincipalIds array
param allowedSubnetResourceId string
param enforceFirewall bool
param workspaceId string
param softDeleteRetentionDays int
param enablePurgeProtection bool

// Built-in role definition IDs are constant across all tenants.
var roles = {
  secretsUser:    '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
  secretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' // Key Vault Secrets Officer
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name:     keyVaultName
  location: location
  tags:     tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId

    enableRbacAuthorization:   true
    enableSoftDelete:          true
    softDeleteRetentionInDays: softDeleteRetentionDays
    enablePurgeProtection:     enablePurgeProtection ? true : null

    publicNetworkAccess: enforceFirewall ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass:        'AzureServices'
      defaultAction: enforceFirewall ? 'Deny' : 'Allow'
      virtualNetworkRules: empty(allowedSubnetResourceId) ? [] : [
        { id: allowedSubnetResourceId, ignoreMissingVnetServiceEndpoint: false }
      ]
      ipRules: []
    }
  }
}

// Runtime: read only.
resource runtimeRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name:  guid(vault.id, runtimeIdentityPrincipalId, roles.secretsUser)
  properties: {
    principalId:      runtimeIdentityPrincipalId
    principalType:    'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.secretsUser)
  }
}

// Operators: manage secrets.
resource officers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in secretsOfficerPrincipalIds: {
  scope: vault
  name:  guid(vault.id, principalId, roles.secretsOfficer)
  properties: {
    principalId:      principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.secretsOfficer)
  }
}]

// Every secret read is auditable. This is one of the controls the customer asked for.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: vault
  name:  'to-log-analytics'
  properties: {
    workspaceId: workspaceId
    logs: [
      { categoryGroup: 'audit',       enabled: true }
      { categoryGroup: 'allLogs',     enabled: true }
    ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output keyVaultName string = vault.name
output keyVaultUri  string = vault.properties.vaultUri
output keyVaultId   string = vault.id
