#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The body is taken from the runbook's AST (tests/Helpers/RunbookBody.ps1) and run against
# a stand-in for Invoke-MgGraphRequest, which pages the users as Graph does. ServiceNow is
# a mock of Invoke-RmaRestMethod that answers as /entraiduser/insertMultiple did on the
# test instance (#106).

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Import-EntraUsers.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    function global:Invoke-MgGraphRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        param($Method, $Uri, $OutputType)
    }

    # A user as Graph returns it with -OutputType Hashtable and the runbook's $select.
    function New-TestUser {
        param([string] $Name, [hashtable] $Override = @{})
        $user = @{
            id = [guid]::NewGuid().ToString(); accountEnabled = $true; businessPhones = @('+45 11 22 33 44')
            city = 'Aarhus'; companyName = 'Contoso'; country = 'DK'; department = 'IT'; displayName = "User $Name"
            employeeHireDate = $null; employeeId = $null; employeeType = $null; givenName = 'Test'; jobTitle = $null
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

Describe 'Import-EntraUsers' -Tag 'Unit' {

    BeforeEach {
        # The runbook runs under StrictMode Latest. BeforeEach shares the scope of each It.
        Set-StrictMode -Version Latest

        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:context = [pscustomobject]@{ BaseUri = 'https://contoso.service-now.com'; Headers = @{ Authorization = 'Basic x' } }
        $script:DomainId = 'd' * 32
        $script:CreatedWithinHours = 24
        $script:ImportBatchSize = 2
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:DomainUri = "https://contoso.service-now.com/api/x_autps_active_dir/domain/$('d' * 32)"

        $script:Users = @(
            New-TestUser -Name 'adam' -Override @{
                employeeHireDate = [datetime]::new(2026, 10, 1, 7, 0, 0, [DateTimeKind]::Utc)
                jobTitle         = 'private title'
            }
            New-TestUser -Name 'bertha' -Override @{ businessPhones = @() }
            New-TestUser -Name 'carl'
        )

        # Pages $script:Users by the $top in the first request, as Graph does.
        $script:GraphUris = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-MgGraphRequest {
            $script:GraphUris.Add($Uri)
            $top = if ($Uri -match '\$top=(\d+)') { [int] $Matches[1] } else { 100 }
            $skip = if ($Uri -match 'skip=(\d+)') { [int] $Matches[1] } else { 0 }
            $page = @{ value = @($script:Users | Select-Object -Skip $skip -First $top) }
            if ($skip + $top -lt $script:Users.Count) { $page['@odata.nextLink'] = "https://graph.microsoft.com/v1.0/users?`$top=$top&skip=$($skip + $top)" }
            $page
        }

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

    It 'handles the Import-EntraUsers command' {
        $script:Command | Should -Be 'Import-EntraUsers'
    }

    It 'sets the domain updating, writes the new users a page at a time, and sets it ready, without cleanup' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Import-EntraUsers' })

        $script:Calls.Method | Should -Be @('PATCH', 'PUT', 'PUT', 'PATCH')
        $script:Calls.Uri | Should -Be @(
            "$($script:DomainUri)/syncstate/updating"
            "$($script:DomainUri)/entraiduser/insertMultiple"
            "$($script:DomainUri)/entraiduser/insertMultiple"
            "$($script:DomainUri)/syncstate/ready"
        ) -Because 'a cleanup after importing only the new users would delete every older one'
        $script:Calls[1].Body.mailnickname | Should -Be @('adam', 'bertha')
        $script:Calls[2].Body.mailnickname | Should -Be @('carl')
        $script:GraphUris.Count | Should -Be 2

        $script:Logged[-1].Message | Should -Be 'New Entra ID users imported'
        $script:Logged[-1].Data.users | Should -Be 3
        $script:Logged[-1].Data.inserted | Should -Be 3
        $script:Logged[-1].Data.batches | Should -Be 2
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'asks Graph only for the users created in the last CreatedWithinHours hours' {
        $script:CreatedWithinHours = 6
        $before = [datetime]::UtcNow.AddHours(-6).AddSeconds(-1)

        & $script:Body $script:Job ([pscustomobject]@{})

        $first = [uri]::UnescapeDataString($script:GraphUris[0])
        $first | Should -Match '^v1\.0/users\?\$filter=createdDateTime ge (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)&\$select=.*&\$top=2$'
        $since = [datetime]::Parse(($first -replace '.*createdDateTime ge (\S+Z).*', '$1'),
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        $since | Should -BeGreaterOrEqual $before
        $since | Should -BeLessOrEqual ([datetime]::UtcNow.AddHours(-6).AddSeconds(1))
        $script:GraphUris[0] | Should -Not -Match ' ' -Because 'the filter is escaped'
        $script:Logged[-1].Data.createdSince | Should -Match 'Z$'
    }

    It 'sends the fields Initial-Import-EntraUsers sends, keyed on the Graph object id' {
        & $script:Body $script:Job ([pscustomobject]@{})

        $adam = $script:Calls[1].Body[0]
        @($adam.PSObject.Properties.Name | Sort-Object) | Should -Be (@(
                'city', 'company', 'country', 'department', 'domain', 'email', 'employeehiredate', 'employeeid',
                'employeetype', 'enabled', 'givenname', 'mailnickname', 'mobile', 'name', 'objectguid', 'office_phone',
                'officelocation', 'postalcode', 'preferredlanguage', 'streetaddress', 'surname', 'title',
                'userprincipalname', 'username', 'usertype'
            ) | Sort-Object)
        $adam.objectguid | Should -Be $script:Users[0]['id']
        $adam.domain | Should -Be ('d' * 32)
        $adam.name | Should -Be 'User adam'
        $adam.username | Should -Be 'adam'
        $adam.email | Should -Be 'adam@contoso.com'
        $adam.company | Should -Be 'Contoso'
        $adam.office_phone | Should -Be '+45 11 22 33 44'
        $adam.employeehiredate | Should -Be '2026-10-01 07:00:00'
        $adam.enabled | Should -BeTrue
    }

    It 'leaves out the MFA phone, so the value Import-EntraMFA wrote is kept' {
        & $script:Body $script:Job ([pscustomobject]@{})

        foreach ($record in @($script:Calls | Where-Object Method -EQ 'PUT' | ForEach-Object { $_.Body })) {
            $record.PSObject.Properties.Name | Should -Not -Contain 'mfasms'
            $record.PSObject.Properties.Name | Should -Not -Contain 'description'
            $record.PSObject.Properties.Name | Should -Not -Contain 'officephone' -Because 'officephone given empty does not clear the field (#106)'
        }
    }

    It 'sends every empty value as an empty string, never as null' {
        # The endpoint leaves a field given null as it was, so a value cleared in Entra ID
        # would never be cleared in ServiceNow (#106).
        & $script:Body $script:Job ([pscustomobject]@{})

        $sent = @($script:Calls | Where-Object Method -EQ 'PUT' | ForEach-Object { $_.Body })
        $sent.Count | Should -Be 3
        foreach ($record in $sent) {
            @($record.PSObject.Properties | Where-Object { $null -eq $_.Value } | ForEach-Object Name) | Should -BeNullOrEmpty
        }
        $sent[1].office_phone | Should -BeExactly '' -Because 'bertha has no business phone'
        $sent[1].title | Should -BeExactly ''
        $sent[1].employeehiredate | Should -BeExactly ''
    }

    It 'completes, and writes nothing, when no user was created in the window' {
        $script:Users = @()

        & $script:Body $script:Job ([pscustomobject]@{})

        $script:Calls.Method | Should -Not -Contain 'PUT'
        $script:Calls.Uri | Should -Be @("$($script:DomainUri)/syncstate/updating", "$($script:DomainUri)/syncstate/ready")
        $script:Logged[-1].Message | Should -Be 'New Entra ID users imported'
        $script:Logged[-1].Data.users | Should -Be 0
    }

    It 'fails when ServiceNow reports a user as failed, after writing the rest, and names the user' {
        $script:Status['bertha'] = 'failed'

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '1 of 3 new Entra ID user(s) were not written*'

        @($script:Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 2 -Because 'the import goes on past a failed user'
        $warning = $script:Logged | Where-Object Message -EQ 'ServiceNow did not write an Entra ID user'
        $warning.Data.userPrincipalName | Should -Be 'bertha@contoso.com'
        $warning.Data.objectId | Should -Be $script:Users[1]['id']
        $warning.Data.status | Should -Be 'failed'
        $script:Calls[-1].Uri | Should -Be "$($script:DomainUri)/syncstate/ready"
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

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '1 of 3 new Entra ID user(s)*'
        $script:Logged.Message | Should -Contain 'ServiceNow answered for fewer Entra ID users than were sent'
    }

    It 'counts an updated user as written' {
        $script:Status['adam'] = 'updated'

        & $script:Body $script:Job ([pscustomobject]@{})

        $script:Logged[-1].Data.inserted | Should -Be 2
        $script:Logged[-1].Data.updated | Should -Be 1
    }

    It 'fails at once when a batch is refused, and sets the domain ready' {
        Mock Invoke-RmaRestMethod {
            $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            if ($Method -eq 'PUT') { throw 'PUT insertMultiple failed after 1 attempt(s) (HTTP 400): Bad Request' }
        }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*HTTP 400*'
        @($script:Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 1
        $script:Calls[-1].Uri | Should -Be "$($script:DomainUri)/syncstate/ready"
    }

    It 'fails when the endpoint answers in a shape it does not know' {
        Mock Invoke-RmaRestMethod { if ($Method -eq 'PUT') { [pscustomobject]@{ result = [pscustomobject]@{ status = 'ok' } } } }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*without result.inserted*#106*'
    }

    It 'passes a Graph error through, and sets the domain ready' {
        Mock Invoke-MgGraphRequest { throw 'Insufficient privileges to complete the operation.' }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw 'Insufficient privileges*'
        $script:Calls.Method | Should -Not -Contain 'PUT'
        $script:Calls[-1].Uri | Should -Be "$($script:DomainUri)/syncstate/ready"
    }

    It 'keeps the import''s own error when setting the domain ready also fails' {
        Mock Invoke-MgGraphRequest { throw 'Insufficient privileges to complete the operation.' }
        Mock Invoke-RmaRestMethod { if ($Uri -like '*/syncstate/ready') { throw 'HTTP 503' } }

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw 'Insufficient privileges*'
        $script:Logged.Message | Should -Contain 'Could not set the domain sync state back to ready'
    }

    It 'never logs user attributes beyond the user principal name and object id' {
        $script:Status['adam'] = 'failed'

        { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw
        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'private title|Aarhus|\+45 11'
    }
}
