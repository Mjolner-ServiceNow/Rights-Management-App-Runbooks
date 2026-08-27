#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    $script:Context = [pscustomobject]@{
        Instance = 'contoso'
        BaseUri  = 'https://contoso.service-now.com'
        Headers  = @{ Authorization = 'Basic x' }
    }
    $script:DomainId = 'abcdef0123456789abcdef0123456789'
    $script:SysId    = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'
}

Describe 'Get-RmaProperty' -Tag 'Unit' {
    It 'returns the value when the property exists' {
        InModuleScope RMA.Runbooks {
            Get-RmaProperty -InputObject ([pscustomobject]@{ a = 1 }) -Name 'a' | Should -Be 1
        }
    }
    It 'returns null instead of throwing when it does not' {
        InModuleScope RMA.Runbooks {
            # This is the whole point: Set-StrictMode -Version Latest makes a direct
            # read throw, which previously turned a retryable HTTP failure into a hard one.
            { Get-RmaProperty -InputObject ([pscustomobject]@{ a = 1 }) -Name 'missing' } | Should -Not -Throw
            Get-RmaProperty -InputObject ([pscustomobject]@{ a = 1 }) -Name 'missing' | Should -BeNullOrEmpty
        }
    }
    It 'handles a null input and a hashtable' {
        InModuleScope RMA.Runbooks {
            Get-RmaProperty -InputObject $null -Name 'a'          | Should -BeNullOrEmpty
            Get-RmaProperty -InputObject @{ k = 'v' } -Name 'k'   | Should -Be 'v'
            Get-RmaProperty -InputObject @{ k = 'v' } -Name 'nope' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-RmaSafeLogValue' -Tag 'Unit', 'Security' {
    It 'redacts at depth and preserves non-secrets' {
        InModuleScope RMA.Runbooks {
            $result = ConvertTo-RmaSafeLogValue -InputObject @{
                user = @{ name = 'jane'; password = 'p' }
                list = @(@{ token = 't' }, @{ ok = 'keep' })
            }
            $result.user.name    | Should -Be 'jane'
            $result.user.password | Should -Be '<redacted>'
            $result.list[0].token | Should -Be '<redacted>'
            $result.list[1].ok    | Should -Be 'keep'
        }
    }
    It 'terminates on a deeply nested structure' {
        InModuleScope RMA.Runbooks {
            $deep = @{ v = 'x' }
            1..20 | ForEach-Object { $deep = @{ nested = $deep } }
            { ConvertTo-RmaSafeLogValue -InputObject $deep } | Should -Not -Throw
        }
    }
}

Describe 'Set-RmaJobState' -Tag 'Unit' {
    BeforeEach { Mock -ModuleName RMA.Runbooks Write-RmaLog {} }

    It 'maps each state to the correct ServiceNow status code' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            $script:lastBody = $Body
            [pscustomobject]@{ result = [pscustomobject]@{} }
        }
        foreach ($pair in @{ 'Pending' = '1'; 'Work in Progress' = '2'; 'Failed' = '3'; 'Completed' = '4' }.GetEnumerator()) {
            Set-RmaJobState -Context $script:Context -SysId $script:SysId -State $pair.Key
            ($script:lastBody | ConvertFrom-Json).status | Should -Be $pair.Value -Because "state '$($pair.Key)'"
        }
    }

    It 'truncates an over-long exception so the update itself does not fail' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            $script:lastBody = $Body; [pscustomobject]@{ result = [pscustomobject]@{} }
        }
        Set-RmaJobState -Context $script:Context -SysId $script:SysId -State 'Failed' -ExceptionMessage ('x' * 9000)
        $sent = ($script:lastBody | ConvertFrom-Json).exception
        $sent.Length | Should -Be 4000
        $sent        | Should -Match '\.\.\.$'
    }

    It 'omits the exception field when there is no message' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            $script:lastBody = $Body; [pscustomobject]@{ result = [pscustomobject]@{} }
        }
        Set-RmaJobState -Context $script:Context -SysId $script:SysId -State 'Completed'
        ($script:lastBody | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'exception'
    }

    It 'rethrows so the caller knows the job is now stranded' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { throw 'gateway timeout' }
        { Set-RmaJobState -Context $script:Context -SysId $script:SysId -State 'Completed' } |
        Should -Throw -ExpectedMessage '*Unable to set ServiceNow job*'
    }
}

Describe 'Get-RmaDomainConfig' -Tag 'Unit' {
    BeforeEach { Mock -ModuleName RMA.Runbooks Write-RmaLog {} }

    It 'flattens display_value objects and trims' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            [pscustomobject]@{ result = [pscustomobject]@{
                    tenant_azure_active_directory = '  contoso-tenant-id  '
                    applicationid                 = 'app-id'
                    forest_name                   = [pscustomobject]@{ display_value = 'contoso.local' }
                    domain_controller_ip          = '10.0.0.4'
                } 
            }
        }
        $config = Get-RmaDomainConfig -Context $script:Context -DomainId $script:DomainId
        $config.TenantId   | Should -Be 'contoso-tenant-id'
        $config.ForestName | Should -Be 'contoso.local'
    }

    It 'throws when the record does not exist' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ result = $null } }
        { Get-RmaDomainConfig -Context $script:Context -DomainId $script:DomainId } |
        Should -Throw -ExpectedMessage '*was not found*'
    }

    It 'names every missing required field in one message' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            [pscustomobject]@{ result = [pscustomobject]@{ forest_name = 'contoso.local' } }
        }
        { Get-RmaDomainConfig -Context $script:Context -DomainId $script:DomainId -Require @('TenantId', 'DomainControllerIp') } |
        Should -Throw -ExpectedMessage '*TenantId, DomainControllerIp*'
    }

    It 'treats whitespace as missing' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            [pscustomobject]@{ result = [pscustomobject]@{ tenant_azure_active_directory = '   ' } }
        }
        { Get-RmaDomainConfig -Context $script:Context -DomainId $script:DomainId -Require @('TenantId') } |
        Should -Throw
    }
}

Describe 'Get-RmaPendingJob' -Tag 'Unit' {
    It 'filters on the command and on status Pending' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            $script:uri = $Uri
            [pscustomobject]@{ result = @([pscustomobject]@{ sys_id = 'x' }) }
        }
        $null = Get-RmaPendingJob -Context $script:Context -DomainId $script:DomainId -Command 'Create-EntraUser'
        [uri]::UnescapeDataString($script:uri) | Should -Match 'command=Create-EntraUser'
        [uri]::UnescapeDataString($script:uri) | Should -Match 'status=1'
        [uri]::UnescapeDataString($script:uri) | Should -Match 'ORDERBYsys_created_on'
    }
    It 'returns an empty array, not null, when the queue is empty' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ result = @() } }
        $jobs = Get-RmaPendingJob -Context $script:Context -DomainId $script:DomainId -Command 'Create-EntraUser'
        @($jobs).Count | Should -Be 0
    }
    It 'rejects a command name that could inject into the query' {
        { Get-RmaPendingJob -Context $script:Context -DomainId $script:DomainId -Command 'evil^status=4' } |
        Should -Throw
    }
}

Describe 'Get-RmaSecret' -Tag 'Unit', 'Security' {
    BeforeEach {
        Mock -ModuleName RMA.Runbooks Get-RmaAccessToken { 'fake-token' }
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ value = 'sn-password' } }
    }
    It 'returns a SecureString by default' {
        $secret = Get-RmaSecret -VaultName 'kv-rma-prod' -Name 'servicenow-api-password' -ManagedIdentityClientId 'mi'
        $secret | Should -BeOfType [securestring]
    }
    It 'builds a PSCredential when asked' {
        $cred = Get-RmaSecret -VaultName 'kv-rma-prod' -Name 'ad-service-account' -ManagedIdentityClientId 'mi' `
            -AsCredential -UserName 'CONTOSO\svc-rma'
        $cred | Should -BeOfType [pscredential]
        $cred.UserName | Should -Be 'CONTOSO\svc-rma'
        $cred.GetNetworkCredential().Password | Should -Be 'sn-password'
    }
    It 'throws on an empty secret rather than returning a blank credential' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ value = '' } }
        { Get-RmaSecret -VaultName 'kv-rma-prod' -Name 'empty' -ManagedIdentityClientId 'mi' } |
        Should -Throw -ExpectedMessage '*is empty*'
    }
    It 'rejects a vault name that is not a valid Azure resource name' {
        { Get-RmaSecret -VaultName 'not a vault!' -Name 'x' -ManagedIdentityClientId 'mi' } | Should -Throw
    }
}

Describe 'Get-RmaAccessToken caching' -Tag 'Unit', 'Reliability' {
    It 'reuses a cached token instead of re-minting on every call' {
        InModuleScope RMA.Runbooks {
            $script:RmaTokenCache = @{}
            Mock Get-RmaImdsToken {
                [pscustomobject]@{ AccessToken = 'tok'; ExpiresOn = (Get-Date).ToUniversalTime().AddHours(1); Resource = $Resource }
            }
            1..5 | ForEach-Object { $null = Get-RmaAccessToken -Resource 'https://vault.azure.net' -ManagedIdentityClientId 'mi' }
            Should -Invoke Get-RmaImdsToken -Times 1 -Exactly
        }
    }
    It 're-mints when the cached token is inside the five minute expiry margin' {
        InModuleScope RMA.Runbooks {
            $script:RmaTokenCache = @{}
            Mock Get-RmaImdsToken {
                # The long-running queue loop must not carry a token to expiry mid-job.
                [pscustomobject]@{ AccessToken = 'tok'; ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(2); Resource = $Resource }
            }
            1..3 | ForEach-Object { $null = Get-RmaAccessToken -Resource 'https://vault.azure.net' -ManagedIdentityClientId 'mi' }
            Should -Invoke Get-RmaImdsToken -Times 3 -Exactly
        }
    }
}

Describe 'Connect-RmaServiceNow' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Get-RmaSecret { 'sn-password' }
    }
    It 'builds a basic auth header and verifies it works' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ result = @() } }
        $ctx = Connect-RmaServiceNow -Instance 'contoso' -VaultName 'kv-rma-prod' `
            -UserName 'svc' -SecretName 'sn' -ManagedIdentityClientId 'mi'
        $ctx.BaseUri | Should -Be 'https://contoso.service-now.com'
        $ctx.Headers.Authorization | Should -Match '^Basic '
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($ctx.Headers.Authorization -split ' ')[1])) |
        Should -Be 'svc:sn-password'
    }
    It 'fails with an actionable message when the credential is wrong' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { throw '401 Unauthorized' }
        { Connect-RmaServiceNow -Instance 'contoso' -VaultName 'kv-rma-prod' `
                -UserName 'svc' -SecretName 'sn' -ManagedIdentityClientId 'mi' } |
        Should -Throw -ExpectedMessage '*authentication check failed*'
    }
}
