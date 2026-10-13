#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the ActiveDirectory module, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the AD
# cmdlets it calls. The payload carries a password: the tests that matter most are the
# ones that show it never reaches a log record or a message.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Set-ADUserPassword.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path
    $script:Secret = 'N3w-Pa55w0rd!'

    if (-not ('RmaTest.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition 'namespace RmaTest { public class ADIdentityNotFoundException : System.Exception { public ADIdentityNotFoundException(string m) : base(m) {} } }'
    }

    function global:Get-ADUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        param($Identity, $Properties, $Server, [pscredential] $Credential)
    }
    function global:Set-ADAccountPassword {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, [switch] $Reset, [securestring] $NewPassword, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Reset password')
    }
    function global:Set-ADUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, [bool] $ChangePasswordAtLogon, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Set')
    }
    function global:Unlock-ADAccount {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Unlock')
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-ADUser, Function:\Set-ADAccountPassword, Function:\Set-ADUser, Function:\Unlock-ADAccount -ErrorAction SilentlyContinue
}

Describe 'Set-ADUserPassword' -Tag 'Unit', 'Security' {

    BeforeEach {
        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:server = @{
            Server     = 'dc01.contoso.com'
            Credential = [pscredential]::new('CONTOSO\svc-rma', [securestring]::new())
        }
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:Guid = [guid]'44444444-4444-4444-4444-444444444444'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        $script:SentPassword = $null
        Mock Set-ADAccountPassword { $script:SentPassword = [pscredential]::new('x', $NewPassword).GetNetworkCredential().Password }
        Mock Set-ADUser {}
        Mock Unlock-ADAccount {}
        Mock Get-ADUser { [pscustomobject]@{ SamAccountName = 'jdoe'; ObjectGUID = $script:Guid } }
    }

    It 'handles the Set-ADUserPassword command' {
        $script:Command | Should -Be 'Set-ADUserPassword'
    }

    It 'resets the password by objectGUID, through the given domain controller and credential' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Set-ADUserPassword'; user = ' jdoe '; password = $script:Secret })

        Should -Invoke Get-ADUser -Times 1 -Exactly -ParameterFilter { $Identity -eq 'jdoe' -and $Server -eq 'dc01.contoso.com' }
        Should -Invoke Set-ADAccountPassword -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $script:Guid -and $Reset -and $NewPassword -is [securestring] -and
            $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        $script:SentPassword | Should -BeExactly $script:Secret
        Should -Invoke Set-ADUser -Times 0 -Exactly
        Should -Invoke Unlock-ADAccount -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Be 'AD user password reset'
        $script:Logged[-1].Data.mustChange | Should -BeFalse
    }

    It 'requires a change at next logon and unlocks when asked, with <Case>' -ForEach @(
        @{ Case = 'JSON booleans'; MustChange = $true; Unlock = $true }
        @{ Case = 'text'; MustChange = 'True'; Unlock = ' true ' }
    ) {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe'; password = $script:Secret; mustChange = $MustChange; unlock = $Unlock })

        Should -Invoke Set-ADUser -Times 1 -Exactly -ParameterFilter { $Identity -eq $script:Guid -and $ChangePasswordAtLogon -eq $true }
        Should -Invoke Unlock-ADAccount -Times 1 -Exactly -ParameterFilter { $Identity -eq $script:Guid -and $Server -eq 'dc01.contoso.com' }
        $script:Logged[-1].Data.mustChange | Should -BeTrue
        $script:Logged[-1].Data.unlock | Should -BeTrue
    }

    It 'leaves both alone when they are false' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe'; password = $script:Secret; mustChange = 'false'; unlock = $false })

        Should -Invoke Set-ADUser -Times 0 -Exactly
        Should -Invoke Unlock-ADAccount -Times 0 -Exactly
    }

    It 'rejects <Case> before contacting the directory' -ForEach @(
        @{ Case = 'a missing password'; Payload = [pscustomobject]@{ user = 'jdoe' }; Message = "*Payload field 'password'*" }
        @{ Case = 'an empty password'; Payload = [pscustomobject]@{ user = 'jdoe'; password = '' }; Message = "*Payload field 'password'*" }
        @{ Case = 'a missing user'; Payload = [pscustomobject]@{ password = 'x' }; Message = "*Payload field 'user'*" }
        @{ Case = 'a mustChange that is not a boolean'; Payload = [pscustomobject]@{ user = 'jdoe'; password = 'x'; mustChange = 'yes' }; Message = "*Payload field 'mustChange' must be true or false*" }
        @{ Case = 'an unlock that is not a boolean'; Payload = [pscustomobject]@{ user = 'jdoe'; password = 'x'; unlock = 1 }; Message = "*Payload field 'unlock' must be true or false*" }
    ) {
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw $Message
        Should -Invoke Get-ADUser -Times 0 -Exactly
        Should -Invoke Set-ADAccountPassword -Times 0 -Exactly
    }

    It 'fails, without resetting anything, when the user does not exist' {
        Mock Get-ADUser { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object with identity') }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'nobody'; password = $script:Secret }) } |
        Should -Throw "No Active Directory user 'nobody' on dc01.contoso.com*"
        Should -Invoke Set-ADAccountPassword -Times 0 -Exactly
    }

    It 'fails with the directory''s reason when the password is refused, and does not go on' {
        Mock Set-ADAccountPassword { throw 'The password does not meet the length, complexity, or history requirement of the domain.' }

        { & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe'; password = $script:Secret; mustChange = $true; unlock = $true }) } |
        Should -Throw '*does not meet the length, complexity*'
        Should -Invoke Set-ADUser -Times 0 -Exactly
        Should -Invoke Unlock-ADAccount -Times 0 -Exactly
    }

    It 'never puts the password into a log record or a message' {
        & $script:Body $script:Job ([pscustomobject]@{ user = 'jdoe'; password = $script:Secret; mustChange = $true; unlock = $true })
        $errors = foreach ($payload in @(
                [pscustomobject]@{ user = 'jdoe'; password = $script:Secret; mustChange = 'maybe' }
                [pscustomobject]@{ user = "bad`nuser"; password = $script:Secret })) {
            try { & $script:Body $script:Job $payload } catch { $_.Exception.Message }
        }

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match ([regex]::Escape($script:Secret))
        $errors.Count | Should -Be 2
        $errors | ForEach-Object { $_ | Should -Not -Match ([regex]::Escape($script:Secret)) }
    }
}
