#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Graph and Exchange keep the token they were connected with, so a run that outlived it
# failed part-way through (#30). These tests cover the expiry read from the token, the
# registration in Connect-RmaGraph and Connect-RmaExchange, the renewal in
# Update-RmaConnection, and the call from Invoke-RmaQueueLoop before every job.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force

    $script:MiClientId = '11111111-1111-1111-1111-111111111111'
    $script:AppId      = '22222222-2222-2222-2222-222222222222'
    $script:TenantId   = '33333333-3333-3333-3333-333333333333'
    $script:Context    = [pscustomobject]@{ PSTypeName = 'Rma.Context'; ManagedIdentityClientId = $script:MiClientId }

    # An unsigned JWT that expires a given number of minutes from now. Only exp is read.
    function New-TestJwt {
        param([int] $ExpiresInMinutes)
        $encode = { param($Text) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $exp = [DateTimeOffset]::UtcNow.AddMinutes($ExpiresInMinutes).ToUnixTimeSeconds()
        '{0}.{1}.sig' -f (& $encode '{"alg":"none"}'), (& $encode "{`"exp`":$exp,`"aud`":`"x`"}")
    }

    # Stand-ins for cmdlets a runner may not have installed, so Mock has something to replace.
    function global:Connect-MgGraph {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($AccessToken, [switch] $NoWelcome)
    }
    function global:Connect-ExchangeOnline {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($AccessToken, $Organization, [switch] $ShowBanner)
    }
    function global:Invoke-MgGraphRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Method, $Uri)
    }
    function global:Disconnect-ExchangeOnline {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)] param()
        $null = $PSCmdlet.ShouldProcess('Exchange Online session', 'Disconnect')
    }
}

AfterAll {
    Remove-Item -Path Function:\Connect-MgGraph, Function:\Connect-ExchangeOnline, Function:\Disconnect-ExchangeOnline,
    Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
}

Describe 'Get-RmaTokenExpiry' -Tag 'Unit', 'Reliability' {

    It 'reads the expiry from the token''s exp claim' {
        $token = New-TestJwt -ExpiresInMinutes 70
        $expiry = InModuleScope RMA.Runbooks -Parameters @{ Token = $token } { param($Token) Get-RmaTokenExpiry -AccessToken $Token }

        $expiry.Kind | Should -Be 'Utc'
        ($expiry - (Get-Date).ToUniversalTime()).TotalMinutes | Should -BeGreaterThan 68
        ($expiry - (Get-Date).ToUniversalTime()).TotalMinutes | Should -BeLessThan 71
    }

    It 'falls back to a short expiry for <Case>' -ForEach @(
        @{ Case = 'a token that is not a JWT'; Token = 'opaque-token' }
        @{ Case = 'a payload that is not base64'; Token = 'a.%%%.c' }
        @{ Case = 'a payload with no exp'; Token = 'eyJhbGciOiJub25lIn0.eyJhdWQiOiJ4In0.sig' }
    ) {
        $expiry = InModuleScope RMA.Runbooks -Parameters @{ Token = $Token } { param($Token) Get-RmaTokenExpiry -AccessToken $Token }

        # Earlier than Entra's shortest default lifetime: renewed too early, never too late.
        ($expiry - (Get-Date).ToUniversalTime()).TotalMinutes | Should -BeGreaterThan 54
        ($expiry - (Get-Date).ToUniversalTime()).TotalMinutes | Should -BeLessThan 56
    }
}

Describe 'Update-RmaConnection' -Tag 'Unit', 'Reliability' {

    BeforeEach {
        InModuleScope RMA.Runbooks { $script:RmaSessions.Clear() }
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Connect-MgGraph {}
        Mock -ModuleName RMA.Runbooks Connect-ExchangeOnline {}
        Mock -ModuleName RMA.Runbooks Disconnect-ExchangeOnline {}
        $script:NextTokenMinutes = 70
        Mock -ModuleName RMA.Runbooks Get-RmaAccessToken { New-TestJwt -ExpiresInMinutes $script:NextTokenMinutes }
    }

    It 'does nothing when no connection was made' {
        Update-RmaConnection

        Should -Invoke -ModuleName RMA.Runbooks Get-RmaAccessToken -Times 0 -Exactly
    }

    It 'registers the Graph connection with the token''s expiry' {
        Connect-RmaGraph -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId

        $session = InModuleScope RMA.Runbooks { $script:RmaSessions['Graph'] }
        ($session.ExpiresOn - (Get-Date).ToUniversalTime()).TotalMinutes | Should -BeGreaterThan 68
        $session.Parameters.TenantId | Should -Be $script:TenantId
    }

    It 'leaves a connection alone while its token has time left' {
        Connect-RmaGraph -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId

        Update-RmaConnection

        Should -Invoke -ModuleName RMA.Runbooks Connect-MgGraph -Times 1 -Exactly
    }

    It 'reconnects Graph with a newly minted token when the old one is about to expire' {
        $script:NextTokenMinutes = 10
        Connect-RmaGraph -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId
        $script:NextTokenMinutes = 70

        Update-RmaConnection

        Should -Invoke -ModuleName RMA.Runbooks Connect-MgGraph -Times 2 -Exactly
        # Without -Force the cache would hand back the token that is about to expire.
        Should -Invoke -ModuleName RMA.Runbooks Get-RmaAccessToken -Times 1 -Exactly -ParameterFilter { $Force }
        $session = InModuleScope RMA.Runbooks { $script:RmaSessions['Graph'] }
        ($session.ExpiresOn - (Get-Date).ToUniversalTime()).TotalMinutes | Should -BeGreaterThan 68
    }

    It 'renews within the margin it is given' {
        $script:NextTokenMinutes = 30
        Connect-RmaGraph -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId

        Update-RmaConnection
        Should -Invoke -ModuleName RMA.Runbooks Connect-MgGraph -Times 1 -Exactly

        Update-RmaConnection -MinimumValidityMinutes 45
        Should -Invoke -ModuleName RMA.Runbooks Connect-MgGraph -Times 2 -Exactly
    }

    It 'closes the old Exchange session before opening a new one' {
        $script:NextTokenMinutes = 5
        Connect-RmaExchange -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId -Organization 'contoso.onmicrosoft.com'
        Should -Invoke -ModuleName RMA.Runbooks Disconnect-ExchangeOnline -Times 0 -Exactly

        Update-RmaConnection

        # A second Connect-ExchangeOnline would open a second session beside the first.
        Should -Invoke -ModuleName RMA.Runbooks Disconnect-ExchangeOnline -Times 1 -Exactly
        Should -Invoke -ModuleName RMA.Runbooks Connect-ExchangeOnline -Times 2 -Exactly -ParameterFilter {
            $Organization -eq 'contoso.onmicrosoft.com'
        }
    }

    It 'renews only the connection that is about to expire' {
        $script:NextTokenMinutes = 70
        Connect-RmaGraph -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId
        $script:NextTokenMinutes = 5
        Connect-RmaExchange -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId -Organization 'contoso.onmicrosoft.com'

        Update-RmaConnection

        Should -Invoke -ModuleName RMA.Runbooks Connect-MgGraph -Times 1 -Exactly
        Should -Invoke -ModuleName RMA.Runbooks Connect-ExchangeOnline -Times 2 -Exactly
    }

    It 'does not reconnect under -WhatIf' {
        $script:NextTokenMinutes = 5
        Connect-RmaGraph -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId

        Update-RmaConnection -WhatIf

        Should -Invoke -ModuleName RMA.Runbooks Connect-MgGraph -Times 1 -Exactly
    }
}

Describe 'Invoke-RmaQueueLoop renews connections' -Tag 'Unit', 'Reliability' {

    BeforeAll {
        $script:LoopContext = [pscustomobject]@{
            PSTypeName = 'Rma.ServiceNowContext'; Instance = 'contoso'; BaseUri = 'https://contoso.service-now.com'; Headers = @{}
        }
        function New-LoopJob {
            param([string] $SysId)
            [pscustomobject]@{
                sys_id = $SysId
                input  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ action = 'Create-EntraUser' } | ConvertTo-Json)))
            }
        }
    }

    BeforeEach {
        $script:States = [System.Collections.Generic.List[object]]::new()
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
        Mock -ModuleName RMA.Runbooks Set-RmaJobState { $script:States.Add([pscustomobject]@{ State = $State; Error = $ExceptionMessage }) }
        $script:Jobs = @((New-LoopJob -SysId ('a' * 32)), (New-LoopJob -SysId ('b' * 32)))
        $script:Served = $false
        Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { if ($script:Served) { @() } else { $script:Served = $true; $script:Jobs } }
    }

    It 'renews before every job, before the body runs' {
        Mock -ModuleName RMA.Runbooks Update-RmaConnection { $script:Order.Add('renew') }

        $result = Invoke-RmaQueueLoop -Context $script:LoopContext -DomainId ('f' * 32) -Command 'Create-EntraUser' `
            -Body { $script:Order.Add('body') }

        $result.Succeeded | Should -Be 2
        $script:Order -join ',' | Should -Be 'renew,body,renew,body'
    }

    It 'fails the job with the reason when a connection cannot be renewed' {
        Mock -ModuleName RMA.Runbooks Update-RmaConnection { throw 'token exchange failed' }

        $result = Invoke-RmaQueueLoop -Context $script:LoopContext -DomainId ('f' * 32) -Command 'Create-EntraUser' `
            -Body { $script:Order.Add('body') }

        $result.Failed | Should -Be 2
        $script:Order.Count | Should -Be 0
        $script:States[0].Error | Should -Match 'token exchange failed'
    }
}

Describe 'Connect-RmaExchange without -Organization (#102)' -Tag 'Unit' {

    BeforeEach {
        InModuleScope RMA.Runbooks { $script:RmaSessions.Clear() }
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Connect-ExchangeOnline {}
        Mock -ModuleName RMA.Runbooks Get-RmaAccessToken { New-TestJwt -ExpiresInMinutes 70 }
    }

    It 'connects to the tenant''s initial domain, read from Graph, and keeps it for renewals' {
        # docs/DECISIONS.md D20: the domain record needs no field for it.
        Mock -ModuleName RMA.Runbooks Invoke-MgGraphRequest {
            @{ value = @(
                    @{ id = 'contoso.com'; isInitial = $false }
                    @{ id = 'contoso.onmicrosoft.com'; isInitial = $true }
                ) 
            }
        }

        Connect-RmaExchange -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId

        Should -Invoke -ModuleName RMA.Runbooks Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -like 'v1.0/domains*'
        }
        Should -Invoke -ModuleName RMA.Runbooks Connect-ExchangeOnline -Times 1 -Exactly -ParameterFilter {
            $Organization -eq 'contoso.onmicrosoft.com'
        }
        InModuleScope RMA.Runbooks { $script:RmaSessions['Exchange'].Parameters.Organization } | Should -Be 'contoso.onmicrosoft.com'
    }

    It 'asks Graph nothing when -Organization is given' {
        Mock -ModuleName RMA.Runbooks Invoke-MgGraphRequest { throw 'not expected' }

        Connect-RmaExchange -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId -Organization 'contoso.onmicrosoft.com'

        Should -Invoke -ModuleName RMA.Runbooks Invoke-MgGraphRequest -Times 0 -Exactly
    }

    It 'refuses to connect when Graph does not return exactly one initial domain: <Case>' -ForEach @(
        @{ Case = 'none'; Domains = @(@{ id = 'contoso.com'; isInitial = $false }) }
        @{ Case = 'not onmicrosoft.com'; Domains = @(@{ id = 'contoso.com'; isInitial = $true }) }
    ) {
        Mock -ModuleName RMA.Runbooks Invoke-MgGraphRequest { @{ value = $Domains } }

        { Connect-RmaExchange -Context $script:Context -TenantId $script:TenantId -ApplicationId $script:AppId } |
        Should -Throw '*initial domain*'
        Should -Invoke -ModuleName RMA.Runbooks Connect-ExchangeOnline -Times 0 -Exactly
    }
}
