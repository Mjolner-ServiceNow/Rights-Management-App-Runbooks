#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires Microsoft.Graph.Authentication, which CI does not have, so its body
# is taken from the AST (tests/Helpers/RunbookBody.ps1) and run against a stand-in for
# Invoke-MgGraphRequest that pages as Graph does. ServiceNow is a mock of
# Invoke-RmaRestMethod that answers as /entraiduser/insertMultiple did on the test
# instance (#106).

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Initial-Import-EntraUsers.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Invoke-MgGraphRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Method, $Uri, $OutputType)
    }

    # A user as Invoke-MgGraphRequest -OutputType Hashtable returns it, with every property
    # the runbook selects.
    function New-TestUser {
        param([string] $Name, [hashtable] $Override = @{})
        $user = @{
            accountEnabled = $true; businessPhones = @(); city = 'Aarhus'; companyName = 'Contoso'; country = 'DK'
            department = 'IT'; displayName = "User $Name"; employeeHireDate = $null; employeeId = $null
            employeeType = $null; givenName = 'Test'; id = [guid]::NewGuid().ToString(); jobTitle = $null
            mail = "$Name@contoso.com"; mailNickname = $Name; mobilePhone = $null; officeLocation = $null
            postalCode = '8000'; preferredLanguage = $null; streetAddress = $null; surname = $Name
            userPrincipalName = "$Name@contoso.com"; userType = 'Member'
        }
        foreach ($key in $Override.Keys) { $user[$key] = $Override[$key] }
        $user
    }
}

AfterAll {
    Remove-Item -Path Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
}

Describe 'Initial-Import-EntraUsers' -Tag 'Unit' {

    BeforeEach {
        # The runbook runs under StrictMode Latest. BeforeEach shares the scope of each It.
        Set-StrictMode -Version Latest

        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:context = [pscustomobject]@{ BaseUri = 'https://contoso.service-now.com'; Headers = @{ Authorization = 'Basic x' } }
        $script:DomainId = 'd' * 32
        $script:ImportBatchSize = 2
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:DomainUri = "https://contoso.service-now.com/api/x_autps_active_dir/domain/$('d' * 32)"

        $script:Users = @(
            New-TestUser -Name 'adam' -Override @{
                employeeHireDate = [datetime]::new(2024, 3, 1, 23, 0, 0, [DateTimeKind]::Utc)
                businessPhones   = @('+45 11 22 33 44', '+45 55 66 77 88')
                jobTitle         = 'private title'
            }
            New-TestUser -Name 'bertha' -Override @{ employeeHireDate = '2025-06-15T08:00:00Z' }
            New-TestUser -Name 'carl' -Override @{ accountEnabled = $false; userType = 'Guest' }
        )
        # Pages of ImportBatchSize users, linked by @odata.nextLink as Graph links them.
        $script:GraphUris = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-MgGraphRequest {
            $script:GraphUris.Add($Uri)
            $skip = if ($Uri -match 'skip=(\d+)') { [int] $Matches[1] } else { 0 }
            $page = @{ value = @($script:Users | Select-Object -Skip $skip -First $script:ImportBatchSize) }
            if ($skip + $script:ImportBatchSize -lt $script:Users.Count) {
                $page['@odata.nextLink'] = "https://graph.microsoft.com/v1.0/users?skip=$($skip + $script:ImportBatchSize)"
            }
            $page
        }
        Mock Update-RmaConnection {}

        # Answers each PUT the way the endpoint does: every user inserted. $script:Status
        # overrides the status per mailnickname.
        $script:Status = @{}
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RmaRestMethod {
            $sent = if ($null -ne $Body) { [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -NoEnumerate }
            $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $sent })
            if ($Method -ne 'PUT') { return }
            $results = for ($i = 0; $i -lt $sent.Count; $i++) {
                [pscustomobject]@{
                    index = $i; objectguid = $sent[$i].objectguid; sys_id = '0' * 32
                    status = $script:Status[$sent[$i].mailnickname] ?? 'inserted'
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

    It 'handles the Initial-Import-EntraUsers command' {
        $script:Command | Should -Be 'Initial-Import-EntraUsers'
    }

    It 'sets the domain updating, writes each page as a batch, then sets it ready, without cleanup' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Initial-Import-EntraUsers' })

        # /entraiduser/cleanup does not exist yet (#192); #193 adds the call.
        $script:Calls.Method | Should -Be @('PATCH', 'PUT', 'PUT', 'PATCH')
        $script:Calls.Uri | Should -Be @(
            "$($script:DomainUri)/syncstate/updating"
            "$($script:DomainUri)/entraiduser/insertMultiple"
            "$($script:DomainUri)/entraiduser/insertMultiple"
            "$($script:DomainUri)/syncstate/ready"
        )
        $script:Calls[1].Body.mailnickname | Should -Be @('adam', 'bertha')
        $script:Calls[2].Body.mailnickname | Should -Be @('carl')

        $script:Logged[-1].Message | Should -Be 'Entra ID users imported'
        $script:Logged[-1].Data.users | Should -Be 3
        $script:Logged[-1].Data.inserted | Should -Be 3
        $script:Logged[-1].Data.batches | Should -Be 2
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'reads the users a page of ImportBatchSize at a time, renewing the connection before each page' {
        & $script:Body $script:Job ([pscustomobject]@{})

        $script:GraphUris.Count | Should -Be 2
        $script:GraphUris[0] | Should -BeLike 'v1.0/users?$select=*&$top=2'
        $script:GraphUris[0] | Should -Match '\$select=[^&]*\bemployeeHireDate\b'
        $script:GraphUris[0] | Should -Not -Match 'authentication|mfa' -Because 'Import-EntraMFA owns the MFA phone (D12)'
        $script:GraphUris[1] | Should -Be 'https://graph.microsoft.com/v1.0/users?skip=2' -Because 'the next page is the link Graph gave'
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'GET' -and $OutputType -eq 'Hashtable' }
        Should -Invoke Update-RmaConnection -Times 2 -Exactly
    }

    It 'sends 1.0''s fields without the MFA phone, with dates as ServiceNow Date/Time in UTC' {
        & $script:Body $script:Job ([pscustomobject]@{})

        $adam = $script:Calls[1].Body[0]
        $adam.PSObject.Properties.Name.Count | Should -Be 25
        $adam.PSObject.Properties.Name | Should -Not -Contain 'mfasms'
        $adam.PSObject.Properties.Name | Should -Not -Contain 'officephone' -Because 'officephone: "" does not clear office_phone (#106)'
        $adam.PSObject.Properties.Name | Should -Not -Contain 'location' -Because 'the office location goes to officelocation, as Import-EntraUsers sends it'
        $adam.PSObject.Properties.Name | Should -Contain 'officelocation'
        $adam.domain | Should -Be ('d' * 32)
        $adam.objectguid | Should -Be $script:Users[0].id
        $adam.name | Should -Be 'User adam'
        $adam.email | Should -Be 'adam@contoso.com'
        $adam.userprincipalname | Should -Be 'adam@contoso.com'
        $adam.username | Should -Be 'adam'
        $adam.employeehiredate | Should -Be '2024-03-01 23:00:00'
        $adam.office_phone | Should -Be '+45 11 22 33 44' -Because 'the first business phone is the office phone'
        $adam.title | Should -Be 'private title'
        $adam.enabled | Should -BeTrue
        $script:Calls[1].Body[1].employeehiredate | Should -Be '2025-06-15 08:00:00' -Because 'Graph may give the date as text'
        $script:Calls[2].Body[0].enabled | Should -BeFalse
        $script:Calls[2].Body[0].usertype | Should -Be 'Guest'
    }

    It 'sends every empty value as an empty string, never as null' {
        # The endpoint leaves a field given null as it was, so a value cleared in Entra ID
        # would never be cleared in ServiceNow (#186).
        & $script:Body $script:Job ([pscustomobject]@{})

        $sent = @($script:Calls | Where-Object Method -EQ 'PUT' | ForEach-Object { $_.Body })
        $sent.Count | Should -Be 3
        foreach ($record in $sent) {
            @($record.PSObject.Properties | Where-Object { $null -eq $_.Value } | ForEach-Object Name) | Should -BeNullOrEmpty
        }
        $sent[1].office_phone | Should -BeExactly '' -Because 'bertha has no business phone'
        $sent[1].title | Should -BeExactly ''
        $sent[2].employeehiredate | Should -BeExactly ''
    }

    It 'skips an empty page and still follows the next link' {
        $script:Users = @(New-TestUser -Name 'adam')
        $script:Pages = 0
        Mock Invoke-MgGraphRequest {
            $script:Pages++
            if ($script:Pages -eq 1) { return @{ value = @(); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?skip=0' } }
            @{ value = @($script:Users) }
        }

        & $script:Body $script:Job ([pscustomobject]@{})

        @($script:Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 1
    }

    It 'fails when ServiceNow reports a user as failed, and names the user' {
        $script:Status['bertha'] = 'failed'

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '1 of 3 Entra ID user(s) were not written to ServiceNow.'

        @($script:Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 2 -Because 'the import goes on past a failed user'
        $warning = $script:Logged | Where-Object Message -EQ 'ServiceNow did not write an Entra ID user'
        $warning.Data.userPrincipalName | Should -Be 'bertha@contoso.com'
        $warning.Data.objectId | Should -Be $script:Users[1].id
        $warning.Data.status | Should -Be 'failed'
        $script:Calls.Uri | Should -Contain "$($script:DomainUri)/syncstate/ready"
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

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '1 of 3 Entra ID user(s)*'
        $script:Logged.Message | Should -Contain 'ServiceNow answered for fewer Entra ID users than were sent'
    }

    It 'counts updated users as written' {
        $script:Status['adam'] = 'updated'

        & $script:Body $script:Job ([pscustomobject]@{})

        $script:Logged[-1].Data.updated | Should -Be 1
        $script:Logged[-1].Data.inserted | Should -Be 2
    }

    It 'fails at once when a batch is refused' {
        Mock Invoke-RmaRestMethod {
            $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            if ($Method -eq 'PUT') { throw 'PUT insertMultiple failed after 1 attempt(s) (HTTP 400): Bad Request' }
        }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*HTTP 400*'
        @($script:Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 1
        $script:Calls.Uri | Should -Contain "$($script:DomainUri)/syncstate/ready" -Because 'the domain goes back to ready'
    }

    It 'fails when Graph refuses a page' {
        Mock Invoke-MgGraphRequest { throw 'Insufficient privileges to complete the operation.' }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw 'Insufficient privileges*'
        $script:Calls.Method | Should -Not -Contain 'PUT'
        $script:Calls.Uri | Should -Contain "$($script:DomainUri)/syncstate/ready"
    }

    It 'fails when the endpoint answers in a shape it does not know' {
        Mock Invoke-RmaRestMethod { if ($Method -eq 'PUT') { [pscustomobject]@{ result = [pscustomobject]@{ status = 'ok' } } } }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*without result.inserted*#106*'
    }

    It 'fails when no user is read' {
        $script:Users = @()

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw 'No Entra ID users were read*'
        $script:Calls.Method | Should -Not -Contain 'PUT'
    }

    It 'keeps the import''s own error when setting the domain ready also fails' {
        Mock Invoke-MgGraphRequest { throw 'Graph is down.' }
        Mock Invoke-RmaRestMethod { if ($Uri -like '*/syncstate/ready') { throw 'HTTP 503' } }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw 'Graph is down.'
        $script:Logged.Message | Should -Contain 'Could not set the domain sync state back to ready'
    }

    It 'never logs user attributes beyond the user principal name and object id' {
        $script:Status['adam'] = 'failed'

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw
        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'private title|Aarhus|\+45'
    }
}
