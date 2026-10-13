#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft.Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the two
# Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-EntraUser.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Get-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, $Property)
    }
    function global:Remove-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($UserId)
        $null = $PSCmdlet.ShouldProcess("$UserId", 'Remove')
    }

    # What the Graph SDK writes for a missing object: a plain exception, with the reason
    # only in the error id.
    function script:New-GraphError {
        param([string] $Code, [string] $Cmdlet)
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("[$Code] : Resource does not exist or one of its queried reference-property objects are not present."),
            "$Code,Microsoft.Graph.PowerShell.Cmdlets.$Cmdlet",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null)
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-MgUser, Function:\Remove-MgUser -ErrorAction SilentlyContinue
}

Describe 'Remove-EntraUser' -Tag 'Unit' {

    BeforeEach {
        $script:Id = '44444444-4444-4444-4444-444444444444'
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-MgUser {}
        Mock Get-MgUser {
            [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = 'jdoe@contoso.com' }
        }
    }

    It 'handles the Remove-EntraUser command' {
        $script:Command | Should -Be 'Remove-EntraUser'
    }

    It 'deletes the user by its object id when the payload names a user principal name' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-EntraUser'; user = ' jdoe@contoso.com ' })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq 'jdoe@contoso.com' }
        # By id, not by the payload's name: the object looked up is the object deleted.
        Should -Invoke Remove-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
        $script:Logged[-1].Level | Should -Be 'Information'
        $script:Logged[-1].Message | Should -Be 'Entra user deleted'
        $script:Logged[-1].Data.upn | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.id | Should -Be $script:Id
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'deletes the user when the payload names its object id' {
        & $script:Body $script:Job ([pscustomobject]@{ user = $script:Id })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
        Should -Invoke Remove-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
    }

    It 'accepts a guest user principal name and a name with an apostrophe' -ForEach @(
        @{ Upn = 'jane.doe_fabrikam.com#EXT#@contoso.onmicrosoft.com' }
        @{ Upn = "o'brien@contoso.com" }
    ) {
        Mock Get-MgUser { [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = $Upn } }

        & $script:Body $script:Job ([pscustomobject]@{ user = $Upn })

        Should -Invoke Remove-MgUser -Times 1 -Exactly
    }

    It 'matches the user principal name without regard to case' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'JDoe@Contoso.com' })

        Should -Invoke Remove-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
    }

    It 'completes, with a warning, when the user does not exist' {
        # docs/DECISIONS.md D15: the outcome asked for is already true.
        Mock Get-MgUser { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgUser_Get') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Remove-MgUser -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not found' }
        $script:Logged[-1].Data.user | Should -Be 'nobody@contoso.com'
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'completes, with a warning, when the user is deleted between the lookup and the delete' {
        Mock Remove-MgUser { throw (New-GraphError 'Request_ResourceNotFound' 'RemoveMgUser_Delete') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not found' }
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra user deleted' }
        $script:Logged[-1].Data.id | Should -Be $script:Id
    }

    It 'fails when the lookup fails for any other reason' {
        Mock Get-MgUser { throw (New-GraphError 'Authorization_RequestDenied' 'GetMgUser_Get') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Remove-MgUser -Times 0 -Exactly
    }

    It 'fails with Graph''s reason when the delete is refused' {
        Mock Remove-MgUser { throw (New-GraphError 'Authorization_RequestDenied' 'RemoveMgUser_Delete') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra user deleted' }
    }

    It 'deletes nothing when Graph returns a user other than the one named' {
        Mock Get-MgUser { [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; UserPrincipalName = 'someone.else@contoso.com' } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe@contoso.com' }) } | Should -Throw "*payload field 'user'*nothing was deleted*"
        Should -Invoke Remove-MgUser -Times 0 -Exactly
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing user field'; Payload = [pscustomobject]@{ action = 'Remove-EntraUser' } }
        @{ Case = 'an empty user'; Payload = [pscustomobject]@{ user = '   ' } }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ user = "jdoe`n" + 'x@contoso.com' } }
        @{ Case = 'a path separator'; Payload = [pscustomobject]@{ user = '44444444-4444-4444-4444-444444444444/manager' } }
        @{ Case = 'an escaped character'; Payload = [pscustomobject]@{ user = 'jdoe%23x@contoso.com' } }
        @{ Case = 'a query string'; Payload = [pscustomobject]@{ user = 'jdoe@contoso.com?$select=id' } }
        @{ Case = 'a name without a domain'; Payload = [pscustomobject]@{ user = 'jdoe' } }
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
