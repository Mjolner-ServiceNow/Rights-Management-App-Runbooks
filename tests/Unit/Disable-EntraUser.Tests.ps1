#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft.Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the two
# Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Disable-EntraUser.ps1'
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
        param($UserId, [hashtable] $BodyParameter)
    }

    # Microsoft.Graph 2.39.0 reports a missing user as a plain System.Exception whose error
    # record carries the Graph error code in FullyQualifiedErrorId (found on the test worker).
    function script:New-GraphError {
        param([string] $Code, [string] $Message)
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("[$Code] : $Message"),
            "$Code,Microsoft.Graph.PowerShell.Cmdlets.GetMgUser_Get",
            [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-MgUser, Function:\Update-MgUser -ErrorAction SilentlyContinue
}

Describe 'Disable-EntraUser' -Tag 'Unit' {

    BeforeEach {
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:UserId = '44444444-4444-4444-4444-444444444444'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Message = $Message; Data = $Data }) }
        Mock Update-MgUser {}
        Mock Get-MgUser {
            [pscustomobject]@{
                Id = $script:UserId; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $true; OnPremisesSyncEnabled = $null
            }
        }
    }

    It 'handles the Disable-EntraUser command' {
        $script:Command | Should -Be 'Disable-EntraUser'
    }

    It 'disables an enabled user by the object id it looked up' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Disable-EntraUser'; user = ' jdoe@contoso.com ' })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter {
            $UserId -eq 'jdoe@contoso.com' -and $Property -contains 'accountEnabled' -and $Property -contains 'onPremisesSyncEnabled'
        }
        Should -Invoke Update-MgUser -Times 1 -Exactly -ParameterFilter {
            $UserId -eq $script:UserId -and $BodyParameter.Count -eq 1 -and $BodyParameter['accountEnabled'] -eq $false
        }
        $script:Logged[-1].Message | Should -Be 'Entra user disabled'
        $script:Logged[-1].Data.userPrincipalName | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.id | Should -Be $script:UserId
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'accepts <Case>' -ForEach @(
        @{ Case = 'an object id'; User = '44444444-4444-4444-4444-444444444444' }
        @{ Case = 'a guest user principal name'; User = 'alice_fabrikam.com#EXT#@contoso.onmicrosoft.com' }
        @{ Case = 'an apostrophe'; User = "o'brien@contoso.com" }
    ) {
        & $script:Body $script:Job ([pscustomobject]@{ user = $User })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $User }
        Should -Invoke Update-MgUser -Times 1 -Exactly
    }

    It 'completes without change for a user who is already disabled' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:UserId; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $false; OnPremisesSyncEnabled = $true } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Update-MgUser -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Match 'already disabled'
    }

    It 'asks the loop to run it again, with an actionable reason, when the user is not found' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Request_ResourceNotFound' -Message "Resource 'nobody@contoso.com' does not exist.") }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody@contoso.com' }) } |
        Should -Throw "No Entra ID user 'nobody@contoso.com'. Correct the ServiceNow record." -ErrorId 'RmaJobRetry,*'
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'refuses a user synchronised from on-premises Active Directory' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:UserId; UserPrincipalName = 'jdoe@contoso.com'; AccountEnabled = $true; OnPremisesSyncEnabled = $true } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
        Should -Throw "*synchronised from on-premises Active Directory*Disable-ADUser*"
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'passes any other lookup error through unchanged' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Authorization_RequestDenied' -Message 'Insufficient privileges to complete the operation.') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
        Should -Throw '*Authorization_RequestDenied*Insufficient privileges to complete the operation.'
        Should -Invoke Update-MgUser -Times 0 -Exactly
    }

    It 'passes an update error through unchanged' {
        Mock Update-MgUser { throw 'Insufficient privileges to complete the operation.' }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } |
        Should -Throw 'Insufficient privileges to complete the operation.'
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing user field'; Payload = [pscustomobject]@{ action = 'Disable-EntraUser' } }
        @{ Case = 'an empty user'; Payload = [pscustomobject]@{ user = '   ' } }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ user = "jdoe`n" + '@contoso.com' } }
        @{ Case = 'a path segment'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com/../../groups' } }
        @{ Case = 'a name without a domain'; Payload = [pscustomobject]@{ user = 'jdoe' } }
        @{ Case = 'a query string'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com?$select=id' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field 'user'*"
        Should -Invoke Get-MgUser -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com'; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }

    It 'never puts the payload in an error' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Request_ResourceNotFound' -Message 'does not exist.') }

        $thrown = $null
        try { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody@contoso.com'; note = 'should not appear' }) } catch { $thrown = $_ }

        "$thrown" | Should -Not -Match 'should not appear'
    }
}
