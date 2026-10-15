#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the
# three Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Disable-RevokeSignInTokens.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Get-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, [string[]] $Property)
    }
    function global:Update-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, [switch] $AccountEnabled)
    }
    function global:Revoke-MgUserSignInSession {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId)
    }

    # What the Graph SDK throws for a 404: a plain exception, told apart only by the error id.
    $script:NotFound = [System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new("[Request_ResourceNotFound] : Resource 'nobody@contoso.com' does not exist."),
        'Request_ResourceNotFound,Microsoft.Graph.PowerShell.Cmdlets.GetMgUser_Get',
        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
}

AfterAll {
    Remove-Item -Path Function:\Get-MgUser, Function:\Update-MgUser, Function:\Revoke-MgUserSignInSession -ErrorAction SilentlyContinue
}

Describe 'Disable-RevokeSignInTokens' -Tag 'Unit' {

    BeforeEach {
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:UserObjectId = '44444444-4444-4444-4444-444444444444'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Update-MgUser {}
        Mock Revoke-MgUserSignInSession { $true }
        # Graph answers null, not false, for a user who was never synchronised.
        Mock Get-MgUser {
            [pscustomobject]@{ Id = $script:UserObjectId; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $true; OnPremisesSyncEnabled = $null }
        }
    }

    It 'handles the Revoke-SignInTokens command' {
        $script:Command | Should -Be 'Revoke-SignInTokens'
    }

    It 'disables an enabled user and then revokes their sessions, both by object id' {
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock Update-MgUser { $script:Order.Add('disable') }
        Mock Revoke-MgUserSignInSession { $script:Order.Add('revoke'); $true }

        & $script:Body $script:Job ([pscustomobject]@{ action = 'Revoke-SignInTokens'; user = ' jdoe@contoso.com ' })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter {
            $UserId -eq 'jdoe@contoso.com' -and 'accountEnabled' -in $Property -and 'id' -in $Property -and
            'onPremisesSyncEnabled' -in $Property
        }
        Should -Invoke Update-MgUser -Times 1 -Exactly -ParameterFilter {
            $UserId -eq $script:UserObjectId -and $PesterBoundParameters.ContainsKey('AccountEnabled') -and -not $AccountEnabled
        }
        Should -Invoke Revoke-MgUserSignInSession -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:UserObjectId }
        $script:Order -join ',' | Should -Be 'disable,revoke'

        $script:Logged.Message | Should -Be @('Entra user disabled', 'Entra user sign-in sessions revoked')
        $script:Logged[-1].Data.userPrincipalName | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.id | Should -Be $script:UserObjectId
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'accepts an object id as the user' {
        & $script:Body $script:Job ([pscustomobject]@{ user = $script:UserObjectId })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:UserObjectId }
        Should -Invoke Revoke-MgUserSignInSession -Times 1 -Exactly
    }

    It 'revokes the sessions of a user who is already disabled, without updating them, and completes' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:UserObjectId; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $false; OnPremisesSyncEnabled = $null } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Update-MgUser -Times 0 -Exactly
        Should -Invoke Revoke-MgUserSignInSession -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:UserObjectId }
        $script:Logged[0].Message | Should -Match 'already disabled'
        $script:Logged[-1].Message | Should -Be 'Entra user sign-in sessions revoked'
    }

    It 'disables a cloud-only user whose onPremisesSyncEnabled is false, before revoking' {
        Mock Get-MgUser {
            [pscustomobject]@{ Id = $script:UserObjectId; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $true; OnPremisesSyncEnabled = $false }
        }
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock Update-MgUser { $script:Order.Add('disable') }
        Mock Revoke-MgUserSignInSession { $script:Order.Add('revoke'); $true }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        $script:Order -join ',' | Should -Be 'disable,revoke'
    }

    Context 'a user synchronised from on-premises AD' {

        BeforeEach {
            Mock Get-MgUser {
                [pscustomobject]@{ Id = $script:UserObjectId; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $true; OnPremisesSyncEnabled = $true }
            }
        }

        It 'revokes the sessions, never disables, and then fails naming Disable-ADUser' {
            { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
            Should -Throw "The sign-in sessions of Entra ID user 'jdoe@contoso.com' were revoked, but the account is synchronised from on-premises Active Directory and was not disabled. Disable it there with Disable-ADUser."

            Should -Invoke Revoke-MgUserSignInSession -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:UserObjectId }
            Should -Invoke Update-MgUser -Times 0 -Exactly
            $script:Logged[0].Level | Should -Be 'Warning'
            $script:Logged[0].Message | Should -Match 'synchronised from on-premises AD'
            $script:Logged[-1].Message | Should -Be 'Entra user sign-in sessions revoked'
        }

        It 'fails with Graph''s error, not the revoked message, when the revoke fails' {
            Mock Revoke-MgUserSignInSession { throw '[Authorization_RequestDenied] : Insufficient privileges to complete the operation.' }

            $thrown = { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Throw -PassThru
            $thrown.Exception.Message | Should -BeLike '*Insufficient privileges*'
            $thrown.Exception.Message | Should -Not -BeLike '*were revoked*'
            Should -Invoke Update-MgUser -Times 0 -Exactly
            $script:Logged.Message | Should -Not -Contain 'Entra user sign-in sessions revoked'
        }

        It 'revokes the sessions and completes when the user is already disabled' {
            Mock Get-MgUser {
                [pscustomobject]@{ Id = $script:UserObjectId; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $false; OnPremisesSyncEnabled = $true }
            }

            { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Not -Throw

            Should -Invoke Update-MgUser -Times 0 -Exactly
            Should -Invoke Revoke-MgUserSignInSession -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:UserObjectId }
            $script:Logged[0].Message | Should -Match 'already disabled'
        }
    }

    It 'asks the loop to run it again, with an actionable reason, when the user is not found' {
        Mock Get-MgUser { throw $script:NotFound }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody@contoso.com' }) } |
        Should -Throw "No Entra ID user 'nobody@contoso.com' in the tenant*" -ErrorId 'RmaJobRetry,*'
        Should -Invoke Update-MgUser -Times 0 -Exactly
        Should -Invoke Revoke-MgUserSignInSession -Times 0 -Exactly
    }

    It 'passes any other lookup error through unchanged' {
        Mock Get-MgUser { throw '[Authorization_RequestDenied] : Insufficient privileges to complete the operation.' }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
        Should -Throw '*Insufficient privileges*'
        Should -Invoke Revoke-MgUserSignInSession -Times 0 -Exactly
    }

    It 'does not revoke when disabling fails, and passes the error through' {
        Mock Update-MgUser { throw '[Authorization_RequestDenied] : Insufficient privileges to complete the operation.' }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
        Should -Throw '*Insufficient privileges*'
        Should -Invoke Revoke-MgUserSignInSession -Times 0 -Exactly
    }

    It 'passes a revoke error through unchanged' {
        Mock Revoke-MgUserSignInSession { throw '[TooManyRequests] : Too many requests.' }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Throw '*Too many requests*'
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing user field'; Payload = [pscustomobject]@{ action = 'Revoke-SignInTokens' } }
        @{ Case = 'an empty user'; Payload = [pscustomobject]@{ user = '   ' } }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ user = "jdoe`n" + '@contoso.com' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field 'user'*"
        Should -Invoke Get-MgUser -Times 0 -Exactly
        Should -Invoke Update-MgUser -Times 0 -Exactly
        Should -Invoke Revoke-MgUserSignInSession -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
