metadata description = 'Log Analytics workspace and the action group used by all alert rules.'

param workspaceName string
param actionGroupName string
param location string
param retentionDays int
param emailAddresses array
param tags object

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name:     workspaceName
  location: location
  tags:     tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery:     'Enabled'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name:     actionGroupName
  location: 'global'
  tags:     tags
  properties: {
    groupShortName: take(replace(actionGroupName, '-', ''), 12)
    enabled: true
    emailReceivers: [for (address, i) in emailAddresses: {
      name: 'email${i}'
      emailAddress: address
      useCommonAlertSchema: true
    }]
  }
}

output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output actionGroupId string = actionGroup.id
