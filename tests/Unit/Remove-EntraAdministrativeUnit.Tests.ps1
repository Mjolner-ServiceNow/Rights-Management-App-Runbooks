#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft.Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the two
# Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-EntraAdministrativeUnit.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Get-MgDirectoryAdministrativeUnit {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($AdministrativeUnitId, $Property)
    }
    function global:Remove-MgDirectoryAdministrativeUnit {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($AdministrativeUnitId)
        $null = $PSCmdlet.ShouldProcess("$AdministrativeUnitId", 'Remove')
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
    Remove-Item -Path Function:\Get-MgDirectoryAdministrativeUnit, Function:\Remove-MgDirectoryAdministrativeUnit -ErrorAction SilentlyContinue
}

Describe 'Remove-EntraAdministrativeUnit' -Tag 'Unit' {

    BeforeEach {
        $script:Id = '77777777-7777-7777-7777-777777777777'
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-MgDirectoryAdministrativeUnit {}
        Mock Get-MgDirectoryAdministrativeUnit {
            [pscustomobject]@{ Id = '77777777-7777-7777-7777-777777777777'; DisplayName = 'Contoso North' }
        }
    }

    It 'handles the Remove-EntraAdministrativeUnit command' {
        $script:Command | Should -Be 'Remove-EntraAdministrativeUnit'
    }

    It 'looks the administrative unit up and deletes it by the object id Graph returned' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-EntraAdministrativeUnit'; organizationalunit = " $($script:Id) " })

        Should -Invoke Get-MgDirectoryAdministrativeUnit -Times 1 -Exactly -ParameterFilter { $AdministrativeUnitId -eq $script:Id }
        Should -Invoke Remove-MgDirectoryAdministrativeUnit -Times 1 -Exactly -ParameterFilter { $AdministrativeUnitId -eq $script:Id }
        $script:Logged[-1].Level | Should -Be 'Information'
        $script:Logged[-1].Message | Should -Be 'Entra administrative unit deleted'
        $script:Logged[-1].Data.displayName | Should -Be 'Contoso North'
        $script:Logged[-1].Data.id | Should -Be $script:Id
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'accepts an object id in upper case' {
        & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = 'ABCDEF01-2345-6789-ABCD-EF0123456789' })

        Should -Invoke Get-MgDirectoryAdministrativeUnit -Times 1 -Exactly -ParameterFilter { $AdministrativeUnitId -eq 'ABCDEF01-2345-6789-ABCD-EF0123456789' }
        Should -Invoke Remove-MgDirectoryAdministrativeUnit -Times 1 -Exactly -ParameterFilter { $AdministrativeUnitId -eq $script:Id }
    }

    It 'completes, with a warning, when the administrative unit does not exist' {
        # docs/DECISIONS.md D15: the outcome asked for is already true.
        Mock Get-MgDirectoryAdministrativeUnit { throw (New-GraphError 'Request_ResourceNotFound' 'GetMgDirectoryAdministrativeUnit_Get') }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:Id }) } | Should -Not -Throw

        Should -Invoke Remove-MgDirectoryAdministrativeUnit -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not found' }
        $script:Logged[-1].Data.administrativeUnit | Should -Be $script:Id
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'completes, with a warning, when the administrative unit is deleted between the lookup and the delete' {
        Mock Remove-MgDirectoryAdministrativeUnit { throw (New-GraphError 'Request_ResourceNotFound' 'RemoveMgDirectoryAdministrativeUnit_Delete') }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:Id }) } | Should -Not -Throw

        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not found' }
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra administrative unit deleted' }
        $script:Logged[-1].Data.id | Should -Be $script:Id
    }

    It 'fails when the lookup fails for any other reason' {
        Mock Get-MgDirectoryAdministrativeUnit { throw (New-GraphError 'Authorization_RequestDenied' 'GetMgDirectoryAdministrativeUnit_Get') }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:Id }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Remove-MgDirectoryAdministrativeUnit -Times 0 -Exactly
    }

    It 'fails with Graph''s reason when the delete is refused' {
        Mock Remove-MgDirectoryAdministrativeUnit { throw (New-GraphError 'Authorization_RequestDenied' 'RemoveMgDirectoryAdministrativeUnit_Delete') }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:Id }) } | Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Message -eq 'Entra administrative unit deleted' }
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing organizationalunit field'; Payload = [pscustomobject]@{ action = 'Remove-EntraAdministrativeUnit' } }
        @{ Case = 'an empty organizationalunit'; Payload = [pscustomobject]@{ organizationalunit = '   ' } }
        @{ Case = 'a display name'; Payload = [pscustomobject]@{ organizationalunit = 'Contoso North' } }
        @{ Case = 'a line feed'; Payload = [pscustomobject]@{ organizationalunit = "77777777-7777-7777`n-7777-777777777777" } }
        @{ Case = 'a tab'; Payload = [pscustomobject]@{ organizationalunit = "77777777-7777-7777-7777-77777777777`t7" } }
        @{ Case = 'a path separator'; Payload = [pscustomobject]@{ organizationalunit = '77777777-7777-7777-7777-777777777777/members' } }
        @{ Case = 'an escaped character'; Payload = [pscustomobject]@{ organizationalunit = '77777777-7777-7777-7777-777777777777%2Fmembers' } }
        @{ Case = 'a query string'; Payload = [pscustomobject]@{ organizationalunit = '77777777-7777-7777-7777-777777777777?$select=id' } }
        @{ Case = 'an AD distinguished name'; Payload = [pscustomobject]@{ organizationalunit = 'OU=North,DC=contoso,DC=com' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field 'organizationalunit'*Correct the ServiceNow record."
        Should -Invoke Get-MgDirectoryAdministrativeUnit -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:Id; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
