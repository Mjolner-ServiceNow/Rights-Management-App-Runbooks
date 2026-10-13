#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the ActiveDirectory module, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the AD
# cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-ADGroupMember.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    if (-not ('RmaTest.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition 'namespace RmaTest { public class ADIdentityNotFoundException : System.Exception { public ADIdentityNotFoundException(string m) : base(m) {} } }'
    }

    function global:Get-ADGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        param($Identity, $Server, [pscredential] $Credential)
    }
    function global:Get-ADUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        param($Identity, $Properties, $Server, [pscredential] $Credential)
    }
    function global:Remove-ADGroupMember {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $Members, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Remove member')
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-ADGroup, Function:\Get-ADUser, Function:\Remove-ADGroupMember -ErrorAction SilentlyContinue
}

Describe 'Remove-ADGroupMember' -Tag 'Unit' {

    BeforeEach {
        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:server = @{
            Server     = 'dc01.contoso.com'
            Credential = [pscredential]::new('CONTOSO\svc-rma', [securestring]::new())
        }
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:GroupGuid = [guid]'55555555-5555-5555-5555-555555555555'
        $script:UserGuid = [guid]'44444444-4444-4444-4444-444444444444'
        $script:GroupDn = 'CN=Staff,OU=Groups,DC=contoso,DC=com'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-ADGroupMember {}
        Mock Get-ADGroup { [pscustomobject]@{ SamAccountName = 'staff'; ObjectGUID = $script:GroupGuid; DistinguishedName = $script:GroupDn } }
        Mock Get-ADUser {
            [pscustomobject]@{ SamAccountName = 'jdoe'; ObjectGUID = $script:UserGuid; MemberOf = @('CN=Other,OU=Groups,DC=contoso,DC=com', $script:GroupDn.ToUpperInvariant()) }
        }
    }

    It 'handles the Remove-ADGroupMember command' {
        $script:Command | Should -Be 'Remove-ADGroupMember'
    }

    It 'removes a member by objectGUID, through the given domain controller and credential' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-ADGroupMember'; group = ' staff '; user = ' jdoe ' })

        Should -Invoke Get-ADGroup -Times 1 -Exactly -ParameterFilter { $Identity -eq 'staff' -and $Server -eq 'dc01.contoso.com' }
        Should -Invoke Get-ADUser -Times 1 -Exactly -ParameterFilter { $Identity -eq 'jdoe' -and $Properties -contains 'MemberOf' }
        Should -Invoke Remove-ADGroupMember -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $script:GroupGuid -and $Members -eq $script:UserGuid -and
            $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        $script:Logged[-1].Message | Should -Be 'AD group member removed'
        $script:Logged[-1].Data.group | Should -Be 'staff'
        $script:Logged[-1].Data.user | Should -Be 'jdoe'
    }

    It 'completes without change when the user is not a member' {
        Mock Get-ADUser { [pscustomobject]@{ SamAccountName = 'jdoe'; ObjectGUID = $script:UserGuid; MemberOf = @('CN=Other,OU=Groups,DC=contoso,DC=com') } }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; user = 'jdoe' }) } | Should -Not -Throw

        Should -Invoke Remove-ADGroupMember -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Match 'not a member'
    }

    It 'completes without change for a user in no groups at all' {
        Mock Get-ADUser { [pscustomobject]@{ SamAccountName = 'jdoe'; ObjectGUID = $script:UserGuid; MemberOf = $null } }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; user = 'jdoe' }) } | Should -Not -Throw
        Should -Invoke Remove-ADGroupMember -Times 0 -Exactly
    }

    It 'completes, with a warning, when the <Missing> does not exist' -ForEach @(
        @{ Missing = 'group'; Message = 'AD group not found*' }
        @{ Missing = 'user'; Message = 'AD user not found*' }
    ) {
        # docs/DECISIONS.md D15: the membership asked to be gone does not exist.
        if ($Missing -eq 'group') { Mock Get-ADGroup { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object') } }
        else { Mock Get-ADUser { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object') } }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; user = 'jdoe' }) } | Should -Not -Throw

        Should -Invoke Remove-ADGroupMember -Times 0 -Exactly
        $script:Logged[-1].Level | Should -Be 'Warning'
        $script:Logged[-1].Message | Should -BeLike $Message
        $script:Logged[-1].Data.group | Should -Be 'staff'
        $script:Logged[-1].Data.user | Should -Be 'jdoe'
    }

    It 'fails when a lookup fails for any other reason' {
        Mock Get-ADUser { throw 'The server is not operational.' }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; user = 'jdoe' }) } | Should -Throw 'The server is not operational.'
        Should -Invoke Remove-ADGroupMember -Times 0 -Exactly
    }

    It 'fails with the directory''s reason when the removal is refused' {
        Mock Remove-ADGroupMember { throw 'Insufficient access rights to perform the operation.' }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; user = 'jdoe' }) } | Should -Throw 'Insufficient access rights*'
    }

    It 'rejects <Case> before contacting the directory' -ForEach @(
        @{ Case = 'a missing group'; Payload = [pscustomobject]@{ user = 'jdoe' }; Field = 'group' }
        @{ Case = 'a missing user'; Payload = [pscustomobject]@{ group = 'staff' }; Field = 'user' }
        @{ Case = 'an empty group'; Payload = [pscustomobject]@{ group = ' '; user = 'jdoe' }; Field = 'group' }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ group = 'staff'; user = "jdoe`nx" }; Field = 'user' }
    ) {
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field '$Field'*"
        Should -Invoke Get-ADGroup -Times 0 -Exactly
        Should -Invoke Get-ADUser -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; user = 'jdoe'; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
