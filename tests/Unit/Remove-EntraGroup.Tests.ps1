#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft.Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the two
# Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-EntraGroup.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Get-MgGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($GroupId, $Property)
    }
    function global:Remove-MgGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($GroupId)
        $null = $PSCmdlet.ShouldProcess("$GroupId", 'Remove')
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
    Remove-Item -Path Function:\Get-MgGroup, Function:\Remove-MgGroup -ErrorAction SilentlyContinue
}

Describe 'Remove-EntraGroup' -Tag 'Unit' {

    BeforeEach {
        $script:Id = '66666666-6666-6666-6666-666666666666'
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-MgGroup {}
        Mock Get-MgGroup {
            [pscustomobject]@{ Id = '66666666-6666-6666-6666-666666666666'; DisplayName = 'Contoso Sales'; OnPremisesSyncEnabled = $null }
        }
    }

    It 'handles the Remove-EntraGroup command' {
        $script:Command | Should -Be 'Remove-EntraGroup'
    }

    It 'looks the group up and deletes it by the object id Graph returned' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-EntraGroup'; group = " $($script:Id) " })

        Should -Invoke Get-MgGroup -Times 1 -Exactly -ParameterFilter {
            $GroupId -eq $script:Id -and $Property -contains 'onPremisesSyncEnabled'
        }
        Should -Invoke Remove-MgGroup -Times 1 -Exactly -ParameterFilter { $GroupId -eq $script:Id }
        $script:Logged[-1].Level | Should -Be 'Information'
        $script:Logged[-1].Message | Should -Be 'Entra group deleted'
        $script:Logged[-1].Data.displayName | Should -Be 'Contoso Sales'
        $script:Logged[-1].Data.id | Should -Be $script:Id
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'accepts an object id in upper case' {
        & $script:Body $script:Job ([pscustomobject]@{ group = 'ABCDEF01-2345-6789-ABCD-EF0123456789' })

        Should -Invoke Get-MgGroup -Times 1 -Exactly -ParameterFilter { $GroupId -eq 'ABCDEF01-2345-6789-ABCD-EF0123456789' }
        Should -Invoke Remove-MgGroup -Times 1 -Exactly -ParameterFilter { $GroupId -eq $script:Id }
    }

    It 'deletes a cloud-only group whose sync flag is false' {
        Mock Get-MgGroup { [pscustomobject]@{ Id = '66666666-6666-6666-6666-666666666666'; DisplayName = 'Contoso Sales'; OnPremisesSyncEnabled = $false } }

        & $script:Body $script:Job ([pscustomobject]@{ group = $script:Id })

        Should -Invoke Remove-MgGroup -Times 1 -Exactly
    }

    It 'completes at once, with a warning, when the group is in deleted items' {
        # docs/DECISIONS.md D15: the outcome asked for is already true. D19: deleted items
        # tell gone from not replicated yet.
        Mock Get-MgGroup { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgGroup_Get') }
        Mock Test-RmaDeletedDirectoryObject { $true }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:Id }) } | Should -Not -Throw

        Should -Invoke Remove-MgGroup -Times 0 -Exactly
        Should -Invoke Test-RmaDeletedDirectoryObject -Times 1 -Exactly -ParameterFilter { $Id -eq $script:Id }
        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not found' }
        $script:Logged[-1].Data.group | Should -Be $script:Id
        $script:Logged[-1].Data.inDeletedItems | Should -BeTrue
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'asks the loop to run it again, and to complete it then, when the group is found neither live nor in deleted items' {
        # D19: it may have been created moments ago and not have reached Graph yet.
        Mock Get-MgGroup { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgGroup_Get') }
        Mock Test-RmaDeletedDirectoryObject { $false }

        $caught = $null
        try { & $script:Body $script:Job ([pscustomobject]@{ group = $script:Id }) } catch { $caught = $_ }

        $caught.FullyQualifiedErrorId | Should -BeLike 'RmaJobRetry,*'
        $caught.Exception.Message | Should -BeLike '*not found; nothing to delete'
        $caught.TargetObject.CompleteWhenExhausted | Should -BeTrue
        Should -Invoke Remove-MgGroup -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 0 -Exactly
    }

    It 'completes, with a warning, when the group is deleted between the lookup and the delete' {
        Mock Remove-MgGroup { throw (New-GraphError 'Request_ResourceNotFound' 'RemoveMgGroup_Delete') }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:Id }) } | Should -Not -Throw

        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not found' }
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra group deleted' }
        $script:Logged[-1].Data.id | Should -Be $script:Id
    }

    It 'refuses a group synchronised from on-premises AD without deleting it' {
        Mock Get-MgGroup { [pscustomobject]@{ Id = '66666666-6666-6666-6666-666666666666'; DisplayName = 'Contoso Sales'; OnPremisesSyncEnabled = $true } }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:Id }) } | Should -Throw '*synchronised from on-premises*Remove-ADGroup*'
        Should -Invoke Remove-MgGroup -Times 0 -Exactly
    }

    It 'fails when the lookup fails for any other reason' {
        Mock Get-MgGroup { throw (New-GraphError 'Authorization_RequestDenied' 'GetMgGroup_Get') }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:Id }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Remove-MgGroup -Times 0 -Exactly
    }

    It 'fails with Graph''s reason when the delete is refused' {
        Mock Remove-MgGroup { throw (New-GraphError 'Authorization_RequestDenied' 'RemoveMgGroup_Delete') }

        { & $script:Body $script:Job ([pscustomobject]@{ group = $script:Id }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra group deleted' }
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing group field'; Payload = [pscustomobject]@{ action = 'Remove-EntraGroup' } }
        @{ Case = 'an empty group'; Payload = [pscustomobject]@{ group = '   ' } }
        @{ Case = 'a display name'; Payload = [pscustomobject]@{ group = 'Contoso Sales' } }
        @{ Case = 'a line feed'; Payload = [pscustomobject]@{ group = "66666666-6666-6666`n-6666-666666666666" } }
        @{ Case = 'a tab'; Payload = [pscustomobject]@{ group = "66666666-6666-6666-6666-66666666666`t6" } }
        @{ Case = 'a path separator'; Payload = [pscustomobject]@{ group = '66666666-6666-6666-6666-666666666666/members' } }
        @{ Case = 'an escaped character'; Payload = [pscustomobject]@{ group = '66666666-6666-6666-6666-666666666666%2Fmembers' } }
        @{ Case = 'a query string'; Payload = [pscustomobject]@{ group = '66666666-6666-6666-6666-666666666666?$select=id' } }
        @{ Case = 'a mail address'; Payload = [pscustomobject]@{ group = 'sales@contoso.com' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field 'group'*Correct the ServiceNow record."
        Should -Invoke Get-MgGroup -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ group = $script:Id; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
