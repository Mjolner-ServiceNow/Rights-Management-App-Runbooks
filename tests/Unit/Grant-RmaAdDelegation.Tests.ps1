#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# scripts/Grant-RmaAdDelegation.ps1 writes permissions into Active Directory with dsacls.
# Under -WhatIf it writes nothing and returns every grant it would make, which is what
# these tests read. The point of the script is least privilege, so the guard against a
# broader right creeping in matters as much as the grants themselves.

BeforeAll {
    $script:Path = Join-Path $PSScriptRoot '../../scripts/Grant-RmaAdDelegation.ps1'
    $script:Ou = 'OU=Staff,DC=contoso,DC=com'

    function Get-Grant {
        param([string[]] $Scope, [string[]] $OrganizationalUnit = @($script:Ou), [string] $Server)
        $parameters = @{ ServiceAccount = 'CONTOSO\svc-rma'; OrganizationalUnit = $OrganizationalUnit; Scope = $Scope; WhatIf = $true }
        if ($Server) { $parameters['Server'] = $Server }
        & $script:Path @parameters
    }
}

Describe 'Grant-RmaAdDelegation' -Tag 'Unit', 'Security' {

    It 'grants <Scope> exactly these rights' -ForEach @(
        @{ Scope = 'Users'; Expected = @('/I:T CONTOSO\svc-rma:CCDC;user', '/I:S CONTOSO\svc-rma:RPWP;;user', '/I:S CONTOSO\svc-rma:CA;Reset Password;user') }
        @{ Scope = 'Groups'; Expected = @('/I:T CONTOSO\svc-rma:CCDC;group', '/I:S CONTOSO\svc-rma:RPWP;;group') }
        @{ Scope = 'OrganizationalUnits'; Expected = @('/I:T CONTOSO\svc-rma:CCDC;organizationalUnit', '/I:S CONTOSO\svc-rma:RPWP;;organizationalUnit') }
    ) {
        $grants = @(Get-Grant -Scope $Scope)

        $grants | ForEach-Object { '{0} {1}' -f $_.Arguments[1], $_.Arguments[3] } | Should -Be $Expected
        $grants.Arguments | Where-Object { $_ -eq $script:Ou } | Should -HaveCount $Expected.Count
        $grants | ForEach-Object { $_.Arguments[2] | Should -Be '/G' }
    }

    It 'never grants full control, write permissions or take ownership' {
        $rights = (Get-Grant -Scope Users, Groups, OrganizationalUnits).Arguments | Where-Object { $_ -like 'CONTOSO\*' }

        # GA is full control, WD write permissions, WO take ownership: each would let the
        # service account give itself anything.
        foreach ($right in $rights) {
            ($right -split ':', 2)[1].Split(';')[0] | Should -Not -Match 'GA|WD|WO|GW' -Because $right
        }
    }

    It 'grants every scope on every OU given, once' {
        $grants = @(Get-Grant -Scope Users, Users, Groups -OrganizationalUnit 'OU=A,DC=contoso,DC=com', 'OU=B,DC=contoso,DC=com')

        $grants.Count | Should -Be 10
        @($grants | Where-Object OrganizationalUnit -EQ 'OU=B,DC=contoso,DC=com').Count | Should -Be 5
    }

    It 'addresses a named domain controller' {
        (Get-Grant -Scope Groups -Server 'dc01.contoso.com')[0].Arguments[0] | Should -Be "\\dc01.contoso.com\$script:Ou"
    }

    It 'writes nothing under -WhatIf' {
        @(Get-Grant -Scope Users) | ForEach-Object { $_.Applied | Should -BeFalse }
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an account without a domain'; Account = 'svc-rma'; Ou = 'OU=Staff,DC=contoso,DC=com' }
        @{ Case = 'an OU that is not a distinguished name'; Account = 'CONTOSO\svc-rma'; Ou = 'Staff' }
    ) {
        { & $script:Path -ServiceAccount $Account -OrganizationalUnit $Ou -Scope Users -WhatIf } | Should -Throw
    }

    It 'says what to install when dsacls is missing' -Skip:([bool](Get-Command dsacls.exe -ErrorAction SilentlyContinue)) {
        { & $script:Path -ServiceAccount 'CONTOSO\svc-rma' -OrganizationalUnit $script:Ou -Scope Users -Confirm:$false } |
        Should -Throw '*dsacls.exe not found*RSAT-ADDS-Tools*'
    }
}
