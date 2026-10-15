#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the two
# Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Enable-EntraUser.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    # Graph reports a missing user as a plain System.Exception whose error id leads with
    # the Graph error code; this builds the same shape.
    function script:New-GraphError {
        param([string] $Code, [string] $Message)
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("[$Code] : $Message"),
            "$Code,Microsoft.Graph.PowerShell.Cmdlets.GetMgUser_Get",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null)
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
        [CmdletBinding()]
        param($UserId, [switch] $AccountEnabled)
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-MgUser, Function:\Update-MgUser -ErrorAction SilentlyContinue
}

Describe 'Enable-EntraUser' -Tag 'Unit' {

    BeforeEach {
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:Id = '44444444-4444-4444-4444-444444444444'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Message = $Message; Data = $Data }) }
        Mock Update-MgUser {}
        Mock Get-MgUser {
            [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $false }
        }
    }

    It 'handles the Enable-EntraUser command' {
        $script:Command | Should -Be 'Enable-EntraUser'
    }

    It 'enables a disabled user, looked up by user principal name and changed by object id' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Enable-EntraUser'; user = ' jdoe@contoso.com ' })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter {
            $UserId -eq 'jdoe@contoso.com' -and 'accountEnabled' -in $Property
        }
        Should -Invoke Update-MgUser -Times 1 -Exactly -ParameterFilter {
            $UserId -eq '44444444-4444-4444-4444-444444444444' -and $AccountEnabled
        }
        $script:Logged[-1].Message | Should -Be 'Entra user enabled'
        $script:Logged[-1].Data.userPrincipalName | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.id | Should -Be $script:Id
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'enables a user named by object id' {
        & $script:Body $script:Job ([pscustomobject]@{ user = $script:Id.ToUpperInvariant() })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
        Should -Invoke Update-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
    }

    It 'accepts a guest''s user principal name' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:Id; UserPrincipalName = 'j.o''doe_fabrikam.com#EXT#@contoso.com'; AccountEnabled = $false } }

        & $script:Body $script:Job ([pscustomobject]@{ user = 'j.o''doe_fabrikam.com#EXT#@contoso.com' })

        Should -Invoke Update-MgUser -Times 1 -Exactly
    }

    It 'completes without change for a user who is already enabled' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:Id; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $true } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Update-MgUser -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Match 'already enabled'
    }

    It 'asks the loop to run it again, with an actionable reason, when the user is not found' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Request_ResourceNotFound' -Message "Resource 'nobody@contoso.com' does not exist.") }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody@contoso.com' }) } |
        Should -Throw "No Entra ID user 'nobody@contoso.com'. Correct the ServiceNow record." -ErrorId 'RmaJobRetry,*'
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'passes any other lookup failure through unchanged' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Authorization_RequestDenied' -Message 'Insufficient privileges to complete the operation.') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
        Should -Throw '*Authorization_RequestDenied*Insufficient privileges*'
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'fails with Graph''s own reason when the update is refused' {
        Mock Update-MgUser { throw '[Authorization_RequestDenied] : Insufficient privileges to complete the operation.' }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
        Should -Throw '*Insufficient privileges*'
    }

    It 'changes nothing when Graph returns a different user than the one asked for' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:Id; UserPrincipalName = 'admin@contoso.com'; AccountEnabled = $false } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
        Should -Throw '*different user*Nothing was changed*'
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing user field'; Payload = [pscustomobject]@{ action = 'Enable-EntraUser' } }
        @{ Case = 'an empty user'; Payload = [pscustomobject]@{ user = '   ' } }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ user = "jdoe`n" + 'x@contoso.com' } }
        @{ Case = 'a name without a domain'; Payload = [pscustomobject]@{ user = 'jdoe' } }
        @{ Case = 'a path separator'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com/manager' } }
        @{ Case = 'a query string'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com?$select=id' } }
        @{ Case = 'a space'; Payload = [pscustomobject]@{ user = 'j doe@contoso.com' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field 'user'*Correct the ServiceNow record."
        Should -Invoke Get-MgUser -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
