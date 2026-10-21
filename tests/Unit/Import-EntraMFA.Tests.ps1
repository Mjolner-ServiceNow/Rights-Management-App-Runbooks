#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the
# Graph cmdlets it calls. ServiceNow is a mock of Invoke-RmaRestMethod that answers as
# /entraiduser/insertMultiple did on the test instance (#106).

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Import-EntraMFA.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    # The generated Graph cmdlets report their errors as a plain System.Exception whose
    # error id leads with the Graph error code; this builds the same shape.
    function script:New-GraphError {
        param([string] $Code, [string] $Message, [string] $Cmdlet = 'GetMgUserAuthenticationPhoneMethod_List')
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("[$Code] : $Message"),
            "$Code,Microsoft.Graph.PowerShell.Cmdlets.$Cmdlet",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null)
    }
    # Invoke-MgGraphRequest reports an HTTP failure as an exception carrying the response.
    function script:New-HttpError {
        param([string] $Status)
        $exception = [System.Exception]::new("Response status code does not indicate success: $Status.")
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status })
        [System.Management.Automation.ErrorRecord]::new($exception, 'Microsoft.Graph.PowerShell.Authentication.Helpers.HttpResponseException',
            [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    }

    function global:Get-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, $Property)
    }
    function global:Get-MgUserAuthenticationPhoneMethod {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId)
    }
    function global:Invoke-MgGraphRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($Method, $Uri, $OutputType)
    }

    function script:New-TestUser {
        param([int] $N)
        [pscustomobject]@{ id = '{0:d8}-0000-0000-0000-000000000000' -f $N; userPrincipalName = "user$N@contoso.com" }
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-MgUser, Function:\Get-MgUserAuthenticationPhoneMethod, Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
}

Describe 'Import-EntraMFA' -Tag 'Unit' {

    BeforeEach {
        # The runbook runs under StrictMode Latest. BeforeEach shares the scope of each It.
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        # The script-scope variables the body reads, as the runbook sets them before the loop.
        $script:context = [pscustomobject]@{ BaseUri = 'https://contoso.service-now.com'; Headers = @{ Authorization = 'Basic x' } }
        $script:DomainId = 'd' * 32
        $script:ImportBatchSize = 2
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:Endpoint = "https://contoso.service-now.com/api/x_autps_active_dir/domain/$('d' * 32)/entraiduser/insertMultiple"
        $script:NextLink = 'https://graph.microsoft.com/v1.0/users?$skiptoken=page2'

        # Three users over two pages. user1 has a mobile and an office phone, user2 none,
        # user3 only an alternate mobile.
        $script:Pages = @{
            "v1.0/users?`$select=id,userPrincipalName&`$top=2" = [pscustomobject]@{
                value = @((New-TestUser 1), (New-TestUser 2)); '@odata.nextLink' = $script:NextLink
            }
            $script:NextLink = [pscustomobject]@{ value = @(New-TestUser 3) }
        }
        Mock Invoke-MgGraphRequest { $script:Pages[$Uri] }
        $script:Phones = @{
            '00000001-0000-0000-0000-000000000000' = @(
                [pscustomobject]@{ PhoneType = 'office'; PhoneNumber = '+45 70000000' }
                [pscustomobject]@{ PhoneType = 'mobile'; PhoneNumber = '+45 20000001' }
            )
            '00000003-0000-0000-0000-000000000000' = @([pscustomobject]@{ PhoneType = 'alternateMobile'; PhoneNumber = '+45 20000003' })
        }
        # A user without phone methods gets nothing, as from Graph, not a null.
        Mock Get-MgUserAuthenticationPhoneMethod { if ($script:Phones.ContainsKey($UserId)) { $script:Phones[$UserId] } }
        Mock Get-MgUser { [pscustomobject]@{ Id = '00000001-0000-0000-0000-000000000000'; UserPrincipalName = 'user1@contoso.com' } }
        Mock Update-RmaConnection {}

        # Answers each PUT the way the endpoint does: every user updated. $script:Status
        # overrides the status per objectguid.
        $script:Status = @{}
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RmaRestMethod {
            $sent = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -NoEnumerate
            $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $sent })
            $results = for ($i = 0; $i -lt $sent.Count; $i++) {
                [pscustomobject]@{
                    index = $i; objectguid = $sent[$i].objectguid; sys_id = '0' * 32
                    status = $script:Status[$sent[$i].objectguid] ?? 'updated'
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

    It 'handles the Import-EntraMFA command' {
        $script:Command | Should -Be 'Import-EntraMFA'
    }

    Context 'every user' {

        It 'writes each page of users, the mobile number or an empty string, to /entraiduser/insertMultiple' {
            & $script:Body $script:Job ([pscustomobject]@{ action = 'Import-EntraMFA' })

            Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
            Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'GET' -and $Uri -eq "v1.0/users?`$select=id,userPrincipalName&`$top=2" -and $OutputType -eq 'PSObject' -and
                $PesterBoundParameters['ErrorAction'] -eq 'Stop'
            }
            Should -Invoke Get-MgUserAuthenticationPhoneMethod -Times 3 -Exactly -ParameterFilter { $PesterBoundParameters['ErrorAction'] -eq 'Stop' }

            $script:Calls.Method | Should -Be @('PUT', 'PUT')
            $script:Calls.Uri | Should -Be @($script:Endpoint, $script:Endpoint)
            $first = $script:Calls[0].Body
            $first.objectguid | Should -Be @('00000001-0000-0000-0000-000000000000', '00000002-0000-0000-0000-000000000000')
            $first[0].mfasms | Should -Be '+45 20000001' -Because 'only the mobile method receives SMS codes'
            $first[1].mfasms | Should -BeExactly '' -Because 'an empty string clears the field; null would keep the old number (#106)'
            $script:Calls[1].Body[0].mfasms | Should -BeExactly '' -Because 'an alternate mobile is not the SMS number'
        }

        It 'sends the object id and mfasms only, so the fields the user imports own keep their values' {
            & $script:Body $script:Job ([pscustomobject]@{})

            foreach ($record in $script:Calls.Body) {
                $record.PSObject.Properties.Name | Should -Be @('objectguid', 'mfasms')
            }
        }

        It 'renews the Graph connection before every page' {
            & $script:Body $script:Job ([pscustomobject]@{})

            Should -Invoke Update-RmaConnection -Times 2 -Exactly
        }

        It 'calls no cleanup and leaves the domain''s sync state alone' {
            & $script:Body $script:Job ([pscustomobject]@{})

            $script:Calls.Uri | Should -Not -Match 'cleanup|syncstate'
            @($script:Calls | Where-Object Method -NE 'PUT') | Should -BeNullOrEmpty
        }

        It 'logs the counts, and never a phone number' {
            & $script:Body $script:Job ([pscustomobject]@{})

            $done = $script:Logged | Where-Object Message -EQ 'Entra MFA imported'
            $done.Level | Should -Be 'Information'
            $done.Data.users | Should -Be 3
            $done.Data.updated | Should -Be 3
            $done.Data.batches | Should -Be 2
            $done.Data.failed | Should -Be 0
            $done.Data.queueSysId | Should -Be ('f' * 32)
            ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match '2000000|7000000'
        }

        It 'warns how many users ServiceNow had no record of' {
            $script:Status['00000002-0000-0000-0000-000000000000'] = 'inserted'

            & $script:Body $script:Job ([pscustomobject]@{})

            $warning = $script:Logged | Where-Object { $_.Level -eq 'Warning' -and $_.Message -like 'ServiceNow had no record*' }
            $warning.Data.inserted | Should -Be 1
            ($script:Logged | Where-Object Message -EQ 'Entra MFA imported').Data.inserted | Should -Be 1
        }

        It 'completes without a write when the tenant has no users' {
            $script:Pages["v1.0/users?`$select=id,userPrincipalName&`$top=2"] = [pscustomobject]@{ value = @() }

            & $script:Body $script:Job ([pscustomobject]@{})

            $script:Calls | Should -BeNullOrEmpty
            ($script:Logged | Where-Object Message -EQ 'Entra MFA imported').Data.users | Should -Be 0
        }

        It 'skips a user the authentication methods do not know, with a warning, and goes on' {
            Mock Get-MgUserAuthenticationPhoneMethod {
                if ($UserId -like '00000002-*') { throw (New-GraphError -Code 'resourceNotFound' -Message 'Resource does not exist.') }
                if ($script:Phones.ContainsKey($UserId)) { $script:Phones[$UserId] }
            }

            & $script:Body $script:Job ([pscustomobject]@{})

            $script:Calls.Body.objectguid | Should -Be @('00000001-0000-0000-0000-000000000000', '00000003-0000-0000-0000-000000000000')
            $warning = $script:Logged | Where-Object Message -Like '*not known to Graph*'
            $warning.Level | Should -Be 'Warning'
            $warning.Data.id | Should -Be '00000002-0000-0000-0000-000000000000'
            $warning.Data.userPrincipalName | Should -Be 'user2@contoso.com'
            ($script:Logged | Where-Object Message -EQ 'Entra MFA imported').Data.skipped | Should -Be 1
        }

        It 'writes no request for a page whose every user is skipped' {
            Mock Get-MgUserAuthenticationPhoneMethod {
                if ($UserId -like '00000003-*') { throw (New-GraphError -Code 'resourceNotFound' -Message 'Resource does not exist.') }
                if ($script:Phones.ContainsKey($UserId)) { $script:Phones[$UserId] }
            }

            & $script:Body $script:Job ([pscustomobject]@{})

            @($script:Calls).Count | Should -Be 1
        }

        It 'asks the loop to run it again when Graph still throttles the <Call>' -ForEach @(
            @{ Call = 'phone methods' }
            @{ Call = 'user pages' }
        ) {
            if ($Call -eq 'phone methods') {
                Mock Get-MgUserAuthenticationPhoneMethod { throw (New-GraphError -Code 'TooManyRequests' -Message 'Too many requests.') }
            } else {
                Mock Invoke-MgGraphRequest { throw (New-HttpError -Status 'TooManyRequests') }
            }

            { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*throttling*' -ErrorId 'RmaJobRetry,*'
            $script:Calls | Should -BeNullOrEmpty
        }

        It 'passes any other Graph failure through unchanged' -ForEach @(
            @{ Call = 'phone methods' }
            @{ Call = 'user pages' }
        ) {
            if ($Call -eq 'phone methods') {
                Mock Get-MgUserAuthenticationPhoneMethod { throw (New-GraphError -Code 'accessDenied' -Message 'Request Authorization failed') }
                $expected = '*accessDenied*Request Authorization failed*'
            } else {
                Mock Invoke-MgGraphRequest { throw (New-HttpError -Status 'Forbidden') }
                $expected = '*Forbidden*'
            }

            { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw $expected
            $script:Calls | Should -BeNullOrEmpty
        }

        It 'fails at the end when ServiceNow reports a user as failed, names it by object id, and goes on' {
            $script:Status['00000002-0000-0000-0000-000000000000'] = 'failed'

            { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw "1 of 3 Entra user(s)' SMS phone numbers were not written to ServiceNow."

            @($script:Calls).Count | Should -Be 2 -Because 'the import goes on past a failed user'
            $warning = $script:Logged | Where-Object Message -Like 'ServiceNow did not write*'
            $warning.Data.objectGuid | Should -Be '00000002-0000-0000-0000-000000000000'
            $warning.Data.status | Should -Be 'failed'
            $warning.Data.Keys | Should -Not -Contain 'mfasms'
            ($script:Logged | Where-Object Message -EQ 'Entra MFA import incomplete').Level | Should -Be 'Error'
        }

        It 'counts a user the answer leaves out as failed' {
            Mock Invoke-RmaRestMethod {
                $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
                [pscustomobject]@{ result = [pscustomobject]@{ inserted = 0; updated = 1; results = @([pscustomobject]@{ index = 0; status = 'updated' }) } }
            }

            { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '1 of 3 Entra user(s)*'
            $script:Logged.Message | Should -Contain 'ServiceNow answered for fewer Entra users than were sent'
        }

        It 'fails at once when a batch is refused' {
            Mock Invoke-RmaRestMethod {
                $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
                throw 'PUT insertMultiple failed after 1 attempt(s) (HTTP 400): Bad Request'
            }

            { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*HTTP 400*'
            @($script:Calls).Count | Should -Be 1
        }

        It 'fails when the endpoint answers in a shape it does not know' {
            Mock Invoke-RmaRestMethod { [pscustomobject]@{ result = [pscustomobject]@{ status = 'ok' } } }

            { & $script:Body $script:Job ([pscustomobject]@{}) } | Should -Throw '*without result.inserted*#106*'
        }
    }

    Context 'one user' {

        It 'writes the user named by <Form> alone' -ForEach @(
            @{ Form = 'object id'; Id = '00000001-0000-0000-0000-000000000000' }
            @{ Form = 'user principal name'; Id = ' user1@contoso.com ' }
        ) {
            & $script:Body $script:Job ([pscustomobject]@{ action = 'Import-EntraMFA'; Id = $Id })

            Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $Id.Trim() -and $PesterBoundParameters['ErrorAction'] -eq 'Stop' }
            Should -Invoke Get-MgUserAuthenticationPhoneMethod -Times 1 -Exactly -ParameterFilter { $UserId -eq '00000001-0000-0000-0000-000000000000' }
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
            $script:Calls.Uri | Should -Be $script:Endpoint
            $script:Calls[0].Body.Count | Should -Be 1
            $script:Calls[0].Body[0].objectguid | Should -Be '00000001-0000-0000-0000-000000000000'
            $script:Calls[0].Body[0].mfasms | Should -Be '+45 20000001'
            ($script:Logged | Where-Object Message -EQ 'Entra MFA imported').Data.users | Should -Be 1
        }

        It 'imports every user when Id is null' {
            & $script:Body $script:Job ([pscustomobject]@{ Id = $null })

            Should -Invoke Get-MgUser -Times 0 -Exactly
            @($script:Calls).Count | Should -Be 2
        }

        It 'asks the loop to run it again when Graph does not know the user yet' {
            Mock Get-MgUser { throw (New-GraphError -Code 'Request_ResourceNotFound' -Message "Resource 'nobody@contoso.com' does not exist." -Cmdlet 'GetMgUser_Get') }

            { & $script:Body $script:Job ([pscustomobject]@{ Id = 'nobody@contoso.com' }) } |
            Should -Throw "No Entra ID user 'nobody@contoso.com'. Correct the ServiceNow record." -ErrorId 'RmaJobRetry,*'
            $script:Calls | Should -BeNullOrEmpty
        }

        It 'asks the loop to run it again when the authentication methods do not know the user yet' {
            Mock Get-MgUserAuthenticationPhoneMethod { throw (New-GraphError -Code 'resourceNotFound' -Message 'Resource does not exist.') }

            { & $script:Body $script:Job ([pscustomobject]@{ Id = 'user1@contoso.com' }) } |
            Should -Throw "*'user1@contoso.com' exists*queue the job again." -ErrorId 'RmaJobRetry,*'
            $script:Calls | Should -BeNullOrEmpty
        }

        It 'asks the loop to run it again when Graph still throttles the <Call>' -ForEach @(
            @{ Call = 'user' }
            @{ Call = 'phone methods' }
        ) {
            $throttle = { throw (New-GraphError -Code 'TooManyRequests' -Message 'Too many requests.') }
            if ($Call -eq 'user') { Mock Get-MgUser $throttle } else { Mock Get-MgUserAuthenticationPhoneMethod $throttle }

            { & $script:Body $script:Job ([pscustomobject]@{ Id = 'user1@contoso.com' }) } | Should -Throw '*throttling*' -ErrorId 'RmaJobRetry,*'
        }

        It 'passes any other lookup failure through unchanged' {
            Mock Get-MgUser { throw (New-GraphError -Code 'Authorization_RequestDenied' -Message 'Insufficient privileges to complete the operation.' -Cmdlet 'GetMgUser_Get') }

            { & $script:Body $script:Job ([pscustomobject]@{ Id = 'user1@contoso.com' }) } | Should -Throw '*Authorization_RequestDenied*Insufficient privileges*'
            $script:Calls | Should -BeNullOrEmpty
        }

        It 'writes nothing when Graph returns another user than the one asked for' {
            Mock Get-MgUser { [pscustomobject]@{ Id = '00000009-0000-0000-0000-000000000000'; UserPrincipalName = 'other@contoso.com' } }

            { & $script:Body $script:Job ([pscustomobject]@{ Id = 'user1@contoso.com' }) } | Should -Throw "Graph returned a different user than 'user1@contoso.com'*"
            $script:Calls | Should -BeNullOrEmpty
        }

        It 'fails when ServiceNow does not write the user' {
            $script:Status['00000001-0000-0000-0000-000000000000'] = 'failed'

            { & $script:Body $script:Job ([pscustomobject]@{ Id = 'user1@contoso.com' }) } | Should -Throw "1 of 1 Entra user(s)'*"
        }

        It 'refuses Id <Case> before Graph is called' -ForEach @(
            @{ Case = 'empty'; Value = '  '; Message = "Payload field 'Id' is empty or contains control characters. Leave it out*" }
            @{ Case = 'with a control character'; Value = "user1@con`ntoso.com"; Message = "Payload field 'Id' is empty or contains control characters*" }
            @{ Case = 'with a path in it'; Value = 'user1@contoso.com/manager'; Message = "Payload field 'Id' is neither an object id nor a user principal name*" }
            @{ Case = 'as a display name'; Value = 'User One'; Message = "Payload field 'Id' is neither an object id nor a user principal name*" }
        ) {
            { & $script:Body $script:Job ([pscustomobject]@{ Id = $Value }) } | Should -Throw $Message
            Should -Invoke Get-MgUser -Times 0 -Exactly
            Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
            $script:Calls | Should -BeNullOrEmpty
        }
    }
}
