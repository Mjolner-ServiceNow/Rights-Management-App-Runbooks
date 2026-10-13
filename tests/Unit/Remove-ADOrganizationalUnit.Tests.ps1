#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the ActiveDirectory module, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the AD
# cmdlets it calls. The two refusals, protected and not empty, are what this runbook adds
# over 1.0, which cleared the protection and deleted.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Remove-ADOrganizationalUnit.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    if (-not ('RmaTest.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition 'namespace RmaTest { public class ADIdentityNotFoundException : System.Exception { public ADIdentityNotFoundException(string m) : base(m) {} } }'
    }

    function global:Get-ADOrganizationalUnit {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        param($Identity, $Properties, $Server, [pscredential] $Credential)
    }
    function global:Get-ADObject {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        param($SearchBase, $SearchScope, $Filter, $ResultSetSize, $Server, [pscredential] $Credential)
    }
    function global:Remove-ADOrganizationalUnit {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, [switch] $Recursive, $Server, [pscredential] $Credential)
        $null = $PSCmdlet.ShouldProcess("$Identity", 'Remove')
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-ADOrganizationalUnit, Function:\Get-ADObject, Function:\Remove-ADOrganizationalUnit -ErrorAction SilentlyContinue
}

Describe 'Remove-ADOrganizationalUnit' -Tag 'Unit' {

    BeforeEach {
        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:server = @{
            Server     = 'dc01.contoso.com'
            Credential = [pscredential]::new('CONTOSO\svc-rma', [securestring]::new())
        }
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:OuGuid = [guid]'66666666-6666-6666-6666-666666666666'
        $script:OuDn = 'OU=Old,OU=Managed,DC=contoso,DC=com'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Remove-ADOrganizationalUnit {}
        Mock Get-ADObject {}
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = $script:OuDn; ObjectGUID = $script:OuGuid; ProtectedFromAccidentalDeletion = $false } }
    }

    It 'handles the Remove-ADOrganizationalUnit command' {
        $script:Command | Should -Be 'Remove-ADOrganizationalUnit'
    }

    It 'deletes an empty, unprotected OU by objectGUID, never as a tree' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Remove-ADOrganizationalUnit'; organizationalunit = " $script:OuDn " })

        Should -Invoke Get-ADOrganizationalUnit -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $script:OuDn -and $Properties -contains 'ProtectedFromAccidentalDeletion' -and $Server -eq 'dc01.contoso.com'
        }
        Should -Invoke Get-ADObject -Times 1 -Exactly -ParameterFilter {
            $SearchBase -eq $script:OuDn -and $SearchScope -eq 'OneLevel' -and $ResultSetSize -eq 1
        }
        Should -Invoke Remove-ADOrganizationalUnit -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $script:OuGuid -and -not $Recursive -and $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma'
        }
        $script:Logged[-1].Message | Should -Be 'Organizational unit deleted'
        $script:Logged[-1].Data.organizationalUnit | Should -Be $script:OuDn
    }

    It 'refuses a protected OU, and does not try to clear the protection' {
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = $script:OuDn; ObjectGUID = $script:OuGuid; ProtectedFromAccidentalDeletion = $true } }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:OuDn }) } |
        Should -Throw "*'$script:OuDn' is protected from accidental deletion. An administrator must remove the protection*"
        Should -Invoke Remove-ADOrganizationalUnit -Times 0 -Exactly
    }

    It 'refuses an OU that is not empty' {
        Mock Get-ADObject { [pscustomobject]@{ DistinguishedName = "CN=Staff,$script:OuDn" } }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:OuDn }) } |
        Should -Throw "*'$script:OuDn' is not empty. Move or delete what it holds first*"
        Should -Invoke Remove-ADOrganizationalUnit -Times 0 -Exactly
    }

    It 'completes, with a warning, when the OU does not exist' {
        # docs/DECISIONS.md D15: the outcome asked for is already true.
        Mock Get-ADOrganizationalUnit { throw [RmaTest.ADIdentityNotFoundException]::new('Cannot find an object') }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = 'OU=Gone,DC=contoso,DC=com' }) } | Should -Not -Throw

        Should -Invoke Remove-ADOrganizationalUnit -Times 0 -Exactly
        $script:Logged[-1].Level | Should -Be 'Warning'
        $script:Logged[-1].Data.organizationalUnit | Should -Be 'OU=Gone,DC=contoso,DC=com'
    }

    It 'fails when the lookup fails for any other reason' {
        Mock Get-ADOrganizationalUnit { throw 'The server is not operational.' }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:OuDn }) } | Should -Throw 'The server is not operational.'
    }

    It 'fails with the directory''s reason when the delete is refused' {
        Mock Remove-ADOrganizationalUnit { throw 'Access is denied.' }

        { & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:OuDn }) } | Should -Throw 'Access is denied.'
    }

    It 'rejects <Case> before contacting the directory' -ForEach @(
        @{ Case = 'a missing organizationalunit'; Payload = [pscustomobject]@{ action = 'Remove-ADOrganizationalUnit' } }
        @{ Case = 'an empty organizationalunit'; Payload = [pscustomobject]@{ organizationalunit = ' ' } }
        @{ Case = 'a control character'; Payload = [pscustomobject]@{ organizationalunit = "OU=x`nDC=y" } }
    ) {
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field 'organizationalunit'*"
        Should -Invoke Get-ADOrganizationalUnit -Times 0 -Exactly
    }

    It 'never logs the payload' {
        & $script:Body $script:Job ([pscustomobject]@{ organizationalunit = $script:OuDn; note = 'should not appear' })

        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
    }
}
