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

// NO identity block, and that is the whole point of this deployment.
//
// Enabling a managed identity on the Automation Account overrides the Hybrid Worker VM's
// identity, and every runbook then fails to authenticate. See main.bicep.
//
// It has to be expressed by omission rather than by `identity: { type: 'None' }`, because
// the Automation resource provider rejects an explicit None identity. It fails the whole
// deployment with the misleading error:
//
//     BadRequest: {"Message":"Could not find the account. SubscriptionId: ... AccountName: ..."}
//
// Verified by bisecting the request body: every other property below is accepted, and only
// the identity block fails. Do not "tidy this up" by adding one back.
//
// Because the property is absent rather than explicitly None, a redeployment will not
// remove an identity that someone enabled by hand. That is what the post-deployment
// assertion in scripts/Deploy-RmaPlatform.ps1 is for.
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name:     automationAccountName
  location: location
  tags:     tags

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
