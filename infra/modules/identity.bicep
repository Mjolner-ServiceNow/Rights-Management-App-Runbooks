metadata description = 'User-assigned managed identity used by the Hybrid Worker runbooks.'

param identityName string
param location string
param tags object

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name:     identityName
  location: location
  tags:     tags
}

@description('Client ID. Used by IMDS token requests (?client_id=...).')
output clientId string = identity.properties.clientId

@description('Principal (object) ID. Used as the federated identity credential subject and for RBAC assignments.')
output principalId string = identity.properties.principalId

output resourceId string = identity.id
output name string = identity.name
