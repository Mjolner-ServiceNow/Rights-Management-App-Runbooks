metadata description = '''
Alert rules over the Automation job streams.

These map one-to-one onto the failure modes found during the code review. Each rule
exists because that specific failure has either already happened or is unrecoverable
without human intervention.
'''

param namePrefix string
param location string
param tags object
param workspaceId string
param actionGroupId string
param automationAccountId string
param environment string

// Only page in production. Lower environments record but do not notify.
var notifyActions = environment == 'prod' ? {
  actionGroups: [ actionGroupId ]
} : { actionGroups: [] }

var rules = [
  {
    name:        'jobs-stranded-in-progress'
    displayName: 'RMA: jobs stranded in Work in Progress'
    description: 'A claimed job has not reached a terminal state. The watchdog should requeue it; if this fires repeatedly the watchdog itself is failing.'
    severity:    1
    query:       '''
AutomationJobLogs
| where TimeGenerated > ago(1h)
| where ResultType == "Failed" or ResultType == "Stopped"
| summarize StrandedJobs = count() by RunbookName
| where StrandedJobs > 0
'''
    threshold:   0
    operator:    'GreaterThan'
    windowSize:  'PT1H'
    frequency:   'PT15M'
  }
  {
    name:        'runbook-failure-rate'
    displayName: 'RMA: elevated runbook failure rate'
    description: 'More than five job failures in fifteen minutes across any runbook.'
    severity:    2
    query:       '''
AutomationJobLogs
| where TimeGenerated > ago(15m)
| where ResultType == "Failed"
| summarize Failures = count()
'''
    threshold:   5
    operator:    'GreaterThan'
    windowSize:  'PT15M'
    frequency:   'PT5M'
  }
  {
    name:        'job-claim-contention'
    displayName: 'RMA: high job claim contention'
    description: 'Workers are repeatedly losing the claim race. Expected occasionally with several workers; sustained contention means the schedule is too aggressive for the queue depth.'
    severity:    3
    query:       '''
AutomationJobStreams
| where TimeGenerated > ago(30m)
| where StreamType == "Output"
| extend Parsed = parse_json(ResultDescription)
| where tostring(Parsed.message) == "Job claim lost to another worker"
| summarize Contention = count()
'''
    threshold:   50
    operator:    'GreaterThan'
    windowSize:  'PT30M'
    frequency:   'PT15M'
  }
  {
    name:        'queue-loop-hit-safety-limit'
    displayName: 'RMA: queue loop stopped at a safety limit'
    description: 'A run stopped on the iteration or time cap with jobs still queued. Sustained firing means throughput is below arrival rate; add a worker or increase frequency.'
    severity:    2
    query:       '''
AutomationJobStreams
| where TimeGenerated > ago(1h)
| where StreamType == "Warning"
| extend Parsed = parse_json(ResultDescription)
| where tostring(Parsed.message) startswith "Queue loop finished (max-"
| summarize Hits = count()
'''
    threshold:   0
    operator:    'GreaterThan'
    windowSize:  'PT1H'
    frequency:   'PT15M'
  }
  {
    name:        'module-install-attempted'
    displayName: 'RMA: a runbook attempted a runtime module install'
    description: 'Runbooks must never install modules at run time. Firing means an unreviewed runbook reached production, or a rollback restored an old one.'
    severity:    2
    query:       '''
AutomationJobStreams
| where TimeGenerated > ago(1h)
| where ResultDescription has "Install-Module"
| summarize Attempts = count()
'''
    threshold:   0
    operator:    'GreaterThan'
    windowSize:  'PT1H'
    frequency:   'PT30M'
  }
]

resource alertRules 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [for rule in rules: {
  name:     '${namePrefix}-${rule.name}'
  location: location
  tags:     tags
  properties: {
    displayName:         rule.displayName
    description:         rule.description
    severity:            rule.severity
    enabled:             true
    scopes:              [ workspaceId ]
    evaluationFrequency: rule.frequency
    windowSize:          rule.windowSize
    autoMitigate:        true
    criteria: {
      allOf: [
        {
          query:           rule.query
          timeAggregation: 'Count'
          operator:        rule.operator
          threshold:       rule.threshold
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert:  1
          }
        }
      ]
    }
    actions: notifyActions
  }
}]

// Any runbook job that fails at the platform level, independent of our own logging.
resource jobFailureMetric 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name:     '${namePrefix}-runbook-job-failed'
  location: 'global'
  tags:     tags
  properties: {
    description: 'An Automation job reported Failed at the platform level.'
    severity:    2
    enabled:     true
    scopes:      [ automationAccountId ]
    evaluationFrequency: 'PT5M'
    windowSize:          'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name:            'FailedJobs'
          metricName:      'TotalJob'
          metricNamespace: 'Microsoft.Automation/automationAccounts'
          operator:        'GreaterThan'
          threshold:       0
          timeAggregation: 'Total'
          criterionType:   'StaticThresholdCriterion'
          dimensions: [
            { name: 'Status', operator: 'Include', values: [ 'Failed' ] }
          ]
        }
      ]
    }
    actions: environment == 'prod' ? [ { actionGroupId: actionGroupId } ] : []
  }
}

output alertRuleNames array = [for (rule, i) in rules: alertRules[i].name]
