#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the ActiveDirectory module, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the AD
# cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Move-ADGroupToOrganizationalUnit.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    if (-not ('RmaTest.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition 'namespace RmaTest { public class ADIdentityNotFoundException : System.Exception { public ADIdentityNotFoundException(string m) : base(m) {} } }'
    }

    function global:Get-ADGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        param($Identity, $Server, [pscredential] $Credential)
    }
    function global:Get-ADOrganizationalUnit {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        param($Identity, $Server, [pscredential] $Credential)
    }
    function global:Move-ADObject {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $TargetPath, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Move')
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-ADGroup, Function:\Get-ADOrganizationalUnit, Function:\Move-ADObject -ErrorAction SilentlyContinue
}

Describe 'Move-ADGroupToOrganizationalUnit' -Tag 'Unit' {

    BeforeEach {
        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:server = @{
            Server     = 'dc01.contoso.com'
            Credential = [pscredential]::new('CONTOSO\svc-rma', [securestring]::new())
        }
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:GroupGuid = [guid]'55555555-5555-5555-5555-555555555555'
        $script:Target = 'OU=Target,OU=Groups,DC=contoso,DC=com'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Move-ADObject {}
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = $script:Target } }
        Mock Get-ADGroup { [pscustomobject]@{ SamAccountName = 'staff'; ObjectGUID = $script:GroupGuid; DistinguishedName = 'CN=Staff,OU=Old,DC=contoso,DC=com' } }
    }

    It 'handles the Move-ADGroupToOrganizationalUnit command' {
        $script:Command | Should -Be 'Move-ADGroupToOrganizationalUnit'
    }

    It 'moves the group by objectGUID into the target OU, through the given domain controller and credential' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Move-ADGroupToOrganizationalUnit'; group = ' staff '; ou = " $script:Target " })

        Should -Invoke Get-ADOrganizationalUnit -Times 1 -Exactly -ParameterFilter { $Identity -eq $script:Target -and $Server -eq 'dc01.contoso.com' }
        Should -Invoke Move-ADObject -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $script:GroupGuid -and $TargetPath -eq $script:Target -and
            $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        $script:Logged[-1].Message | Should -Be 'AD group moved'
        $script:Logged[-1].Data.from | Should -Be 'OU=Old,DC=contoso,DC=com'
        $script:Logged[-1].Data.to | Should -Be $script:Target
    }

    It 'completes without change when the group is already in the target OU' {
        Mock Get-ADGroup { [pscustomobject]@{ SamAccountName = 'staff'; ObjectGUID = $script:GroupGuid; DistinguishedName = "CN=Staff,$($script:Target.ToLowerInvariant())" } }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; ou = $script:Target }) } | Should -Not -Throw

        Should -Invoke Move-ADObject -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Match 'already in the target OU'
    }

    It 'finds the parent of a group whose name contains an escaped comma' {
        Mock Get-ADGroup { [pscustomobject]@{ SamAccountName = 'sales'; ObjectGUID = $script:GroupGuid; DistinguishedName = "CN=Sales\, Nordic,$script:Target" } }

        & $script:Body $script:Job ([pscustomobject]@{ group = 'sales'; ou = $script:Target })

        Should -Invoke Move-ADObject -Times 0 -Exactly
    }

    It 'fails with an actionable message when the <Missing> does not exist' -ForEach @(
        @{ Missing = 'target OU'; Message = "No organizational unit 'OU=Gone,DC=contoso,DC=com' on dc01.contoso.com*" }
        @{ Missing = 'group'; Message = "No Active Directory group 'staff' on dc01.contoso.com*" }
    ) {
        if ($Missing -eq 'group') { Mock Get-ADGroup { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object') } }
        else { Mock Get-ADOrganizationalUnit { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object') } }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; ou = 'OU=Gone,DC=contoso,DC=com' }) } | Should -Throw $Message
        Should -Invoke Move-ADObject -Times 0 -Exactly
    }

    It 'fails with the directory''s reason when the move is refused' {
        Mock Move-ADObject { throw 'Access is denied.' }

        { & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; ou = $script:Target }) } | Should -Throw 'Access is denied.'
    }

    It 'rejects <Case> before contacting the directory' -ForEach @(
        @{ Case = 'a missing group'; Payload = [pscustomobject]@{ ou = 'OU=Target,DC=contoso,DC=com' }; Field = 'group' }
        @{ Case = 'a missing ou'; Payload = [pscustomobject]@{ group = 'staff' }; Field = 'ou' }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ group = 'staff'; ou = "OU=x`nDC=y" }; Field = 'ou' }
    ) {
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field '$Field'*"
        Should -Invoke Get-ADOrganizationalUnit -Times 0 -Exactly
        Should -Invoke Get-ADGroup -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ group = 'staff'; ou = $script:Target; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
