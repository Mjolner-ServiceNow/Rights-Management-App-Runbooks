#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft.Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the
# three Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-EntraAUGroupMember.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Get-MgDirectoryAdministrativeUnit {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($AdministrativeUnitId, $Property)
    }
    function global:Get-MgGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($GroupId, $Property)
    }
    function global:Remove-MgDirectoryAdministrativeUnitMemberByRef {
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
    Remove-Item -Path Function:\Get-MgDirectoryAdministrativeUnit, Function:\Get-MgGroup,
    Function:\Remove-MgDirectoryAdministrativeUnitMemberByRef -ErrorAction SilentlyContinue
}

Describe 'Remove-EntraAUGroupMember' -Tag 'Unit' {

    BeforeEach {
        $script:UnitId = '22222222-2222-2222-2222-222222222222'
        $script:GroupId = '33333333-3333-3333-3333-333333333333'
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-MgDirectoryAdministrativeUnitMemberByRef {}
        # An assigned unit reports membershipType empty, not 'Assigned' (test tenant).
        Mock Get-MgDirectoryAdministrativeUnit {
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; DisplayName = 'Region North'; MembershipType = $null }
        }
        Mock Get-MgGroup {
            [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Sales' }
        }
    }

    It 'handles the Remove-EntraAUGroupMember command' {
        $script:Command | Should -Be 'Remove-EntraAUGroupMember'
    }

    It 'removes the group by the object ids it looked up' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-EntraAUGroupMember'; ou = " $script:UnitId "; group = " $script:GroupId " })

        Should -Invoke Get-MgDirectoryAdministrativeUnit -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq $script:UnitId -and $Property -contains 'membershipType'
        }
        Should -Invoke Get-MgGroup -Times 1 -Exactly -ParameterFilter { $GroupId -eq $script:GroupId }
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq $script:UnitId -and $DirectoryObjectId -eq $script:GroupId
        }
        $script:Logged[-1].Level | Should -Be 'Information'
        $script:Logged[-1].Message | Should -Be 'Entra group removed from administrative unit'
        $script:Logged[-1].Data.administrativeUnit | Should -Be 'Region North'
        $script:Logged[-1].Data.administrativeUnitId | Should -Be $script:UnitId
        $script:Logged[-1].Data.group | Should -Be 'Sales'
        $script:Logged[-1].Data.groupId | Should -Be $script:GroupId
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'removes the group from a unit whose membership type is Assigned' {
        Mock Get-MgDirectoryAdministrativeUnit {
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; DisplayName = 'Region North'; MembershipType = 'Assigned' }
        }

        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId })

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 1 -Exactly
    }

    It 'matches object ids without regard to case' {
        Mock Get-MgDirectoryAdministrativeUnit { [pscustomobject]@{ Id = 'abcdef00-2222-2222-2222-222222222222'; DisplayName = 'Region North'; MembershipType = $null } }
        Mock Get-MgGroup { [pscustomobject]@{ Id = 'abcdef00-3333-3333-3333-333333333333'; DisplayName = 'Sales' } }

        & $script:Body $script:Job ([pscustomobject]@{ ou = 'ABCDEF00-2222-2222-2222-222222222222'; group = 'ABCDEF00-3333-3333-3333-333333333333' })

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 1 -Exactly -ParameterFilter {
            $AdministrativeUnitId -eq 'abcdef00-2222-2222-2222-222222222222' -and $DirectoryObjectId -eq 'abcdef00-3333-3333-3333-333333333333'
        }
    }

    It 'completes, with a warning, when the group is not a member (<Case>)' -ForEach @(
        # What the test tenant answered, immediately after a removal and later alike.
        @{ Case = 'not found'; Code = 'Request_ResourceNotFound'; Text = "Resource '22222222-2222-2222-2222-222222222222' does not exist or one of its queried reference-property objects are not present." }
        # What group membership answers seconds after a removal.
        @{ Case = 'bad request'; Code = 'Request_BadRequest'; Text = "One or more removed object references do not exist for the following modified properties: 'members'." }
    ) {
        Mock Remove-MgDirectoryAdministrativeUnitMemberByRef {
            throw (New-GraphError $Code 'RemoveMgDirectoryAdministrativeUnitMemberDirectoryObjectByRef_Delete' $Text)
        }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } | Should -Not -Throw

        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not a member' }
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra group removed from administrative unit' }
        $script:Logged[-1].Data.administrativeUnitId | Should -Be $script:UnitId
        $script:Logged[-1].Data.groupId | Should -Be $script:GroupId
    }

    It 'completes at once, with a warning, when the administrative unit is in deleted items' {
        # docs/DECISIONS.md D15: the outcome asked for is already true. D19: deleted items
        # tell gone from not replicated yet.
        Mock Get-MgDirectoryAdministrativeUnit { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgDirectoryAdministrativeUnit_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } | Should -Not -Throw

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
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
        try { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } catch { $caught = $_ }

        $caught.FullyQualifiedErrorId | Should -BeLike 'RmaJobRetry,*'
        $caught.Exception.Message | Should -BeLike '*administrative unit*not found; the membership does not exist'
        $caught.TargetObject.CompleteWhenExhausted | Should -BeTrue
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'completes at once, with a warning, when the group is in deleted items' {
        # docs/DECISIONS.md D15: the outcome asked for is already true. D19: deleted items
        # tell gone from not replicated yet.
        Mock Get-MgGroup { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgGroup_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } | Should -Not -Throw

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
        Should -Invoke Test-RmaDeletedDirectoryObject -Times 1 -Exactly -ParameterFilter { $Id -eq $script:GroupId }
        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'group not found' }
        $script:Logged[-1].Data.inDeletedItems | Should -BeTrue
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'asks the loop to run it again, and to complete it then, when the group is found neither live nor in deleted items' {
        # D19: it may have been created moments ago and not have reached Graph yet.
        Mock Get-MgGroup { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgGroup_Get') }
        Mock Test-RmaDeletedDirectoryObject { $false }

        $caught = $null
        try { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } catch { $caught = $_ }

        $caught.FullyQualifiedErrorId | Should -BeLike 'RmaJobRetry,*'
        $caught.Exception.Message | Should -BeLike '*group*not found; the membership does not exist'
        $caught.TargetObject.CompleteWhenExhausted | Should -BeTrue
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'refuses an administrative unit with dynamic membership before asking Graph to remove' {
        # As 1.0 and the two user runbooks do (#159).
        Mock Get-MgDirectoryAdministrativeUnit {
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; DisplayName = 'Region North'; MembershipType = 'Dynamic' }
        }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } |
        Should -Throw "*payload field 'ou'*dynamic membership*Correct the ServiceNow record."

        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' }
    }

    It 'fails when the <Cmdlet> lookup fails for any other reason' -ForEach @(
        @{ Cmdlet = 'Get-MgDirectoryAdministrativeUnit'; Id = 'GetMgDirectoryAdministrativeUnit_Get' }
        @{ Cmdlet = 'Get-MgGroup'; Id = 'GetMgGroup_Get' }
    ) {
        Mock $Cmdlet { throw (New-GraphError 'Authorization_RequestDenied' $Id 'Insufficient privileges to complete the operation.') }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'fails with Graph''s reason when the removal is refused (<Case>)' -ForEach @(
        # An administrative unit with restricted management, for example.
        @{ Case = 'access denied'; Code = 'Authorization_RequestDenied'; Text = 'Insufficient privileges to complete the operation.' }
        # A bad request that does not say the reference is missing.
        @{ Case = 'another bad request'; Code = 'Request_BadRequest'; Text = 'Invalid object identifier.' }
    ) {
        Mock Remove-MgDirectoryAdministrativeUnitMemberByRef {
            throw (New-GraphError $Code 'RemoveMgDirectoryAdministrativeUnitMemberDirectoryObjectByRef_Delete' $Text)
        }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } | Should -Throw "*$Code*$Text*"
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'removes nothing when Graph returns a <Kind> other than the one named' -ForEach @(
        @{ Kind = 'ou'; Cmdlet = 'Get-MgDirectoryAdministrativeUnit'; Other = [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; DisplayName = 'Other'; MembershipType = $null } }
        @{ Kind = 'group'; Cmdlet = 'Get-MgGroup'; Other = [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; DisplayName = 'Other' } }
    ) {
        Mock $Cmdlet { $Other }

        { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId }) } |
        Should -Throw "*payload field '$Kind'*nothing was removed*"
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing ou field'; Field = 'ou'; Payload = [pscustomobject]@{ action = 'Remove-EntraAUGroupMember'; group = '33333333-3333-3333-3333-333333333333' } }
        @{ Case = 'an empty ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = '  '; group = '33333333-3333-3333-3333-333333333333' } }
        @{ Case = 'a unit display name'; Field = 'ou'; Payload = [pscustomobject]@{ ou = 'Region North'; group = '33333333-3333-3333-3333-333333333333' } }
        @{ Case = 'a control character in the ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = "22222222-2222-2222-`n2222-222222222222"; group = '33333333-3333-3333-3333-333333333333' } }
        @{ Case = 'a path in the ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = '22222222-2222-2222-2222-222222222222/members'; group = '33333333-3333-3333-3333-333333333333' } }
        @{ Case = 'a query string in the ou'; Field = 'ou'; Payload = [pscustomobject]@{ ou = '22222222-2222-2222-2222-222222222222?$select=id'; group = '33333333-3333-3333-3333-333333333333' } }
        @{ Case = 'a missing group field'; Field = 'group'; Payload = [pscustomobject]@{ ou = '22222222-2222-2222-2222-222222222222' } }
        @{ Case = 'an empty group'; Field = 'group'; Payload = [pscustomobject]@{ ou = '22222222-2222-2222-2222-222222222222'; group = '   ' } }
        @{ Case = 'a group display name'; Field = 'group'; Payload = [pscustomobject]@{ ou = '22222222-2222-2222-2222-222222222222'; group = 'Sales' } }
        @{ Case = 'a control character in the group'; Field = 'group'; Payload = [pscustomobject]@{ ou = '22222222-2222-2222-2222-222222222222'; group = "33333333-3333-3333-`t3333-333333333333" } }
        @{ Case = 'an escaped character in the group'; Field = 'group'; Payload = [pscustomobject]@{ ou = '22222222-2222-2222-2222-222222222222'; group = '33333333-3333-3333-3333-33333333%2F33' } }
        @{ Case = 'a path in the group'; Field = 'group'; Payload = [pscustomobject]@{ ou = '22222222-2222-2222-2222-222222222222'; group = '33333333-3333-3333-3333-333333333333/owners' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field '$Field'*Correct the ServiceNow record."
        Should -Invoke Get-MgDirectoryAdministrativeUnit -Times 0 -Exactly
        Should -Invoke Get-MgGroup -Times 0 -Exactly
        Should -Invoke Remove-MgDirectoryAdministrativeUnitMemberByRef -Times 0 -Exactly
    }

    It 'never logs the payload' {
        Mock Remove-MgDirectoryAdministrativeUnitMemberByRef {
            throw (New-GraphError 'Request_ResourceNotFound' 'RemoveMgDirectoryAdministrativeUnitMemberDirectoryObjectByRef_Delete')
        }

        & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = $script:GroupId; note = 'should not appear' })
        $refused = { & $script:Body $script:Job ([pscustomobject]@{ ou = $script:UnitId; group = 'should not appear' }) } |
        Should -Throw -PassThru

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
        $refused.Exception.Message | Should -Not -Match 'should not appear'
    }
}
