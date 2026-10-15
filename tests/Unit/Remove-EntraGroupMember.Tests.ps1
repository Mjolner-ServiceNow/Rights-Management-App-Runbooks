#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft.Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the
# three Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-EntraGroupMember.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Get-MgGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($GroupId, $Property)
    }
    function global:Get-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, $Property)
    }
    function global:Remove-MgGroupMemberByRef {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($GroupId, $DirectoryObjectId)
        $null = $PSCmdlet.ShouldProcess("$GroupId", 'Remove member')
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
    Remove-Item -Path Function:\Get-MgGroup, Function:\Get-MgUser, Function:\Remove-MgGroupMemberByRef -ErrorAction SilentlyContinue
}

Describe 'Remove-EntraGroupMember' -Tag 'Unit' {

    BeforeEach {
        $script:GroupId = '33333333-3333-3333-3333-333333333333'
        $script:UserId = '44444444-4444-4444-4444-444444444444'
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-MgGroupMemberByRef {}
        Mock Get-MgGroup {
            [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Sales' }
        }
        Mock Get-MgUser {
            [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = 'jdoe@contoso.com' }
        }
    }

    It 'handles the Remove-EntraGroupMember command' {
        $script:Command | Should -Be 'Remove-EntraGroupMember'
    }

    It 'removes the member by the object ids it looked up when the payload names a user principal name' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-EntraGroupMember'; group = " $script:GroupId "; user = ' jdoe@contoso.com ' })

        Should -Invoke Get-MgGroup -Times 1 -Exactly -ParameterFilter { $GroupId -eq $script:GroupId }
        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq 'jdoe@contoso.com' }
        # By id, not by the payload's name: the objects looked up are the objects changed.
        Should -Invoke Remove-MgGroupMemberByRef -Times 1 -Exactly -ParameterFilter {
            $GroupId -eq $script:GroupId -and $DirectoryObjectId -eq $script:UserId
        }
        $script:Logged[-1].Level | Should -Be 'Information'
        $script:Logged[-1].Message | Should -Be 'Entra group member removed'
        $script:Logged[-1].Data.group | Should -Be 'Sales'
        $script:Logged[-1].Data.groupId | Should -Be $script:GroupId
        $script:Logged[-1].Data.upn | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.userId | Should -Be $script:UserId
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'removes the member when the payload names the user by object id' {
        & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = $script:UserId })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:UserId }
        Should -Invoke Remove-MgGroupMemberByRef -Times 1 -Exactly -ParameterFilter {
            $GroupId -eq $script:GroupId -and $DirectoryObjectId -eq $script:UserId
        }
    }

    It 'matches object ids and the user principal name without regard to case' {
        Mock Get-MgGroup { [pscustomobject]@{ Id = 'abcdef00-3333-3333-3333-333333333333'; DisplayName = 'Sales' } }

        & $script:Body $script:Job ([pscustomobject]@{ group = 'ABCDEF00-3333-3333-3333-333333333333'; user = 'JDoe@Contoso.com' })

        Should -Invoke Remove-MgGroupMemberByRef -Times 1 -Exactly -ParameterFilter {
            $GroupId -eq 'abcdef00-3333-3333-3333-333333333333' -and $DirectoryObjectId -eq $script:UserId
        }
    }

    It 'accepts a guest user principal name and a name with an apostrophe' -ForEach @(
        @{ Upn = 'jane.doe_fabrikam.com#EXT#@contoso.onmicrosoft.com' }
        @{ Upn = "o'brien@contoso.com" }
    ) {
        Mock Get-MgUser { [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = $Upn } }

        & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = $Upn })

        Should -Invoke Remove-MgGroupMemberByRef -Times 1 -Exactly
    }

    It 'completes, with a warning, when the user is not a direct member (<Case>)' -ForEach @(
        # Usually the same not-found as a missing group.
        @{ Case = 'not found'; Code = 'Request_ResourceNotFound'; Text = 'Resource does not exist or one of its queried reference-property objects are not present.' }
        # Seen on the test tenant seconds after the membership was removed.
        @{ Case = 'bad request'; Code = 'Request_BadRequest'; Text = "One or more removed object references do not exist for the following modified properties: 'members'." }
    ) {
        Mock Remove-MgGroupMemberByRef { throw (New-GraphError $Code 'RemoveMgGroupMemberDirectoryObjectByRef_Delete' $Text) }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not a direct member' }
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra group member removed' }
        $script:Logged[-1].Data.groupId | Should -Be $script:GroupId
        $script:Logged[-1].Data.userId | Should -Be $script:UserId
    }

    It 'completes at once, with a warning, when the group is in deleted items' {
        # docs/DECISIONS.md D15: the outcome asked for is already true. D19: deleted items
        # tell gone from not replicated yet.
        Mock Get-MgGroup { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgGroup_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = 'jdoe@contoso.com' }) } | Should -Not -Throw

        Should -Invoke Remove-MgGroupMemberByRef -Times 0 -Exactly
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
        try { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = 'jdoe@contoso.com' }) } catch { $caught = $_ }

        $caught.FullyQualifiedErrorId | Should -BeLike 'RmaJobRetry,*'
        $caught.Exception.Message | Should -BeLike '*group*not found; the membership does not exist'
        $caught.TargetObject.CompleteWhenExhausted | Should -BeTrue
        Should -Invoke Remove-MgGroupMemberByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'completes at once, with a warning, when the user is in deleted items' {
        # docs/DECISIONS.md D15: the outcome asked for is already true. D19: deleted items
        # tell gone from not replicated yet.
        Mock Get-MgUser { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgUser_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = $script:UserId }) } | Should -Not -Throw

        Should -Invoke Remove-MgGroupMemberByRef -Times 0 -Exactly
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
        try { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = $script:UserId }) } catch { $caught = $_ }

        $caught.FullyQualifiedErrorId | Should -BeLike 'RmaJobRetry,*'
        $caught.Exception.Message | Should -BeLike '*user*not found; the membership does not exist'
        $caught.TargetObject.CompleteWhenExhausted | Should -BeTrue
        Should -Invoke Remove-MgGroupMemberByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'asks the loop to run it again without looking in deleted items for a user principal name' {
        # Entra rewrites a deleted user's UPN, so only an object id can be looked up there.
        Mock Get-MgUser { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgUser_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = 'nobody@contoso.com' }) } |
        Should -Throw "*'nobody@contoso.com' not found; the membership does not exist" -ErrorId 'RmaJobRetry,*'
        Should -Invoke Test-RmaDeletedDirectoryObject -Times 0 -Exactly
    }

    It 'fails when the <Cmdlet> lookup fails for any other reason' -ForEach @(
        @{ Cmdlet = 'Get-MgGroup'; Id = 'GetMgGroup_Get' }
        @{ Cmdlet = 'Get-MgUser'; Id = 'GetMgUser_Get' }
    ) {
        Mock $Cmdlet { throw (New-GraphError 'Authorization_RequestDenied' $Id) }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = 'jdoe@contoso.com' }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Remove-MgGroupMemberByRef -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'fails with Graph''s reason when the removal is refused' {
        # A group synced from Active Directory, for example.
        Mock Remove-MgGroupMemberByRef {
            throw (New-GraphError 'Request_BadRequest' 'RemoveMgGroupMemberDirectoryObjectByRef_Delete' 'Cannot update the members of a group synchronized from on-premises.')
        }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = 'jdoe@contoso.com' }) } | Should -Throw '*Request_BadRequest*on-premises*'
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'removes nothing when Graph returns a <Kind> other than the one named' -ForEach @(
        @{ Kind = 'group'; Cmdlet = 'Get-MgGroup'; Other = [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; DisplayName = 'Other' } }
        @{ Kind = 'user'; Cmdlet = 'Get-MgUser'; Other = [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; UserPrincipalName = 'someone.else@contoso.com' } }
    ) {
        Mock $Cmdlet { $Other }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = 'jdoe@contoso.com' }) } |
        Should -Throw "*payload field '$Kind'*nothing was removed*"
        Should -Invoke Remove-MgGroupMemberByRef -Times 0 -Exactly
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing group field'; Field = 'group'; Payload = [pscustomobject]@{ action = 'Remove-EntraGroupMember'; user = 'jdoe@contoso.com' } }
        @{ Case = 'an empty group'; Field = 'group'; Payload = [pscustomobject]@{ group = '  '; user = 'jdoe@contoso.com' } }
        @{ Case = 'a group display name'; Field = 'group'; Payload = [pscustomobject]@{ group = 'Sales'; user = 'jdoe@contoso.com' } }
        @{ Case = 'a control character in the group'; Field = 'group'; Payload = [pscustomobject]@{ group = "33333333-3333-3333-`n3333-333333333333"; user = 'jdoe@contoso.com' } }
        @{ Case = 'a path in the group'; Field = 'group'; Payload = [pscustomobject]@{ group = '33333333-3333-3333-3333-333333333333/owners'; user = 'jdoe@contoso.com' } }
        @{ Case = 'a missing user field'; Field = 'user'; Payload = [pscustomobject]@{ group = '33333333-3333-3333-3333-333333333333' } }
        @{ Case = 'an empty user'; Field = 'user'; Payload = [pscustomobject]@{ group = '33333333-3333-3333-3333-333333333333'; user = '   ' } }
        @{ Case = 'a control character in the user'; Field = 'user'; Payload = [pscustomobject]@{ group = '33333333-3333-3333-3333-333333333333'; user = "jdoe`n" + 'x@contoso.com' } }
        @{ Case = 'a path separator in the user'; Field = 'user'; Payload = [pscustomobject]@{ group = '33333333-3333-3333-3333-333333333333'; user = '44444444-4444-4444-4444-444444444444/manager' } }
        @{ Case = 'an escaped character in the user'; Field = 'user'; Payload = [pscustomobject]@{ group = '33333333-3333-3333-3333-333333333333'; user = 'jdoe%23x@contoso.com' } }
        @{ Case = 'a query string in the user'; Field = 'user'; Payload = [pscustomobject]@{ group = '33333333-3333-3333-3333-333333333333'; user = 'jdoe@contoso.com?$select=id' } }
        @{ Case = 'a user name without a domain'; Field = 'user'; Payload = [pscustomobject]@{ group = '33333333-3333-3333-3333-333333333333'; user = 'jdoe' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field '$Field'*Correct the ServiceNow record."
        Should -Invoke Get-MgGroup -Times 0 -Exactly
        Should -Invoke Get-MgUser -Times 0 -Exactly
        Should -Invoke Remove-MgGroupMemberByRef -Times 0 -Exactly
    }

    It 'never logs the payload' {
        Mock Remove-MgGroupMemberByRef { throw (New-GraphError 'Request_ResourceNotFound' 'RemoveMgGroupMemberDirectoryObjectByRef_Delete') }

        & $script:Body $script:Job ([pscustomobject]@{ group = $script:GroupId; user = 'jdoe@contoso.com'; note = 'should not appear' })
        $refused = { & $script:Body $script:Job ([pscustomobject]@{ group = 'should not appear'; user = 'jdoe@contoso.com' }) } |
        Should -Throw -PassThru

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
        $refused.Exception.Message | Should -Not -Match 'should not appear'
    }
}
