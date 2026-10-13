#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the ActiveDirectory module, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the two
# AD cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-ADGroup.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    if (-not ('RmaTest.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition 'namespace RmaTest { public class ADIdentityNotFoundException : System.Exception { public ADIdentityNotFoundException(string m) : base(m) {} } }'
    }

    function global:Get-ADGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Identity, $Properties, $Server, [pscredential] $Credential)
    }
    function global:Remove-ADGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Remove')
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-ADGroup, Function:\Remove-ADGroup -ErrorAction SilentlyContinue
}

Describe 'Remove-ADGroup' -Tag 'Unit' {

    BeforeEach {
        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:server = @{
            Server     = 'dc01.contoso.com'
            Credential = [pscredential]::new('CONTOSO\svc-rma', [securestring]::new())
        }
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-ADGroup {}
        Mock Get-ADGroup {
            [pscustomobject]@{ SamAccountName = 'staff'; ObjectGUID = [guid]'44444444-4444-4444-4444-444444444444' }
        }
    }

    It 'handles the Remove-ADGroup command' {
        $script:Command | Should -Be 'Remove-ADGroup'
    }

    It 'deletes the group by its objectGUID, through the given domain controller and credential' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-ADGroup'; group = ' staff ' })

        Should -Invoke Get-ADGroup -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'staff' -and $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        # By GUID, not by the payload's name: the object looked up is the object deleted.
        Should -Invoke Remove-ADGroup -Times 1 -Exactly -ParameterFilter {
            $Identity -eq [guid]'44444444-4444-4444-4444-444444444444' -and $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        $script:Logged[-1].Message | Should -Be 'AD group deleted'
        $script:Logged[-1].Data.samAccountName | Should -Be 'staff'
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'completes, with a warning, when the group does not exist' {
        # docs/DECISIONS.md D15: the outcome asked for is already true.
        Mock Get-ADGroup { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object with identity') }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'nobody' }) } | Should -Not -Throw

        Should -Invoke Remove-ADGroup -Times 0 -Exactly
        Should -Invoke Write-RmaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'not found' }
        $script:Logged[-1].Data.group | Should -Be 'nobody'
    }

    It 'fails when the lookup fails for any other reason' {
        Mock Get-ADGroup { throw 'The server is not operational.' }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff' }) } | Should -Throw 'The server is not operational.'
        Should -Invoke Remove-ADGroup -Times 0 -Exactly
    }

    It 'fails with the directory''s reason when the delete is refused' {
        Mock Remove-ADGroup { throw 'Access is denied.' }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff' }) } | Should -Throw 'Access is denied.'
    }

    It 'rejects <Case> before contacting the directory' -ForEach @(
        @{ Case = 'a missing group field'; Payload = [pscustomobject]@{ action = 'Remove-ADGroup' } }
        @{ Case = 'an empty group'; Payload = [pscustomobject]@{ group = '   ' } }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ group = "staff`n" + 'x' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field 'group'*"
        Should -Invoke Get-ADGroup -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
