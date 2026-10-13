#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the ActiveDirectory module, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the two
# AD cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Enable-ADUser.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    if (-not ('RmaTest.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition 'namespace RmaTest { public class ADIdentityNotFoundException : System.Exception { public ADIdentityNotFoundException(string m) : base(m) {} } }'
    }

    function global:Get-ADUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Identity, $Properties, $Server, [pscredential] $Credential)
    }
    function global:Enable-ADAccount {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Enable')
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-ADUser, Function:\Enable-ADAccount -ErrorAction SilentlyContinue
}

Describe 'Enable-ADUser' -Tag 'Unit' {

    BeforeEach {
        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:server = @{
            Server     = 'dc01.contoso.com'
            Credential = [pscredential]::new('CONTOSO\svc-rma', [securestring]::new())
        }
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Message = $Message; Data = $Data }) }
        Mock Enable-ADAccount {}
        Mock Get-ADUser {
            [pscustomobject]@{ SamAccountName = 'jdoe'; ObjectGUID = [guid]'44444444-4444-4444-4444-444444444444'; Enabled = $false }
        }
    }

    It 'handles the Enable-ADUser command' {
        $script:Command | Should -Be 'Enable-ADUser'
    }

    It 'enables a disabled user, through the given domain controller and credential' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Enable-ADUser'; user = ' jdoe ' })

        Should -Invoke Get-ADUser -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'jdoe' -and $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        Should -Invoke Enable-ADAccount -Times 1 -Exactly -ParameterFilter {
            $Identity.SamAccountName -eq 'jdoe' -and $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        $script:Logged[-1].Message | Should -Be 'AD user enabled'
        $script:Logged[-1].Data.samAccountName | Should -Be 'jdoe'
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'completes without change for a user who is already enabled' {
        Mock Get-ADUser { [pscustomobject]@{ SamAccountName = 'jdoe'; ObjectGUID = [guid]::Empty; Enabled = $true } }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe' }) } | Should -Not -Throw

        Should -Invoke Enable-ADAccount -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Match 'already enabled'
    }

    It 'fails with an actionable message when the user does not exist' {
        Mock Get-ADUser { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object with identity') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody' }) } |
        Should -Throw "No Active Directory user 'nobody' on dc01.contoso.com*"
        Should -Invoke Enable-ADAccount -Times 0 -Exactly
    }

    It 'fails with the directory''s own reason when the domain refuses to enable the account' {
        Mock Enable-ADAccount { throw 'The password does not meet the length, complexity, or history requirement of the domain.' }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe' }) } | Should -Throw '*does not meet the length, complexity*'
    }

    It 'rejects <Case> before contacting the directory' -ForEach @(
        @{ Case = 'a missing user field'; Payload = [pscustomobject]@{ action = 'Enable-ADUser' } }
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
