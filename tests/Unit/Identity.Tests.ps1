#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The identity path had no tests at all: Get-RmaImdsToken, Test-RmaPrerequisite,
# Connect-RmaGraph and Connect-RmaExchange were all at 0% line coverage, and they are the
# part CLAUDE.md calls the constraint that governs everything. The coverage floor was met
# entirely on the back of the queue logic.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force

    $script:MiClientId = '11111111-1111-1111-1111-111111111111'
    $script:AppId      = '22222222-2222-2222-2222-222222222222'
    $script:TenantId   = '33333333-3333-3333-3333-333333333333'
    $script:DomainId   = 'abcdef0123456789abcdef0123456789'
}

Describe 'Get-RmaImdsToken' -Tag 'Unit', 'Security' {

    BeforeEach {
        # The sandbox branch is selected by this variable, so every test states which
        # context it is exercising rather than inheriting the runner's environment.
        $env:IDENTITY_ENDPOINT = $null
    }

    AfterAll { $env:IDENTITY_ENDPOINT = $null }

    It 'always sends client_id, so the VM system-assigned identity is not used by mistake' {
        # A Hybrid Worker VM has a system-assigned identity created by the extension as
        # well as the user-assigned one. Omitting client_id silently returns the wrong
        # identity, and the failure surfaces later as an unexplained 403 on Key Vault.
        InModuleScope RMA.Runbooks -Parameters @{ ClientId = $script:MiClientId } {
            param($ClientId)
            Mock Invoke-RestMethod { [pscustomobject]@{ access_token = 'tok'; expires_on = '1900000000' } }

            $null = Get-RmaImdsToken -Resource 'https://vault.azure.net' -ClientId $ClientId

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -like "*169.254.169.254*" -and $Uri -like "*client_id=$ClientId*"
            }
        }
    }

    It 'uses the Automation sandbox endpoint and its header when one is present' {
        $env:IDENTITY_ENDPOINT = 'http://localhost:12345/token'
        $env:IDENTITY_HEADER   = 'sandbox-header'
        try {
            InModuleScope RMA.Runbooks -Parameters @{ ClientId = $script:MiClientId } {
                param($ClientId)
                Mock Invoke-RestMethod { [pscustomobject]@{ access_token = 'tok'; expires_on = '1900000000' } }

                $null = Get-RmaImdsToken -Resource 'https://vault.azure.net' -ClientId $ClientId

                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                    $Uri -like 'http://localhost:12345/token*' -and $Headers['X-IDENTITY-HEADER'] -eq 'sandbox-header'
                }
            }
        } finally {
            $env:IDENTITY_ENDPOINT = $null
            $env:IDENTITY_HEADER   = $null
        }
    }

    It 'reads expires_on as a Unix timestamp even when it arrives as a string' {
        InModuleScope RMA.Runbooks {
            Mock Invoke-RestMethod { [pscustomobject]@{ access_token = 'tok'; expires_on = '1900000000' } }

            $token = Get-RmaImdsToken -Resource 'https://vault.azure.net' -ClientId 'x'

            $token.ExpiresOn | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1900000000).UtcDateTime)
        }
    }

    It 'falls back to a bounded lifetime when the endpoint omits expires_on' {
        InModuleScope RMA.Runbooks {
            Mock Invoke-RestMethod { [pscustomobject]@{ access_token = 'tok' } }

            $token = Get-RmaImdsToken -Resource 'https://vault.azure.net' -ClientId 'x'

            $token.ExpiresOn | Should -BeGreaterThan (Get-Date).ToUniversalTime()
            $token.ExpiresOn | Should -BeLessThan (Get-Date).ToUniversalTime().AddHours(1)
        }
    }

    It 'names the Automation Account identity trap when the request fails' {
        # This is the first thing to check when authentication worked yesterday and does
        # not today, so the message has to say so rather than repeat the HTTP error.
        InModuleScope RMA.Runbooks {
            Mock Invoke-RestMethod { throw 'connection refused' }

            { Get-RmaImdsToken -Resource 'https://vault.azure.net' -ClientId 'x' } |
            Should -Throw '*Automation*managed identity of its own*'
        }
    }
}

Describe 'Get-RmaAccessToken cache isolation' -Tag 'Unit', 'Security' {

    It 'does not hand one tenant the token minted for another' {
        # The key was ParameterSetName|Resource|ManagedIdentityClientId. Two federated
        # calls for the same scope through the same managed identity but different app
        # registrations collided, and the second caller received the first one's token.
        InModuleScope RMA.Runbooks -Parameters @{
            Mi = $script:MiClientId; App = $script:AppId; Tenant = $script:TenantId
        } {
            param($Mi, $App, $Tenant)
            $script:RmaTokenCache = @{}
            Mock Get-RmaImdsToken { [pscustomobject]@{ AccessToken = 'assertion'; ExpiresOn = (Get-Date).AddHours(1) } }
            Mock Invoke-RmaRestMethod {
                [pscustomobject]@{ access_token = "token-for-$($Body.client_id)"; expires_in = 3600 }
            }

            $first  = Get-RmaAccessToken -Federated -Resource 'https://graph.microsoft.com/.default' `
                -ManagedIdentityClientId $Mi -ApplicationId $App -TenantId $Tenant
            $second = Get-RmaAccessToken -Federated -Resource 'https://graph.microsoft.com/.default' `
                -ManagedIdentityClientId $Mi -ApplicationId '99999999-9999-9999-9999-999999999999' -TenantId $Tenant

            $first  | Should -Be "token-for-$App"
            $second | Should -Be 'token-for-99999999-9999-9999-9999-999999999999'
            Should -Invoke Invoke-RmaRestMethod -Times 2 -Exactly
        }
    }

    It 'still reuses the entry when every input is the same' {
        InModuleScope RMA.Runbooks -Parameters @{
            Mi = $script:MiClientId; App = $script:AppId; Tenant = $script:TenantId
        } {
            param($Mi, $App, $Tenant)
            $script:RmaTokenCache = @{}
            Mock Get-RmaImdsToken { [pscustomobject]@{ AccessToken = 'assertion'; ExpiresOn = (Get-Date).AddHours(1) } }
            Mock Invoke-RmaRestMethod { [pscustomobject]@{ access_token = 'tok'; expires_in = 3600 } }

            1..3 | ForEach-Object {
                $null = Get-RmaAccessToken -Federated -Resource 'https://graph.microsoft.com/.default' `
                    -ManagedIdentityClientId $Mi -ApplicationId $App -TenantId $Tenant
            }

            Should -Invoke Invoke-RmaRestMethod -Times 1 -Exactly
        }
    }
}

Describe 'Test-RmaPrerequisite' -Tag 'Unit' {

    BeforeEach {
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Get-RmaAccessToken { 'token' }
        Mock -ModuleName RMA.Runbooks Connect-RmaServiceNow {
            [pscustomobject]@{
                PSTypeName = 'Rma.ServiceNowContext'
                Instance   = 'contoso'
                BaseUri    = 'https://contoso.service-now.com'
                Headers    = @{ Authorization = 'Basic x' }
            }
        }
    }

    It 'returns the context Connect-RmaGraph and Connect-RmaExchange actually read' {
        # Two different context shapes flow through this module under the same parameter
        # name. This is the contract between them: the prerequisite context is the one
        # that carries ManagedIdentityClientId.
        $context = Test-RmaPrerequisite -Instance 'contoso' `
            -VaultName 'kv-rma-test' -ManagedIdentityClientId $script:MiClientId `
            -ServiceNowUserName 'svc-rma'

        $context.ManagedIdentityClientId | Should -Be $script:MiClientId
        $context.BaseUri                 | Should -Be 'https://contoso.service-now.com'
        $context.Headers                 | Should -Not -BeNullOrEmpty
    }

    It 'checks the managed identity before anything that needs the network' {
        # Cheapest check first: a bad identity should fail in under a second, not after
        # a Key Vault round trip.
        Test-RmaPrerequisite -Instance 'contoso' `
            -VaultName 'kv-rma-test' -ManagedIdentityClientId $script:MiClientId `
            -ServiceNowUserName 'svc-rma' | Out-Null

        Should -Invoke -ModuleName RMA.Runbooks Get-RmaAccessToken -Times 1 -Exactly
    }

    It 'points at the Automation Account identity when the managed identity check fails' {
        Mock -ModuleName RMA.Runbooks Get-RmaAccessToken { throw 'no identity endpoint' }

        { Test-RmaPrerequisite -Instance 'contoso' `
                -VaultName 'kv-rma-test' -ManagedIdentityClientId $script:MiClientId `
                -ServiceNowUserName 'svc-rma' } |
        Should -Throw '*Automation*managed identity enabled*'

        Should -Invoke -ModuleName RMA.Runbooks Connect-RmaServiceNow -Times 0 -Exactly
    }

    It 'reads nothing from ServiceNow beyond the authentication check' {
        # Every configuration value arrives as a runbook parameter. The domain record used
        # to be fetched here; a REST call from this function now means that came back.
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { throw 'unexpected ServiceNow call' }

        { Test-RmaPrerequisite -Instance 'contoso' `
                -VaultName 'kv-rma-test' -ManagedIdentityClientId $script:MiClientId `
                -ServiceNowUserName 'svc-rma' } | Should -Not -Throw

        Should -Invoke -ModuleName RMA.Runbooks Invoke-RmaRestMethod -Times 0 -Exactly
    }
}

Describe 'Context typing' -Tag 'Unit' {

    # Two shapes used to flow through this module under one parameter name and one type.
    # Passing the wrong one surfaced as a property-not-found somewhere far from the call.
    BeforeAll {
        $script:ServiceNowOnly = [pscustomobject]@{
            PSTypeName = 'Rma.ServiceNowContext'
            Instance   = 'contoso'
            BaseUri    = 'https://contoso.service-now.com'
            Headers    = @{}
        }
        $script:Full = [pscustomobject]@{
            PSTypeName              = 'Rma.Context'
            Instance                = 'contoso'
            BaseUri                 = 'https://contoso.service-now.com'
            Headers                 = @{}
            ManagedIdentityClientId = $script:MiClientId
        }
        $script:Full.PSObject.TypeNames.Insert(1, 'Rma.ServiceNowContext')
    }

    It 'refuses the ServiceNow context where the full context is required' {
        { Connect-RmaGraph -Context $script:ServiceNowOnly -TenantId $script:TenantId -ApplicationId $script:AppId } |
        Should -Throw '*Rma.Context*'
    }

    It 'accepts the full context where only the ServiceNow one is required' {
        # Test-RmaPrerequisite returns the full context and the runbooks hand it straight
        # to the queue functions, so this has to keep working.
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ result = @() } }

        { Get-RmaPendingJob -Context $script:Full -DomainId $script:DomainId -Command 'Create-EntraUser' } |
        Should -Not -Throw
    }

    It 'gives Test-RmaPrerequisite output both names' {
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Get-RmaAccessToken { 'token' }
        Mock -ModuleName RMA.Runbooks Connect-RmaServiceNow {
            [pscustomobject]@{ PSTypeName = 'Rma.ServiceNowContext'; Instance = 'contoso'
                BaseUri = 'https://contoso.service-now.com'; Headers = @{}
            }
        }

        $context = Test-RmaPrerequisite -Instance 'contoso' `
            -VaultName 'kv-rma-test' -ManagedIdentityClientId $script:MiClientId `
            -ServiceNowUserName 'svc-rma'

        $context.PSObject.TypeNames | Should -Contain 'Rma.Context'
        $context.PSObject.TypeNames | Should -Contain 'Rma.ServiceNowContext'
    }
}

Describe 'Connect-RmaGraph' -Tag 'Unit', 'Security' {

    BeforeAll {
        $script:GraphContext = [pscustomobject]@{
            PSTypeName              = 'Rma.Context'
            ManagedIdentityClientId = $script:MiClientId
        }
    }

    It 'tells you which module to declare when it is missing' -Skip:([bool](Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        { Connect-RmaGraph -Context $script:GraphContext -TenantId $script:TenantId -ApplicationId $script:AppId } |
        Should -Throw '*Microsoft.Graph.Authentication is not available*'
    }

    Context 'when Microsoft.Graph.Authentication is present' {
        BeforeAll {
            # Stand-in for the real cmdlet so the function under test is reachable on a
            # runner that has no Graph SDK installed.
            function global:Connect-MgGraph {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock ParameterFilter can bind them; a stub has no body to read them in.')]
                param($AccessToken, [switch] $NoWelcome)
            }
        }
        AfterAll { Remove-Item function:global:Connect-MgGraph -ErrorAction SilentlyContinue }

        BeforeEach {
            Mock -ModuleName RMA.Runbooks Write-RmaLog {}
            Mock -ModuleName RMA.Runbooks Connect-MgGraph {}
            Mock -ModuleName RMA.Runbooks Get-RmaAccessToken { 'federated-token' }
        }

        It 'exchanges the managed identity token for an app token in the given tenant' {
            Connect-RmaGraph -Context $script:GraphContext -TenantId $script:TenantId -ApplicationId $script:AppId

            Should -Invoke -ModuleName RMA.Runbooks Get-RmaAccessToken -Times 1 -Exactly -ParameterFilter {
                $Federated -and
                $ApplicationId -eq $script:AppId -and
                $TenantId -eq $script:TenantId -and
                $ManagedIdentityClientId -eq $script:MiClientId -and
                $Resource -eq 'https://graph.microsoft.com/.default'
            }
        }

        It 'rejects a tenant id that is not a GUID before requesting any token' {
            # The tenant used to be read from the domain record, where a display name in
            # the field only failed at token exchange. As a parameter it fails at binding.
            { Connect-RmaGraph -Context $script:GraphContext -TenantId 'contoso.onmicrosoft.com' -ApplicationId $script:AppId } |
            Should -Throw

            Should -Invoke -ModuleName RMA.Runbooks Get-RmaAccessToken -Times 0 -Exactly
        }

        It 'hands Graph a SecureString, never the raw token' {
            Connect-RmaGraph -Context $script:GraphContext -TenantId $script:TenantId -ApplicationId $script:AppId

            Should -Invoke -ModuleName RMA.Runbooks Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
                $AccessToken -is [securestring]
            }
        }
    }
}

Describe 'Connect-RmaExchange' -Tag 'Unit', 'Security' {

    BeforeAll {
        $script:ExoContext = [pscustomobject]@{
            PSTypeName              = 'Rma.Context'
            ManagedIdentityClientId = $script:MiClientId
        }
    }

    It 'tells you which module to declare when it is missing' -Skip:([bool](Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        { Connect-RmaExchange -Context $script:ExoContext -TenantId $script:TenantId -ApplicationId $script:AppId -Organization 'contoso.onmicrosoft.com' } |
        Should -Throw '*ExchangeOnlineManagement is not available*'
    }

    Context 'when ExchangeOnlineManagement is present' {
        BeforeAll {
            function global:Connect-ExchangeOnline {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock ParameterFilter can bind them; a stub has no body to read them in.')]
                param($AccessToken, $Organization, [switch] $ShowBanner)
            }
        }
        AfterAll { Remove-Item function:global:Connect-ExchangeOnline -ErrorAction SilentlyContinue }

        BeforeEach {
            Mock -ModuleName RMA.Runbooks Write-RmaLog {}
            Mock -ModuleName RMA.Runbooks Connect-ExchangeOnline {}
            Mock -ModuleName RMA.Runbooks Get-RmaAccessToken { 'federated-token' }
        }

        It 'requests the Outlook scope, not the Graph one' {
            Connect-RmaExchange -Context $script:ExoContext -TenantId $script:TenantId -ApplicationId $script:AppId `
                -Organization 'contoso.onmicrosoft.com'

            Should -Invoke -ModuleName RMA.Runbooks Get-RmaAccessToken -Times 1 -Exactly -ParameterFilter {
                $Resource -eq 'https://outlook.office365.com/.default' -and $Federated
            }
        }

        It 'rejects an organization that is not an onmicrosoft.com tenant name' {
            { Connect-RmaExchange -Context $script:ExoContext -TenantId $script:TenantId -ApplicationId $script:AppId `
                    -Organization 'contoso.com' } | Should -Throw
        }
    }
}
