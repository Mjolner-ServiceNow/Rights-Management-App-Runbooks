#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft.Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the
# three Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Create-EntraAUUserMember.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Get-MgDirectoryAdministrativeUnit {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($AdministrativeUnitId, $Property)
    }
    function global:Get-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, $Property)
    }
    function global:New-MgDirectoryAdministrativeUnitMemberByRef {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($AdministrativeUnitId, $OdataId)
        $null = $PSCmdlet.ShouldProcess("$AdministrativeUnitId", 'Add member')
    }

    # What the Graph SDK writes for a failed request: a plain exception, with the reason
    # only in the error id and the message.
    function script:New-GraphError {
        param(
            [string] $Code,
            [string] $Cmdlet,
            [string] $Message = 'Resource does not exist or one of its queried reference-property objects are not present.'
        )
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("[$Code] : $Message"),
            "$Code,Microsoft.Graph.PowerShell.Cmdlets.$Cmdlet",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null)
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-MgDirectoryAdministrativeUnit, Function:\Get-MgUser, Function:\New-MgDirectoryAdministrativeUnitMemberByRef -ErrorAction SilentlyContinue
}

Describe 'Create-EntraAUUserMember' -Tag 'Unit' {

    BeforeEach {
        $script:UnitId = '33333333-3333-3333-3333-333333333333'
        $script:UserId = '44444444-4444-4444-4444-444444444444'
        $script:MemberRef = 'https://graph.microsoft.com/v1.0/directoryObjects/44444444-4444-4444-4444-444444444444'
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock New-MgDirectoryAdministrativeUnitMemberByRef {}
        Mock Get-MgDirectoryAdministrativeUnit {
            [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Sales'; MembershipType = $null }
        }
        Mock Get-MgUser {
            [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = 'jdoe@contoso.com' }
        }
    }

    It 'handles the Create-EntraAUUserMember command' {
        $script:Command | Should -Be 'Create-EntraAUUserMember'
    }

    It 'adds the member by the object ids it looked up when the payload names a user principal name' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Create-EntraAUUserMember'; ou = " $script:UnitId "; user = ' jdoe@contoso.com ' })

        Should -Invoke Get-MgDirectoryAdministrativeUnit -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq $script:UnitId -and $Property -contains 'membershipType'
        }
        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq 'jdoe@contoso.com' }
        # By id, not by the payload's name: the objects looked up are the objects changed.
        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq $script:UnitId -and $OdataId -eq $script:MemberRef
        }
        $script:Logged[-1].Level | Should -Be 'Information'
        $script:Logged[-1].Message | Should -Be 'Entra administrative unit member added'
        $script:Logged[-1].Data.administrativeUnit | Should -Be 'Sales'
        $script:Logged[-1].Data.administrativeUnitId | Should -Be $script:UnitId
        $script:Logged[-1].Data.upn | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.userId | Should -Be $script:UserId
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'adds the member when the payload names the user by object id' {
        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = $script:UserId })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:UserId }
        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq $script:UnitId -and $OdataId -eq $script:MemberRef
        }
    }

    It 'adds the member to a unit whose membership type is Assigned' {
        Mock Get-MgDirectoryAdministrativeUnit { [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Sales'; MembershipType = 'Assigned' } }

        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' })

        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 1 -Exactly
    }

    It 'matches object ids and the user principal name without regard to case' {
        Mock Get-MgDirectoryAdministrativeUnit { [pscustomobject]@{ Id = 'abcdef00-3333-3333-3333-333333333333'; DisplayName = 'Sales'; MembershipType = $null } }

        & $script:Body $script:Job ([pscustomobject]@{ ou = 'ABCDEF00-3333-3333-3333-333333333333'; user = 'JDoe@Contoso.com' })

        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq 'abcdef00-3333-3333-3333-333333333333' -and $OdataId -eq $script:MemberRef
        }
    }

    It 'accepts a guest user principal name and a name with an apostrophe' -ForEach @(
        @{ Upn = 'jane.doe_fabrikam.com#EXT#@contoso.onmicrosoft.com' }
        @{ Upn = "o'brien@contoso.com" }
    ) {
        Mock Get-MgUser { [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = $Upn } }

        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = $Upn })

        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 1 -Exactly
    }

    It 'completes when the user is already a member' {
        # What Graph returned on the test tenant for a second addition of the same user.
        Mock New-MgDirectoryAdministrativeUnitMemberByRef {
            throw (New-GraphError 'Request_BadRequest' 'NewMgDirectoryAdministrativeUnitMemberByRef_CreateExpanded' 'A conflicting object with one or more of the specified property values is present in the directory.')
        }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Information' -and $Message -match 'already a member' }
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra administrative unit member added' }
        $script:Logged[-1].Data.administrativeUnitId | Should -Be $script:UnitId
        $script:Logged[-1].Data.userId | Should -Be $script:UserId
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'fails with Graph''s reason on any other bad request' {
        Mock New-MgDirectoryAdministrativeUnitMemberByRef {
            throw (New-GraphError 'Request_BadRequest' 'NewMgDirectoryAdministrativeUnitMemberByRef_CreateExpanded' 'Invalid object identifier.')
        }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } | Should -Throw '*Request_BadRequest*Invalid object identifier*'
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'fails with Graph''s reason when the addition is refused' {
        # A unit with restricted management, for example, when the app holds no role on it.
        Mock New-MgDirectoryAdministrativeUnitMemberByRef {
            throw (New-GraphError 'Authorization_RequestDenied' 'NewMgDirectoryAdministrativeUnitMemberByRef_CreateExpanded' 'Insufficient privileges to complete the operation.')
        }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'fails when the administrative unit does not exist' {
        # Not a removal: there is nothing to add the user to (docs/DECISIONS.md D15 covers deletes only).
        Mock Get-MgDirectoryAdministrativeUnit { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgDirectoryAdministrativeUnit_Get') }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } |
        Should -Throw "No Entra ID administrative unit '$script:UnitId'. Correct the ServiceNow record."
        Should -Invoke Get-MgUser -Times 0 -Exactly
        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
    }

    It 'fails when the user does not exist' {
        Mock Get-MgUser { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgUser_Get') }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'nobody@contoso.com' }) } |
        Should -Throw "No Entra ID user 'nobody@contoso.com'. Correct the ServiceNow record."
        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
    }

    It 'refuses a unit with dynamic membership before adding anything' {
        Mock Get-MgDirectoryAdministrativeUnit { [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Sales'; MembershipType = 'Dynamic' } }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } |
        Should -Throw "*'Sales' has dynamic membership*Correct the ServiceNow record."
        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
    }

    It 'fails when the <Cmdlet> lookup fails for any other reason' -ForEach @(
        @{ Cmdlet = 'Get-MgDirectoryAdministrativeUnit'; Id = 'GetMgDirectoryAdministrativeUnit_Get' }
        @{ Cmdlet = 'Get-MgUser'; Id = 'GetMgUser_Get' }
    ) {
        Mock $Cmdlet { throw (New-GraphError 'Authorization_RequestDenied' $Id 'Insufficient privileges to complete the operation.') }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'adds nothing when Graph returns a <Kind> other than the one named' -ForEach @(
        @{ Kind = 'ou'; Cmdlet = 'Get-MgDirectoryAdministrativeUnit'; Other = [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; DisplayName = 'Other'; MembershipType = $null } }
        @{ Kind = 'user'; Cmdlet = 'Get-MgUser'; Other = [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; UserPrincipalName = 'someone.else@contoso.com' } }
    ) {
        Mock $Cmdlet { $Other }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } |
        Should -Throw "*payload field '$Kind'*nothing was added*"
        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing ou field'; Field = 'ou'; Payload = [pscustomobject]@{ action = 'Create-EntraAUUserMember'; user = 'jdoe@contoso.com' } }
        @{ Case = 'an empty ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = '  '; user = 'jdoe@contoso.com' } }
        @{ Case = 'a unit display name'; Field = 'ou'; Payload = [pscustomobject]@{ ou = 'Sales'; user = 'jdoe@contoso.com' } }
        @{ Case = 'a control character in the ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = "33333333-3333-3333-`n3333-333333333333"; user = 'jdoe@contoso.com' } }
        @{ Case = 'a path in the ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333/members'; user = 'jdoe@contoso.com' } }
        @{ Case = 'a missing user field'; Field = 'user'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333' } }
        @{ Case = 'an empty user'; Field = 'user'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333'; user = '   ' } }
        @{ Case = 'a control character in the user'; Field = 'user'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333'; user = "jdoe`n" + 'x@contoso.com' } }
        @{ Case = 'a path separator in the user'; Field = 'user'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333'; user = '44444444-4444-4444-4444-444444444444/manager' } }
        @{ Case = 'an escaped character in the user'; Field = 'user'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333'; user = 'jdoe%23x@contoso.com' } }
        @{ Case = 'a query string in the user'; Field = 'user'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333'; user = 'jdoe@contoso.com?$select=id' } }
        @{ Case = 'a user name without a domain'; Field = 'user'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333'; user = 'jdoe' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field '$Field'*Correct the ServiceNow record."
        Should -Invoke Get-MgDirectoryAdministrativeUnit -Times 0 -Exactly
        Should -Invoke Get-MgUser -Times 0 -Exactly
        Should -Invoke New-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com'; note = 'should not appear' })
        $refused = { & $script:Body $script:Job ([pscustomobject]@{ ou = 'should not appear'; user = 'jdoe@contoso.com' }) } |
        Should -Throw -PassThru

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
        $refused.Exception.Message | Should -Not -Match 'should not appear'
    }
}
