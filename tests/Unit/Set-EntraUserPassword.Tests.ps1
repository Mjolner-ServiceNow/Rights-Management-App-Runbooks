#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the two
# Graph cmdlets it calls. The payload carries a password: the tests that matter most are
# the ones that show it never reaches a log record, a message or an error record.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Set-EntraUserPassword.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path
    $script:Secret = 'N3w-Pa55w0rd!'

    # Graph errors are a plain System.Exception whose error id leads with the Graph error
    # code. For Update-MgUser, the SDK puts the request body, password included, into the
    # error's TargetObject (seen on the test tenant with SDK 2.39.0); this builds that shape.
    function script:New-GraphError {
        param([string] $Code, [string] $Message, [string] $Cmdlet = 'GetMgUser_Get', $TargetObject = $null)
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("[$Code] : $Message"),
            "$Code,Microsoft.Graph.PowerShell.Cmdlets.$Cmdlet",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $TargetObject)
    }

    function global:Get-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, $Property)
    }
    function global:Update-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
            Justification = 'Mirrors the real Update-MgUser parameters -UserId and -PasswordProfile, which the mock must bind by those names.')]
        [CmdletBinding()]
        param($UserId, [hashtable] $PasswordProfile)
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-MgUser, Function:\Update-MgUser -ErrorAction SilentlyContinue
}

Describe 'Set-EntraUserPassword' -Tag 'Unit', 'Security' {

    BeforeEach {
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:Id = '44444444-4444-4444-4444-444444444444'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        $script:Sent = $null
        Mock Update-MgUser { $script:Sent = $PasswordProfile.Clone() }
        Mock Get-MgUser {
            [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = 'jdoe@contoso.com'; OnPremisesSyncEnabled = $null }
        }
    }

    It 'handles the Set-EntraUserPassword command' {
        $script:Command | Should -Be 'Set-EntraUserPassword'
    }

    It 'resets the password by object id, without a change at next sign-in by default' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Set-EntraUserPassword'; user = ' jdoe@contoso.com '; password = $script:Secret })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter {
            $UserId -eq 'jdoe@contoso.com' -and 'onPremisesSyncEnabled' -in $Property
        }
        Should -Invoke Update-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq '44444444-4444-4444-4444-444444444444' }
        $script:Sent.password | Should -BeExactly $script:Secret
        $script:Sent.forceChangePasswordNextSignIn | Should -BeExactly $false
        $script:Logged[-1].Message | Should -Be 'Entra user password reset'
        $script:Logged[-1].Data.userPrincipalName | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.id | Should -Be $script:Id
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
        $script:Logged[-1].Data.mustChange | Should -BeFalse
    }

    It 'sends a password with leading and trailing spaces as it is' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; password = " $script:Secret " })

        $script:Sent.password | Should -BeExactly " $script:Secret "
    }

    It 'resets a user named by object id' {
        & $script:Body $script:Job ([pscustomobject]@{ user = $script:Id.ToUpperInvariant(); password = $script:Secret })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
        Should -Invoke Update-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
    }

    It 'requires a change at next sign-in when mustChange is <Case>' -ForEach @(
        @{ Case = 'a JSON boolean'; MustChange = $true }
        @{ Case = 'text'; MustChange = ' True ' }
    ) {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; password = $script:Secret; mustChange = $MustChange })

        $script:Sent.forceChangePasswordNextSignIn | Should -BeExactly $true
        $script:Logged[-1].Data.mustChange | Should -BeTrue
    }

    It 'does not require a change at next sign-in when mustChange is <Case>' -ForEach @(
        @{ Case = 'a JSON boolean'; MustChange = $false }
        @{ Case = 'text'; MustChange = 'false' }
        @{ Case = 'empty'; MustChange = '' }
    ) {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; password = $script:Secret; mustChange = $MustChange })

        $script:Sent.forceChangePasswordNextSignIn | Should -BeExactly $false
    }

    It 'fails with an actionable message when the user does not exist' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Request_ResourceNotFound' -Message "Resource 'nobody@contoso.com' does not exist.") }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody@contoso.com'; password = $script:Secret }) } |
        Should -Throw "No Entra ID user 'nobody@contoso.com'. Correct the ServiceNow record."
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'passes any other lookup failure through unchanged' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Authorization_RequestDenied' -Message 'Insufficient privileges to complete the operation.') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; password = $script:Secret }) } |
        Should -Throw '*Authorization_RequestDenied*Insufficient privileges*'
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'refuses a user synchronised from on-premises AD without sending the password' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:Id; UserPrincipalName = 'jdoe@contoso.com'; OnPremisesSyncEnabled = $true } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; password = $script:Secret }) } |
        Should -Throw '*synchronised from on-premises Active Directory*Use Set-ADUserPassword.'
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'changes nothing when Graph returns a different user than the one asked for' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:Id; UserPrincipalName = 'admin@contoso.com'; OnPremisesSyncEnabled = $null } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; password = $script:Secret }) } |
        Should -Throw '*different user*Nothing was changed*'
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'fails with Graph''s reason, and without the request body, when the password is refused' {
        Mock Update-MgUser {
            throw (New-GraphError -Code 'Request_BadRequest' -Cmdlet 'UpdateMgUser_UpdateExpanded' `
                    -Message 'The specified password does not comply with password complexity requirements. Please provide a different password.' `
                    -TargetObject @{ UserId = $UserId; body = @{ passwordProfile = $PasswordProfile } })
        }

        $record = $null
        try { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; password = $script:Secret }) } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.Exception.Message | Should -BeExactly '[Request_BadRequest] : The specified password does not comply with password complexity requirements. Please provide a different password.'
        $record.TargetObject | Should -BeNullOrEmpty
        ($record | Format-List * -Force | Out-String) | Should -Not -Match ([regex]::Escape($script:Secret))
        $script:Logged | Where-Object Message -EQ 'Entra user password reset' | Should -BeNullOrEmpty
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing user field'; Payload = [pscustomobject]@{ action = 'Set-EntraUserPassword'; password = 'x' }; Message = "*Payload field 'user'*" }
        @{ Case = 'an empty user'; Payload = [pscustomobject]@{ user = '   '; password = 'x' }; Message = "*Payload field 'user'*" }
        @{ Case = 'a control character in the user'; Payload = [pscustomobject]@{ user = "jdoe`n" + 'x@contoso.com'; password = 'x' }; Message = "*Payload field 'user'*" }
        @{ Case = 'a name without a domain'; Payload = [pscustomobject]@{ user = 'jdoe'; password = 'x' }; Message = "*Payload field 'user'*" }
        @{ Case = 'a path separator'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com/manager'; password = 'x' }; Message = "*Payload field 'user'*" }
        @{ Case = 'a query string'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com?$select=id'; password = 'x' }; Message = "*Payload field 'user'*" }
        @{ Case = 'a percent sign'; Payload = [pscustomobject]@{ user = 'jdoe%2f@contoso.com'; password = 'x' }; Message = "*Payload field 'user'*" }
        @{ Case = 'a missing password'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com' }; Message = "*Payload field 'password' is empty*" }
        @{ Case = 'an empty password'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com'; password = '' }; Message = "*Payload field 'password' is empty*" }
        @{ Case = 'a mustChange that is not a boolean'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com'; password = 'x'; mustChange = 'yes' }; Message = "*Payload field 'mustChange' must be true or false*" }
        @{ Case = 'a numeric mustChange'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com'; password = 'x'; mustChange = 1 }; Message = "*Payload field 'mustChange' must be true or false*" }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw $Message
        Should -Invoke Get-MgUser -Times 0 -Exactly
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'never puts the password or the payload into a log record or a message' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; password = $script:Secret; mustChange = $true; note = 'should not appear' })

        Mock Get-MgUser { throw (New-GraphError -Code 'Request_ResourceNotFound' -Message 'Resource does not exist.') }
        $notFound = [pscustomobject]@{ user = 'nobody@contoso.com'; password = $script:Secret }
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:Id; UserPrincipalName = 'jdoe@contoso.com'; OnPremisesSyncEnabled = $true } } -ParameterFilter { $UserId -eq 'synced@contoso.com' }
        $errors = foreach ($payload in @(
                [pscustomobject]@{ user = 'jdoe@contoso.com'; password = $script:Secret; mustChange = 'maybe' }
                [pscustomobject]@{ user = "bad`nuser@contoso.com"; password = $script:Secret }
                $notFound
                [pscustomobject]@{ user = 'synced@contoso.com'; password = $script:Secret })) {
            try { & $script:Body $script:Job $payload } catch { $_ | Format-List * -Force | Out-String }
        }

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match ([regex]::Escape($script:Secret))
        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
        $errors.Count | Should -Be 4
        $errors | ForEach-Object { $_ | Should -Not -Match ([regex]::Escape($script:Secret)) }
    }
}
