#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Which checks Test-RmaHealth runs depends on which directory values it is passed, and the
# ServiceNow application relies on that: it passes the Entra parameters, the Active
# Directory ones, or both, depending on what the domain has enabled.
#
# That used to be three parameter sets. Azure Automation refuses to start a runbook that
# declares any, so the decision moved into the script body, and these tests run the
# script to prove it. The repository's src/ goes on PSModulePath so the script's #Requires
# resolves to the module in this checkout; every call that would leave the machine is
# mocked.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:Runbook = Join-Path $repoRoot 'src/runbooks/Test-RmaHealth.ps1'

    $script:SavedModulePath = $env:PSModulePath
    # The runbook sets $PSStyle.OutputRendering, which is session-wide, not scoped.
    $script:SavedRendering = $PSStyle.OutputRendering
    $env:PSModulePath = (Join-Path $repoRoot 'src') + [IO.Path]::PathSeparator + $env:PSModulePath

    $script:Common = @{
        DomainId                = '0123456789abcdef0123456789abcdef'
        Instance                = 'contoso'
        VaultName               = 'kv-rma-contoso'
        ManagedIdentityClientId = '00000000-0000-0000-0000-000000000001'
        ServiceNowUserName      = 'svc.rma'
    }
    $script:Entra = @{
        TenantId      = '00000000-0000-0000-0000-000000000002'
        ApplicationId = '00000000-0000-0000-0000-000000000003'
    }
    $script:ActiveDirectory = @{
        DomainController = 'dc01.contoso.com'
        AdUserName       = 'CONTOSO\svc.rma'
    }

    # Stand-in for the ActiveDirectory module, which is Windows-only. Mock needs a command
    # to replace.
    $script:StubbedAd = -not (Get-Command Get-ADDomain -ErrorAction Ignore)
    if ($script:StubbedAd) {
        function global:Get-ADDomain {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the runbook can bind them; a stub has no body to read them in.')]
            param([string] $Server, [pscredential] $Credential)
        }
    }
}

AfterAll {
    $env:PSModulePath = $script:SavedModulePath
    $PSStyle.OutputRendering = $script:SavedRendering
    if ($script:StubbedAd) { Remove-Item function:global:Get-ADDomain -ErrorAction SilentlyContinue }
}

Describe 'Test-RmaHealth parameter binding' -Tag 'Unit' {

    It 'declares no parameter sets, which Azure Automation rejects' {
        (Get-Command $script:Runbook).ParameterSets.Name | Should -Be '__AllParameterSets'
    }

    It 'requires the ServiceNow and Key Vault values, and neither directory''s' {
        $parameters = (Get-Command $script:Runbook).Parameters
        foreach ($name in 'DomainId', 'Instance', 'VaultName', 'ManagedIdentityClientId', 'ServiceNowUserName') {
            $parameters[$name].Attributes.Where({ $_ -is [Parameter] }).Mandatory | Should -BeTrue -Because "$name reaches ServiceNow"
        }
        foreach ($name in 'TenantId', 'ApplicationId', 'DomainController', 'AdUserName', 'AdSecretName') {
            $parameters[$name].Attributes.Where({ $_ -is [Parameter] }).Mandatory | Should -Not -Contain $true -Because "a domain may not use the directory $name belongs to"
        }
    }
}

Describe 'Test-RmaHealth choice of checks' -Tag 'Unit' {

    BeforeAll {
        Mock Write-RmaLog {}
        Mock Get-RmaAccessToken { 'token' }
        Mock Test-RmaPrerequisite { [pscustomobject]@{ PSTypeName = 'Rma.ServiceNowContext'; Instance = 'contoso' } }
        # An empty queue is the normal state: nothing queues Test-RmaHealth jobs. It comes
        # back as nothing at all, and under StrictMode `$null.Count` throws, which failed
        # the queue check on every run until the call was wrapped in @().
        Mock Get-RmaPendingJob { @() }
        Mock Get-RmaSecret { [pscredential]::new('CONTOSO\svc.rma', [securestring]::new()) }
        Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'contoso.com' } }
    }

    It 'runs the Graph check and not the AD check for a domain with only Entra' {
        $output = & $script:Runbook @script:Common @script:Entra | Out-String

        $output | Should -Match 'Microsoft Graph token exchange'
        $output | Should -Not -Match 'Active Directory reachable'
        Should -Invoke Get-ADDomain -Times 0 -Exactly
    }

    It 'runs the AD check and not the Graph check for a domain with only Active Directory' {
        # The first version made TenantId and ApplicationId mandatory everywhere, so a
        # domain with Entra switched off could not be health-checked at all.
        $output = & $script:Runbook @script:Common @script:ActiveDirectory | Out-String

        $output | Should -Match 'Active Directory reachable'
        $output | Should -Not -Match 'Microsoft Graph token exchange'
        Should -Invoke Get-RmaAccessToken -Times 0 -Exactly -ParameterFilter { $Federated }
    }

    It 'runs both checks when both pairs are passed' {
        $output = & $script:Runbook @script:Common @script:Entra @script:ActiveDirectory | Out-String

        $output | Should -Match 'Microsoft Graph token exchange'
        $output | Should -Match 'Active Directory reachable'
        $output | Should -Match 'All checks passed'
    }

    It 'reads the AD password from the default secret unless told otherwise' {
        $null = & $script:Runbook @script:Common @script:ActiveDirectory
        Should -Invoke Get-RmaSecret -Times 1 -Exactly -ParameterFilter { $Name -eq 'ad-service-account-password' }

        $null = & $script:Runbook @script:Common @script:ActiveDirectory -AdSecretName 'ad-contoso-password'
        Should -Invoke Get-RmaSecret -Times 1 -Exactly -ParameterFilter { $Name -eq 'ad-contoso-password' }
    }
}

Describe 'Test-RmaHealth end to end' -Tag 'Unit' {

    BeforeAll {
        # Every other test here mocks the module's functions, and that is what let the
        # logger put its lines into their return values unnoticed: the first real run
        # failed on $context.BaseUri. Here only the HTTP calls are replaced, and the
        # module, its logger included, runs for real.
        Import-Module RMA.Runbooks -RequiredVersion (Import-PowerShellDataFile (Join-Path $repoRoot 'src/RMA.Runbooks/RMA.Runbooks.psd1')).ModuleVersion -Force
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            switch -Wildcard ($Uri) {
                'http://169.254.169.254/*' { [pscustomobject]@{ access_token = 'mi-token'; expires_on = '4102444800' } }
                'https://*.vault.azure.net/*' { [pscustomobject]@{ value = 'not-a-real-password' } }
                'https://login.microsoftonline.com/*' { [pscustomobject]@{ access_token = 'graph-token'; expires_in = 3600 } }
                'https://*.service-now.com/*' { [pscustomobject]@{ result = @() } }
                default { throw "Unexpected request to $Uri" }
            }
        }
    }

    It 'passes every check when every dependency answers' {
        $output = & $script:Runbook @script:Common @script:Entra 6>$null | Out-String

        $output | Should -Match 'All checks passed'
        $output | Should -Not -Match 'FAIL'
    }
}

Describe 'Test-RmaHealth output' -Tag 'Unit' {

    BeforeAll {
        Mock Write-RmaLog {}
        Mock Get-RmaAccessToken { 'token' }
        Mock Get-RmaPendingJob { @() }
        # Long enough that the old Format-Table output cut it off before the status code,
        # which is how a real Key Vault 403 reached the job pane: "(HTT."
        $KeyVaultError = 'GET https://kv-rma-contoso.vault.azure.net/secrets/servicenow-api-password?api-version=7.4 failed after 1 attempt(s) (HTTP 403): {"error":{"code":"Forbidden","message":"Caller is not authorized to perform action on resource."}}'
        Mock Test-RmaPrerequisite { throw $KeyVaultError }
    }

    It 'prints the whole detail of a failed check' {
        # Collected line by line, because the throw at the end discards an assignment.
        $output = [System.Collections.Generic.List[object]]::new()
        $thrown = $null
        try { & $script:Runbook @script:Common @script:Entra | ForEach-Object { $output.Add($_) } } catch { $thrown = $_ }

        "$thrown" | Should -BeLike 'Health check failed: Key Vault + ServiceNow*'
        ($output | Out-String) | Should -Match ([regex]::Escape($KeyVaultError))
    }

    It 'writes no error record of its own besides the final throw' {
        { $null = & $script:Runbook @script:Common @script:Entra } | Should -Throw
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Error' }
    }
}

Describe 'Test-RmaHealth refusals' -Tag 'Unit' {

    BeforeAll {
        Mock Write-RmaLog {}
        Mock Get-RmaAccessToken { 'token' }
    }

    It 'refuses <Case>, naming the missing half' -ForEach @(
        @{ Case = 'TenantId alone'; Extra = @{ TenantId = '00000000-0000-0000-0000-000000000002' }; Missing = 'ApplicationId' }
        @{ Case = 'ApplicationId alone'; Extra = @{ ApplicationId = '00000000-0000-0000-0000-000000000003' }; Missing = 'TenantId' }
        @{ Case = 'DomainController alone'; Extra = @{ DomainController = 'dc01.contoso.com' }; Missing = 'AdUserName' }
        @{ Case = 'AdUserName alone'; Extra = @{ AdUserName = 'CONTOSO\svc.rma' }; Missing = 'DomainController' }
    ) {
        # Skipping the check instead would report a pass for a directory nobody tested.
        { & $script:Runbook @script:Common @Extra } | Should -Throw "*needs $Missing*"
        Should -Invoke Get-RmaAccessToken -Times 0 -Exactly
    }

    It 'refuses to run with neither directory, since that proves nothing a job depends on' {
        { & $script:Runbook @script:Common } | Should -Throw '*or all four*'
    }

    It 'refuses AdSecretName without the Active Directory pair' {
        { & $script:Runbook @script:Common @script:Entra -AdSecretName 'ad-contoso-password' } |
        Should -Throw '*AdSecretName is used only by the Active Directory check*'
    }
}
