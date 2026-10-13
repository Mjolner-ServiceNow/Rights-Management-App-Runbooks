#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook declares '#Requires -Modules ActiveDirectory', a Windows feature that no CI
# runner has, so the script itself cannot be run here. Its body is taken from the AST
# instead and run against stand-ins for the two AD cmdlets it calls. Everything around
# the body is the queue loop, which has its own tests.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force

    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Unlock-ADUser.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    # The exception Get-ADUser throws for an unknown identity. The runbook matches it by
    # type name, so a stand-in with the same name behaves as the real one does.
    if (-not ('RmaTest.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition 'namespace RmaTest { public class ADIdentityNotFoundException : System.Exception { public ADIdentityNotFoundException(string m) : base(m) {} } }'
    }

    # Stand-ins so Mock has a command to replace on a machine without ActiveDirectory.
    function global:Get-ADUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Identity, $Properties, $Server, [pscredential] $Credential)
    }
    function global:Unlock-ADAccount {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Unlock')
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-ADUser, Function:\Unlock-ADAccount -ErrorAction SilentlyContinue
}

Describe 'Unlock-ADUser' -Tag 'Unit' {

    BeforeEach {
        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:server = @{
            Server     = 'dc01.contoso.com'
            Credential = [pscredential]::new('CONTOSO\svc-rma', [securestring]::new())
        }
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Message = $Message; Data = $Data }) }
        Mock Unlock-ADAccount {}
        Mock Get-ADUser {
            [pscustomobject]@{ SamAccountName = 'jdoe'; ObjectGUID = [guid]'44444444-4444-4444-4444-444444444444'; LockedOut = $true }
        }
    }

    It 'handles the Unlock-ADUser command' {
        $script:Command | Should -Be 'Unlock-ADUser'
    }

    It 'unlocks a locked-out user, through the given domain controller and credential' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Unlock-ADUser'; user = ' jdoe ' })

        Should -Invoke Get-ADUser -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'jdoe' -and $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma' -and $Properties -contains 'LockedOut'
        }
        Should -Invoke Unlock-ADAccount -Times 1 -Exactly -ParameterFilter {
            $Identity.SamAccountName -eq 'jdoe' -and $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        $script:Logged[-1].Message | Should -Be 'AD user unlocked'
        $script:Logged[-1].Data.samAccountName | Should -Be 'jdoe'
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'completes without unlocking a user who is not locked out' {
        Mock Get-ADUser { [pscustomobject]@{ SamAccountName = 'jdoe'; ObjectGUID = [guid]::Empty; LockedOut = $false } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe' }) } | Should -Not -Throw

        Should -Invoke Unlock-ADAccount -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Match 'not locked out'
    }

    It 'fails with an actionable message when the user does not exist' {
        Mock Get-ADUser { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object with identity') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody' }) } |
        Should -Throw "No Active Directory user 'nobody' on dc01.contoso.com*"
        Should -Invoke Unlock-ADAccount -Times 0 -Exactly
    }

    It 'passes any other directory error through unchanged' {
        Mock Get-ADUser { throw 'The server has rejected the client credentials.' }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe' }) } | Should -Throw 'The server has rejected the client credentials.'
    }

    It 'rejects <Case> before contacting the directory' -ForEach @(
        @{ Case = 'a missing user field'; Payload = [pscustomobject]@{ action = 'Unlock-ADUser' } }
        @{ Case = 'an empty user'; Payload = [pscustomobject]@{ user = '   ' } }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ user = "jdoe`n" + 'x' } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field 'user'*"
        Should -Invoke Get-ADUser -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe'; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
