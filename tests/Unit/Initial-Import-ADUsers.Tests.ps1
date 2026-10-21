#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the ActiveDirectory module, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the AD
# cmdlets it calls. ServiceNow is a mock of Invoke-RmaRestMethod that answers as
# /aduser/insertMultiple did on the test instance (#106).

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Initial-Import-ADUsers.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Get-ADUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Filter, $Properties, $Server, [pscredential] $Credential)
    }
    function global:Get-ADDomain {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Server, [pscredential] $Credential)
    }
    function global:Get-ADForest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Server, [pscredential] $Credential)
    }
    function global:Get-ADOptionalFeature {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Filter, $Server, [pscredential] $Credential)
    }

    # Every property the runbook reads, as Get-ADUser returns them when they are requested.
    function New-TestUser {
        param([string] $Sam, [hashtable] $Override = @{})
        $user = [ordered]@{
            AccountExpirationDate = $null; AccountLockoutTime = $null; CannotChangePassword = $false
            City = 'Aarhus'; Company = 'Contoso'; Country = 'DK'; Department = 'IT'; Description = $null
            DisplayName = "User $Sam"; DistinguishedName = "CN=$Sam,OU=Users,DC=contoso,DC=com"
            EmployeeID = $null; EmployeeNumber = $null; EmployeeType = $null; Enabled = $true
            GivenName = 'Test'; lastLogon = 0; LockedOut = $false; mail = "$Sam@contoso.com"
            MobilePhone = $null; Name = $Sam; ObjectClass = 'user'
            ObjectGUID = [guid]::NewGuid(); Office = $null; OfficePhone = $null; PasswordExpired = $false
            PasswordNeverExpires = $false; PostalCode = '8000'; PreferredLanguage = $null
            SamAccountName = $Sam; StreetAddress = $null; Surname = $Sam; Title = $null
            UserPrincipalName = "$Sam@contoso.com"
        }
        foreach ($key in $Override.Keys) { $user[$key] = $Override[$key] }
        [pscustomobject] $user
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-ADUser, Function:\Get-ADDomain, Function:\Get-ADForest,
    Function:\Get-ADOptionalFeature -ErrorAction SilentlyContinue
}

Describe 'Initial-Import-ADUsers' -Tag 'Unit' {

    BeforeEach {
        # The runbook runs under StrictMode Latest. BeforeEach shares the scope of each It.
        Set-StrictMode -Version Latest

        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:server = @{
            Server     = 'dc01.contoso.com'
            Credential = [pscredential]::new('CONTOSO\svc-rma', [securestring]::new())
        }
        $script:context = [pscustomobject]@{ BaseUri = 'https://contoso.service-now.com'; Headers = @{ Authorization = 'Basic x' } }
        $script:DomainId = 'd' * 32
        $script:ImportBatchSize = 2
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:DomainUri = "https://contoso.service-now.com/api/x_autps_active_dir/domain/$('d' * 32)"

        $script:Users = @(
            New-TestUser -Sam 'adam' -Override @{
                AccountExpirationDate = [datetime]::new(2027, 1, 31, 23, 0, 0, [DateTimeKind]::Utc)
                lastLogon             = [datetime]::new(2026, 10, 1, 8, 30, 0, [DateTimeKind]::Utc).ToFileTimeUtc()
                Description           = 'private note'
            }
            New-TestUser -Sam 'bertha'
            New-TestUser -Sam 'carl' -Override @{ lastLogon = [long]::MaxValue }
        )
        Mock Get-ADUser { $script:Users }
        Mock Get-ADDomain { [pscustomobject]@{ DomainMode = 'Windows2016Domain'; Name = 'contoso' } }
        Mock Get-ADForest { [pscustomobject]@{ ForestMode = 'Windows2016Forest'; Name = 'contoso.com' } }
        Mock Get-ADOptionalFeature { [pscustomobject]@{ Name = 'Privileged Access Management Feature'; EnabledScopes = @() } }

        # Answers each PUT the way the endpoint does: every user inserted. $script:Status
        # overrides the status per samaccountname.
        $script:Status = @{}
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RmaRestMethod {
            $sent = if ($null -ne $Body) { [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -NoEnumerate }
            $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $sent })
            if ($Method -ne 'PUT') { return }
            $results = for ($i = 0; $i -lt $sent.Count; $i++) {
                [pscustomobject]@{
                    index = $i; objectguid = $sent[$i].objectguid; sys_id = '0' * 32
                    status = $script:Status[$sent[$i].samaccountname] ?? 'inserted'
                }
            }
            [pscustomobject]@{ result = [pscustomobject]@{
                    total = [double] $sent.Count; inserted = @($results | Where-Object status -EQ 'inserted').Count
                    updated = @($results | Where-Object status -EQ 'updated').Count
                    failed = @($results | Where-Object status -EQ 'failed').Count; results = @($results)
                }
            }
        }

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
    }

    It 'handles the Initial-Import-ADUsers command' {
        $script:Command | Should -Be 'Initial-Import-ADUsers'
    }

    It 'sets the domain updating, writes the users in batches, sets it ready, then cleans up' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Initial-Import-ADUsers' })

        $script:Calls.Method | Should -Be @('PATCH', 'PUT', 'PUT', 'PATCH', 'PATCH')
        $script:Calls.Uri | Should -Be @(
            "$($script:DomainUri)/syncstate/updating"
            "$($script:DomainUri)/aduser/insertMultiple"
            "$($script:DomainUri)/aduser/insertMultiple"
            $script:DomainUri
            "$($script:DomainUri)/aduser/cleanup"
        )
        $script:Calls[1].Body.samaccountname | Should -Be @('adam', 'bertha')
        $script:Calls[2].Body.samaccountname | Should -Be @('carl')

        $ready = $script:Calls[3].Body
        $ready.sync_state | Should -Be 'ready'
        $ready.domain_mode | Should -Be 'Windows2016Domain'
        $ready.forest_name | Should -Be 'contoso.com'
        $ready.pam_enabled | Should -BeFalse

        $script:Logged[-1].Message | Should -Be 'AD users imported'
        $script:Logged[-1].Data.users | Should -Be 3
        $script:Logged[-1].Data.inserted | Should -Be 3
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'reads every user through the given domain controller and credential' {
        & $script:Body $script:Job ([pscustomobject]@{})

        Should -Invoke Get-ADUser -Times 1 -Exactly -ParameterFilter {
            $Filter -eq '*' -and $Server -eq 'dc01.contoso.com' -and $Credential.UserName -eq 'CONTOSO\svc-rma' -and
            $Properties -contains 'lastLogon' -and $Properties -contains 'mail'
        }
        foreach ($cmdlet in 'Get-ADDomain', 'Get-ADForest', 'Get-ADOptionalFeature') {
            Should -Invoke $cmdlet -Times 1 -Exactly -ParameterFilter { $Server -eq 'dc01.contoso.com' }
        }
    }

    It 'sends 1.0''s fields, with dates as ServiceNow Date/Time in UTC' {
        & $script:Body $script:Job ([pscustomobject]@{})

        $adam = $script:Calls[1].Body[0]
        $adam.PSObject.Properties.Name.Count | Should -Be 34
        $adam.domain | Should -Be ('d' * 32)
        $adam.objectguid | Should -Be "$($script:Users[0].ObjectGUID)"
        $adam.emailaddress | Should -Be 'adam@contoso.com'
        $adam.accountexpirationdate | Should -Be '2027-01-31 23:00:00'
        $adam.lastlogon | Should -Be '2026-10-01 08:30:00'
        $adam.accountlockouttime | Should -BeNullOrEmpty
        $adam.enabled | Should -BeTrue
        $script:Calls[1].Body[1].lastlogon | Should -BeNullOrEmpty -Because 'lastLogon 0 means never'
        $script:Calls[2].Body[0].lastlogon | Should -BeNullOrEmpty -Because 'the largest FILETIME means never too'
    }

    It 'reports PAM as enabled when the feature has an enabled scope' {
        Mock Get-ADOptionalFeature { [pscustomobject]@{ Name = 'Privileged Access Management Feature'; EnabledScopes = @('CN=Partitions') } }

        & $script:Body $script:Job ([pscustomobject]@{})

        ($script:Calls | Where-Object Uri -EQ $script:DomainUri).Body.pam_enabled | Should -BeTrue
    }

    It 'fails without cleanup when ServiceNow reports a user as failed, and names the user' {
        $script:Status['bertha'] = 'failed'

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '1 of 3 AD user(s) were not written*Cleanup was skipped*'

        $script:Calls.Uri | Should -Not -Contain "$($script:DomainUri)/aduser/cleanup"
        $script:Calls.Uri | Should -Contain "$($script:DomainUri)/aduser/insertMultiple" -Because 'the import goes on past a failed user'
        @($script:Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 2
        $warning = $script:Logged | Where-Object Message -EQ 'ServiceNow did not write an AD user'
        $warning.Data.samAccountName | Should -Be 'bertha'
        $warning.Data.status | Should -Be 'failed'
        ($script:Calls | Where-Object Uri -EQ $script:DomainUri).Body.sync_state | Should -Be 'ready'
    }

    It 'counts a user the answer leaves out as failed' {
        Mock Invoke-RmaRestMethod {
            $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $null })
            if ($Method -eq 'PUT') {
                [pscustomobject]@{ result = [pscustomobject]@{ inserted = 1; updated = 0; failed = 0; results = @(
                            [pscustomobject]@{ index = 0; status = 'inserted' }) 
                    }
                }
            }
        }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '1 of 3 AD user(s)*'
        $script:Calls.Uri | Should -Not -Contain "$($script:DomainUri)/aduser/cleanup"
        $script:Logged.Message | Should -Contain 'ServiceNow answered for fewer AD users than were sent'
    }

    It 'fails at once, without cleanup, when a batch is refused' {
        Mock Invoke-RmaRestMethod {
            $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            if ($Method -eq 'PUT') { throw 'PUT insertMultiple failed after 1 attempt(s) (HTTP 400): Bad Request' }
        }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*HTTP 400*'
        @($script:Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 1
        $script:Calls.Uri | Should -Not -Contain "$($script:DomainUri)/aduser/cleanup"
        $script:Calls.Uri | Should -Contain $script:DomainUri -Because 'the domain goes back to ready'
    }

    It 'fails when the endpoint answers in a shape it does not know' {
        Mock Invoke-RmaRestMethod { if ($Method -eq 'PUT') { [pscustomobject]@{ result = [pscustomobject]@{ status = 'ok' } } } }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*without result.inserted*#106*'
    }

    It 'fails without cleanup when no user is read' {
        Mock Get-ADUser {}

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw 'No AD users were read*'
        $script:Calls.Method | Should -Not -Contain 'PUT'
        $script:Calls.Uri | Should -Not -Contain "$($script:DomainUri)/aduser/cleanup"
    }

    It 'sets the domain ready, without its modes, when the directory cannot be read' {
        Mock Get-ADDomain { throw 'The server is not operational.' }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw 'The server is not operational.'
        $ready = ($script:Calls | Where-Object Uri -EQ $script:DomainUri).Body
        $ready.sync_state | Should -Be 'ready'
        $ready.PSObject.Properties.Name | Should -Not -Contain 'domain_mode'
        $script:Calls.Method | Should -Not -Contain 'PUT'
    }

    It 'keeps the import''s own error when setting the domain ready also fails' {
        Mock Get-ADUser { throw 'The server is not operational.' }
        Mock Invoke-RmaRestMethod { if ($Uri -eq $script:DomainUri) { throw 'HTTP 503' } }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw 'The server is not operational.'
        $script:Logged.Message | Should -Contain 'Could not set the domain sync state back to ready'
    }

    It 'never logs user attributes beyond the account name and objectGUID' {
        $script:Status['adam'] = 'failed'

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw
        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'private note|Aarhus|adam@contoso.com'
    }
}
