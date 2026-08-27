metadata description = '''
Automation Account and Hybrid Worker Group.

The account has NO managed identity. See the note in main.bicep: enabling one overrides
the Hybrid Worker VM's identity and breaks runbook authentication. This is enforced here
rather than left to a runbook comment nobody reads.
'''

param automationAccountName string
param hybridWorkerGroupName string
param location string
param tags object
param hybridWorkerVmResourceId string
param workspaceId string

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name:     automationAccountName
  location: location
  tags:     tags

  // Intentional. Do not change to SystemAssigned or UserAssigned.
  identity: {
    type: 'None'
  }

  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
    disableLocalAuth: false
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

resource hybridWorkerGroup 'Microsoft.Automation/automationAccounts/hybridRunbookWorkerGroups@2023-11-01' = {
  parent: automationAccount
  name:   hybridWorkerGroupName
  properties: {}
}

// Job logs and job streams are what the alert rules and the KQL queries in docs/ run against.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: automationAccount
  name:  'to-log-analytics'
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'JobLogs',            enabled: true }
      { category: 'JobStreams',         enabled: true }
      { category: 'DscNodeStatus',      enabled: false }
      { category: 'AuditEvent',         enabled: true }
    ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output automationAccountName string = automationAccount.name
output automationAccountId   string = automationAccount.id
output hybridWorkerGroupName string = hybridWorkerGroup.name

@description('Recorded for traceability. The identity is attached to this VM out of band; the extension registers it into the worker group.')
output registeredVmResourceId string = hybridWorkerVmResourceId
