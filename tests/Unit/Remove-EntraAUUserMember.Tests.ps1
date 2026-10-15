#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft.Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the
# three Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-EntraAUUserMember.ps1'
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
    function global:Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($AdministrativeUnitId, $DirectoryObjectId)
        $null = $PSCmdlet.ShouldProcess("$AdministrativeUnitId", 'Remove member')
    }

    # What the Graph SDK writes for a missing object: a plain exception, with the reason
    # only in the error id.
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
    Remove-Item -Path Function:\Get-MgDirectoryAdministrativeUnit, Function:\Get-MgUser,
    Function:\Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -ErrorAction SilentlyContinue
}

Describe 'Remove-EntraAUUserMember' -Tag 'Unit' {

    BeforeEach {
        $script:UnitId = '33333333-3333-3333-3333-333333333333'
        $script:UserId = '44444444-4444-4444-4444-444444444444'
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:RemoveId = 'RemoveMgDirectoryAdministrativeUnitMemberDirectoryObjectByRef_Delete'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef {}
        Mock Get-MgDirectoryAdministrativeUnit {
            [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Sales'; MembershipType = $null }
        }
        Mock Get-MgUser {
            [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = 'jdoe@contoso.com' }
        }
    }

    It 'handles the Remove-EntraAUUserMember command' {
        $script:Command | Should -Be 'Remove-EntraAUUserMember'
    }

    It 'removes the member by the object ids it looked up when the payload names a user principal name' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-EntraAUUserMember'; ou = " $script:UnitId "; user = ' jdoe@contoso.com ' })

        Should -Invoke Get-MgDirectoryAdministrativeUnit -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq $script:UnitId -and $Property -contains 'membershipType'
        }
        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq 'jdoe@contoso.com' }
        # By id, not by the payload's name: the objects looked up are the objects changed.
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq $script:UnitId -and $DirectoryObjectId -eq $script:UserId
        }
        $script:Logged[-1].Level | Should -Be 'Information'
        $script:Logged[-1].Message | Should -Be 'Entra administrative unit member removed'
        $script:Logged[-1].Data.administrativeUnit | Should -Be 'Sales'
        $script:Logged[-1].Data.administrativeUnitId | Should -Be $script:UnitId
        $script:Logged[-1].Data.upn | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.userId | Should -Be $script:UserId
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'removes the member when the payload names the user by object id' {
        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = $script:UserId })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:UserId }
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq $script:UnitId -and $DirectoryObjectId -eq $script:UserId
        }
    }

    It 'removes the member from an administrative unit with assigned membership reported as <Case>' -ForEach @(
        @{ Case = 'null'; Type = $null }
        @{ Case = 'Assigned'; Type = 'Assigned' }
    ) {
        Mock Get-MgDirectoryAdministrativeUnit { [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Sales'; MembershipType = $Type } }

        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = $script:UserId })

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 1 -Exactly
    }

    It 'matches object ids and the user principal name without regard to case' {
        Mock Get-MgDirectoryAdministrativeUnit { [pscustomobject]@{ Id = 'abcdef00-3333-3333-3333-333333333333'; DisplayName = 'Sales'; MembershipType = $null } }

        & $script:Body $script:Job ([pscustomobject]@{ ou = 'ABCDEF00-3333-3333-3333-333333333333'; user = 'JDoe@Contoso.com' })

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq 'abcdef00-3333-3333-3333-333333333333' -and $DirectoryObjectId -eq $script:UserId
        }
    }

    It 'accepts a guest user principal name and a name with an apostrophe' -ForEach @(
        @{ Upn = 'jane.doe_fabrikam.com#EXT#@contoso.onmicrosoft.com' }
        @{ Upn = "o'brien@contoso.com" }
    ) {
        Mock Get-MgUser { [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = $Upn } }

        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = $Upn })

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 1 -Exactly
    }

    It 'completes, with a warning, when the user is not a member (<Case>)' -ForEach @(
        # What the test tenant answered, for a non-member and right after a removal.
        @{ Case = 'not found'; Code = 'Request_ResourceNotFound'; Text = "Resource '33333333-3333-3333-3333-333333333333' does not exist or one of its queried reference-property objects are not present." }
        # What the group endpoint answers seconds after a removal.
        @{ Case = 'bad request'; Code = 'Request_BadRequest'; Text = "One or more removed object references do not exist for the following modified properties: 'members'." }
    ) {
        Mock Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef { throw (New-GraphError $Code $script:RemoveId $Text) }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not a member' }
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra administrative unit member removed' }
        $script:Logged[-1].Data.administrativeUnitId | Should -Be $script:UnitId
        $script:Logged[-1].Data.userId | Should -Be $script:UserId
    }

    It 'completes at once, with a warning, when the administrative unit is in deleted items' {
        # docs/DECISIONS.md D15: the outcome asked for is already true. D19: deleted items
        # tell gone from not replicated yet.
        Mock Get-MgDirectoryAdministrativeUnit { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgDirectoryAdministrativeUnit_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 0 -Exactly
        Should -Invoke Test-RmaDeletedDirectoryObject -Times 1 -Exactly -ParameterFilter { $Id -eq $script:UnitId }
        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'administrative unit not found' }
        $script:Logged[-1].Data.inDeletedItems | Should -BeTrue
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'asks the loop to run it again, and to complete it then, when the administrative unit is found neither live nor in deleted items' {
        # D19: it may have been created moments ago and not have reached Graph yet.
        Mock Get-MgDirectoryAdministrativeUnit { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgDirectoryAdministrativeUnit_Get') }
        Mock Test-RmaDeletedDirectoryObject { $false }

        $caught = $null
        try { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } catch { $caught = $_ }

        $caught.FullyQualifiedErrorId | Should -BeLike 'RmaJobRetry,*'
        $caught.Exception.Message | Should -BeLike '*administrative unit*not found; the membership does not exist'
        $caught.TargetObject.CompleteWhenExhausted | Should -BeTrue
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'completes at once, with a warning, when the user is in deleted items' {
        # docs/DECISIONS.md D15: the outcome asked for is already true. D19: deleted items
        # tell gone from not replicated yet.
        Mock Get-MgUser { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgUser_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = $script:UserId }) } | Should -Not -Throw

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 0 -Exactly
        Should -Invoke Test-RmaDeletedDirectoryObject -Times 1 -Exactly -ParameterFilter { $Id -eq $script:UserId }
        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'user not found' }
        $script:Logged[-1].Data.inDeletedItems | Should -BeTrue
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'asks the loop to run it again, and to complete it then, when the user is found neither live nor in deleted items' {
        # D19: it may have been created moments ago and not have reached Graph yet.
        Mock Get-MgUser { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgUser_Get') }
        Mock Test-RmaDeletedDirectoryObject { $false }

        $caught = $null
        try { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = $script:UserId }) } catch { $caught = $_ }

        $caught.FullyQualifiedErrorId | Should -BeLike 'RmaJobRetry,*'
        $caught.Exception.Message | Should -BeLike '*user*not found; the membership does not exist'
        $caught.TargetObject.CompleteWhenExhausted | Should -BeTrue
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'asks the loop to run it again without looking in deleted items for a user principal name' {
        # Entra rewrites a deleted user's UPN, so only an object id can be looked up there.
        Mock Get-MgUser { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgUser_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'nobody@contoso.com' }) } |
        Should -Throw "*'nobody@contoso.com' not found; the membership does not exist" -ErrorId 'RmaJobRetry,*'
        Should -Invoke Test-RmaDeletedDirectoryObject -Times 0 -Exactly
    }

    It 'refuses an administrative unit with dynamic membership before asking Graph to remove' {
        # Graph's own answer is a misleading Authorization_RequestDenied.
        Mock Get-MgDirectoryAdministrativeUnit { [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Sales'; MembershipType = 'Dynamic' } }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } |
        Should -Throw "*payload field 'ou'*dynamic membership*Correct the ServiceNow record."
        Should -Invoke Get-MgUser -Times 0 -Exactly
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'fails when the <Cmdlet> lookup fails for any other reason' -ForEach @(
        @{ Cmdlet = 'Get-MgDirectoryAdministrativeUnit'; Id = 'GetMgDirectoryAdministrativeUnit_Get' }
        @{ Cmdlet = 'Get-MgUser'; Id = 'GetMgUser_Get' }
    ) {
        Mock $Cmdlet { throw (New-GraphError 'Authorization_RequestDenied' $Id 'Insufficient privileges to complete the operation.') }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'fails with Graph''s reason when the removal is refused (<Case>)' -ForEach @(
        # A restricted management administrative unit, without a role scoped to it.
        @{ Case = 'access denied'; Code = 'Authorization_RequestDenied'; Text = 'Insufficient privileges to complete the operation.' }
        @{ Case = 'another bad request'; Code = 'Request_BadRequest'; Text = 'Invalid object identifier.' }
    ) {
        Mock Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef { throw (New-GraphError $Code $script:RemoveId $Text) }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } | Should -Throw "*$Code*$Text*"
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'removes nothing when Graph returns <Kind> other than the one named' -ForEach @(
        @{ Kind = 'an administrative unit'; Field = 'ou'; Cmdlet = 'Get-MgDirectoryAdministrativeUnit'; Other = [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; DisplayName = 'Other'; MembershipType = $null } }
        @{ Kind = 'a user'; Field = 'user'; Cmdlet = 'Get-MgUser'; Other = [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; UserPrincipalName = 'someone.else@contoso.com' } }
    ) {
        Mock $Cmdlet { $Other }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com' }) } |
        Should -Throw "*payload field '$Field'*nothing was removed*"
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 0 -Exactly
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing ou field'; Field = 'ou'; Payload = [pscustomobject]@{ action = 'Remove-EntraAUUserMember'; user = 'jdoe@contoso.com' } }
        @{ Case = 'an empty ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = '  '; user = 'jdoe@contoso.com' } }
        @{ Case = 'an administrative unit display name'; Field = 'ou'; Payload = [pscustomobject]@{ ou = 'Sales'; user = 'jdoe@contoso.com' } }
        @{ Case = 'a control character in the ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = "33333333-3333-3333-`n3333-333333333333"; user = 'jdoe@contoso.com' } }
        @{ Case = 'a path in the ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333/members'; user = 'jdoe@contoso.com' } }
        @{ Case = 'an escaped character in the ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = '33333333-3333-3333-3333-333333333333%2F'; user = 'jdoe@contoso.com' } }
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
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef -Times 0 -Exactly
    }

    It 'never logs the payload' {
        Mock Remove-MgDirectoryAdministrativeUnitMemberDirectoryObjectByRef { throw (New-GraphError 'Request_ResourceNotFound' $script:RemoveId) }

        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; user = 'jdoe@contoso.com'; note = 'should not appear' })
        $refused = { & $script:Body $script:Job ([pscustomobject]@{ ou = 'should not appear'; user = 'jdoe@contoso.com' }) } |
        Should -Throw -PassThru

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
        $refused.Exception.Message | Should -Not -Match 'should not appear'
    }
}
