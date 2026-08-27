@{
    RootModule        = 'RMA.Runbooks.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c2f6b1e4-9a3d-4f7b-8c15-2e6d4a9b7c30'
    Author            = 'Cloud Operations Department'
    CompanyName       = 'Mjølner Informatics A/S'
    Copyright         = '(c) Mjølner Informatics A/S. All rights reserved.'
    Description       = 'Shared runtime for the Rights Management App runbooks: ServiceNow queue handling with atomic job claiming, managed-identity authentication, Key Vault secret retrieval and structured logging.'

    PowerShellVersion = '7.2'

    # Dependencies are pinned. Never widen these without a released change.
    RequiredModules   = @()

    FunctionsToExport = @(
        'Write-RmaLog'
        'Invoke-RmaRestMethod'
        'Get-RmaAccessToken'
        'Get-RmaSecret'
        'Connect-RmaServiceNow'
        'Get-RmaDomainConfig'
        'Test-RmaPrerequisite'
        'Connect-RmaGraph'
        'Connect-RmaExchange'
        'Get-RmaPendingJob'
        'Request-RmaJobClaim'
        'Set-RmaJobState'
        'Invoke-RmaQueueLoop'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('ServiceNow', 'Automation', 'ActiveDirectory', 'Entra')
            ProjectUri   = 'https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks'
            ReleaseNotes = 'See CHANGELOG.md'
        }
    }
}
