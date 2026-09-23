#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Which checks Test-RmaHealth runs is decided by its parameter sets, and the ServiceNow
# application relies on that: it passes the Entra parameters, the Active Directory ones,
# or both, depending on what the domain has enabled. These tests read the sets from the
# script's metadata. Running the script would need the module installed at the version
# its #Requires pins, and a live identity behind it.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:Sets = (Get-Command (Join-Path $repoRoot 'src/runbooks/Test-RmaHealth.ps1')).ParameterSets

    $script:MandatoryIn = {
        param([string] $SetName)
        $set = $script:Sets | Where-Object Name -EQ $SetName
        @($set.Parameters | Where-Object IsMandatory | ForEach-Object Name)
    }
}

Describe 'Test-RmaHealth parameter sets' -Tag 'Unit' {

    It 'has one set per combination of directories, and defaults to Entra' {
        @($script:Sets.Name) | Sort-Object |
        Should -Be @('ActiveDirectory', 'Entra', 'EntraAndActiveDirectory')

        ($script:Sets | Where-Object IsDefault).Name | Should -Be 'Entra'
    }

    It 'lets a domain with only Active Directory run it without any Entra value' {
        # The first version made TenantId and ApplicationId mandatory everywhere, so a
        # domain with Entra switched off could not be health-checked at all.
        $mandatory = & $script:MandatoryIn 'ActiveDirectory'

        $mandatory | Should -Contain 'DomainController'
        $mandatory | Should -Contain 'AdUserName'
        $mandatory | Should -Not -Contain 'TenantId'
        $mandatory | Should -Not -Contain 'ApplicationId'
    }

    It 'lets a domain with only Entra run it without any Active Directory value' {
        $mandatory = & $script:MandatoryIn 'Entra'

        $mandatory | Should -Contain 'TenantId'
        $mandatory | Should -Contain 'ApplicationId'
        $mandatory | Should -Not -Contain 'DomainController'
        $mandatory | Should -Not -Contain 'AdUserName'
    }

    It 'requires every value of both directories when both are checked' {
        $mandatory = & $script:MandatoryIn 'EntraAndActiveDirectory'

        foreach ($name in 'TenantId', 'ApplicationId', 'DomainController', 'AdUserName') {
            $mandatory | Should -Contain $name
        }
    }

    It 'requires the ServiceNow and Key Vault values in every set' {
        foreach ($set in $script:Sets.Name) {
            $mandatory = & $script:MandatoryIn $set
            foreach ($name in 'DomainId', 'Instance', 'VaultName', 'ManagedIdentityClientId', 'ServiceNowUserName') {
                $mandatory | Should -Contain $name -Because "set '$set' must still reach ServiceNow"
            }
        }
    }

    It 'never makes the AD secret name mandatory, because it has a default' {
        foreach ($set in 'ActiveDirectory', 'EntraAndActiveDirectory') {
            & $script:MandatoryIn $set | Should -Not -Contain 'AdSecretName'
        }
    }
}
