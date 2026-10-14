#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
}

Describe 'Write-RmaLog secret redaction' -Tag 'Unit', 'Security' {

    It 'redacts a password rather than writing it to the job log' {
        # The original incident: Create-EntraUser wrote the whole ServiceNow payload,
        # including the new user's password, to Automation job output.
        $output = Write-RmaLog -Level Information -Message 'Creating user' -Data @{
            upn      = 'jane@contoso.com'
            password = 'SuperSecret123!'
        } 6>&1 | Out-String

        $output | Should -Not -Match 'SuperSecret123'
        $output | Should -Match '<redacted>'
        $output | Should -Match 'jane@contoso\.com'
    }

    It 'redacts nested secrets' {
        $output = Write-RmaLog -Level Information -Message 'Payload' -Data @{
            user = @{ name = 'jane'; passwordProfile = @{ Password = 'nested-secret' } }
        } 6>&1 | Out-String

        $output | Should -Not -Match 'nested-secret'
    }

    It 'emits one parseable JSON object per call' {
        $line = Write-RmaLog -Level Information -Message 'Structured' -Data @{ jobs = 3 } 6>&1 | Out-String
        { $line | ConvertFrom-Json } | Should -Not -Throw

        $parsed = $line | ConvertFrom-Json
        $parsed.level     | Should -Be 'Information'
        $parsed.message   | Should -Be 'Structured'
        $parsed.data.jobs | Should -Be 3
        $parsed.timestamp | Should -Not -BeNullOrEmpty
    }

    It 'keeps an array an array whatever its length' {
        # An empty array was logged as null and a one-element array as a bare string, so
        # Test-RmaHealth's 'checks' changed JSON type with the number of directories checked.
        $line = Write-RmaLog -Level Information -Message 'Arrays' -Data @{
            none   = @()
            one    = @('Entra ID')
            two    = @('Entra ID', 'Active Directory')
            nested = @{ one = @(1) }
        } 6>&1 | Out-String

        $line | Should -Match '"none":\[\]'
        $line | Should -Match '"one":\["Entra ID"\]'
        $line | Should -Match '"two":\["Entra ID","Active Directory"\]'
        $line | Should -Match '"nested":\{"one":\[1\]\}'
    }

    It 'writes nothing to the success stream at any level' {
        # Write-Output made every log line part of the caller's return value.
        foreach ($level in 'Debug', 'Information', 'Warning', 'Error') {
            @(Write-RmaLog -Level $level -Message 'x' -Verbose 2>$null 3>$null 4>$null 6>$null).Count |
            Should -Be 0 -Because "a $level record must not become part of a return value"
        }
    }

    It 'sends an Information record to the information stream' {
        $records = @(Write-RmaLog -Level Information -Message 'visible' 6>&1)

        $records.Count | Should -Be 1
        ("$($records[0].MessageData)" | ConvertFrom-Json).message | Should -Be 'visible'
    }

    It 'sends a Debug record to the verbose stream instead of discarding it' {
        # Write-Verbose was called with -Verbose:$false, which made every Debug record
        # unreachable no matter what the caller asked for. 'Job claim lost to another
        # worker' is logged at Debug, so claim contention left no trace at all.
        $records = @(Write-RmaLog -Level Debug -Message 'claim lost' -Verbose 4>&1)

        $records.Count | Should -Be 1
        ($records[0].Message | ConvertFrom-Json).level | Should -Be 'Debug'
    }

    It 'stays quiet at Debug when the caller has not asked for verbose' {
        @(Write-RmaLog -Level Debug -Message 'quiet' 4>&1).Count | Should -Be 0
    }

    It 'covers the common secret-bearing property names' {
        foreach ($name in 'password', 'secret', 'token', 'clientSecret', 'apiKey', 'authorization', 'assertion') {
            $line = Write-RmaLog -Level Information -Message 'x' -Data @{ $name = 'LEAKED' } 6>&1 | Out-String
            $line | Should -Not -Match 'LEAKED' -Because "'$name' should be redacted"
        }
    }

    It 'redacts <Name> by pattern, not only by exact name' -ForEach @(
        # An exact list missed all of these (#29).
        @{ Name = 'access_token' }, @{ Name = 'client_secret' }, @{ Name = 'adPassword' }
        @{ Name = 'refresh-token' }, @{ Name = 'NewPassword' }, @{ Name = 'x-api-key' }
        @{ Name = 'privateKey' }, @{ Name = 'storageAccountKey' }, @{ Name = 'connectionString' }
        @{ Name = 'Cookie' }, @{ Name = 'pwd' }, @{ Name = 'client_assertion' }
    ) {
        $line = Write-RmaLog -Level Information -Message 'x' -Data @{ $Name = 'LEAKED'; upn = 'jane@contoso.com' } 6>&1 | Out-String
        $line | Should -Not -Match 'LEAKED'
        $line | Should -Match 'jane@contoso\.com'
    }

    It 'leaves ordinary fields alone' {
        $line = Write-RmaLog -Level Information -Message 'x' -Data @{
            upn = 'jane@contoso.com'; queueSysId = 'abc'; maxJobs = 5; status = 500; keyCount = 2
        } 6>&1 | Out-String
        $parsed = ($line | ConvertFrom-Json).data
        $parsed.upn | Should -Be 'jane@contoso.com'
        $parsed.queueSysId | Should -Be 'abc'
        $parsed.maxJobs | Should -Be 5
        $parsed.keyCount | Should -Be 2
    }

    It 'redacts a secret-named property inside an array of objects' {
        $line = Write-RmaLog -Level Information -Message 'x' -Data @{
            users = @(
                [pscustomobject]@{ upn = 'a@contoso.com'; initialPassword = 'LEAKED-1' }
                @{ upn = 'b@contoso.com'; credentials = @{ user = 'b'; pass = 'x' } }
            )
        } 6>&1 | Out-String
        $line | Should -Not -Match 'LEAKED-1'
        $line | Should -Match 'a@contoso\.com'
        $line | Should -Match 'b@contoso\.com'
        $line | Should -Not -Match '"pass":"x"'
    }

    It 'redacts <Case> inside a string value and inside -Message' -ForEach @(
        @{ Case = 'a bearer token'; Text = 'request failed with Authorization: Bearer abc.def-ghi'; Secret = 'abc.def-ghi' }
        @{ Case = 'basic credentials'; Text = 'header was Basic c3ZjOnBhc3N3b3Jk'; Secret = 'c3ZjOnBhc3N3b3Jk' }
        @{ Case = 'a JWT'; Text = 'token eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl rejected'; Secret = 'eyJhbGciOiJSUzI1NiJ9' }
        @{ Case = 'a query string secret'; Text = 'POST https://login.contoso.com/token?client_secret=s3cr3t&grant_type=x failed'; Secret = 's3cr3t' }
        @{ Case = 'a JSON password'; Text = 'body {"user":"jane","password":"Pa55w0rd!"} rejected'; Secret = 'Pa55w0rd!' }
        @{ Case = 'a SAS signature'; Text = 'GET https://contoso.blob.core.windows.net/c/x?sv=2024&sig=AbC%2Bd3f'; Secret = 'AbC%2Bd3f' }
    ) {
        $inData = Write-RmaLog -Level Warning -Message 'x' -Data @{ error = $Text } 3>&1 | Out-String
        $inMessage = Write-RmaLog -Level Warning -Message $Text 3>&1 | Out-String

        $inData | Should -Not -Match ([regex]::Escape($Secret))
        $inMessage | Should -Not -Match ([regex]::Escape($Secret))
        $inMessage | Should -Match '<redacted>'
    }

    It 'leaves an ordinary message untouched' {
        foreach ($text in 'Token acquired', 'Password reset for jane@contoso.com', 'Queue loop started: maxJobs=5') {
            $line = Write-RmaLog -Level Information -Message $text 6>&1 | Out-String
            ($line | ConvertFrom-Json).message | Should -Be $text
        }
    }
}

Describe 'Write-RmaLog command field' -Tag 'Unit' {

    BeforeAll {
        # In an Automation job a runbook runs from a temporary file named by a GUID, so the
        # runbook field of its own records is that GUID (#124). The command is what finds them.
        $script:RunbookName = [guid]::NewGuid().ToString()
        $script:RunbookFile = Join-Path $TestDrive "$script:RunbookName.ps1"
        Set-Content -Path $script:RunbookFile -Value @'
param($Context, $DomainId)
$null = Invoke-RmaQueueLoop -Context $Context -DomainId $DomainId -Command 'Unlock-ADUser' -Body {
    Write-RmaLog -Level Information -Message 'User unlocked'
}
Write-RmaLog -Level Information -Message 'After the loop'
'@
        $script:Context = [pscustomobject]@{
            PSTypeName = 'Rma.ServiceNowContext'
            Instance   = 'contoso'
            BaseUri    = 'https://contoso.service-now.com'
            Headers    = @{}
        }
    }

    BeforeEach {
        $script:Served = $false
        Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
            if ($script:Served) { return @() }
            $script:Served = $true
            [pscustomobject]@{
                sys_id = 'a' * 32
                input  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"action":"Unlock-ADUser"}'))
            }
        }
        Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
        Mock -ModuleName RMA.Runbooks Set-RmaJobState {}

        $script:Records = @(& $script:RunbookFile -Context $script:Context -DomainId ('b' * 32) 6>&1 |
            ForEach-Object { "$($_.MessageData)" | ConvertFrom-Json })
    }

    It 'names the command on a record the runbook body logs from a GUID-named file' {
        $record = $script:Records | Where-Object message -EQ 'User unlocked'

        $record.runbook | Should -Be $script:RunbookName
        $record.command | Should -Be 'Unlock-ADUser'
    }

    It 'names the command from the first record of the run to the last' {
        ($script:Records | Where-Object message -EQ 'Queue loop started').command | Should -Be 'Unlock-ADUser'
        ($script:Records | Where-Object message -Like 'Queue loop finished*').command | Should -Be 'Unlock-ADUser'
    }

    It 'leaves the command empty once the loop has returned' {
        ($script:Records | Where-Object message -EQ 'After the loop').command | Should -BeNullOrEmpty
    }
}

Describe 'A function that logs before it returns' -Tag 'Unit', 'Reliability' {

    It 'returns only its own value, with the real logger in place' {
        # Connect-RmaServiceNow logs at Information and then returns its context. With
        # Write-RmaLog on the success stream the caller got @($line, $context), and
        # Test-RmaPrerequisite failed on $context.BaseUri on the first real run. Every
        # other test mocks Write-RmaLog, which is exactly what hid it: do not mock it here.
        Mock -ModuleName RMA.Runbooks Get-RmaSecret { 'not-a-real-password' }
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ result = @() } }

        $context = Connect-RmaServiceNow -Instance 'contoso' -VaultName 'kv-rma-contoso' `
            -UserName 'svc.rma' -SecretName 'servicenow-api-password' `
            -ManagedIdentityClientId '00000000-0000-0000-0000-000000000001' 6>$null

        @($context).Count | Should -Be 1
        $context.BaseUri | Should -Be 'https://contoso.service-now.com'
    }
}

Describe 'Invoke-RmaRestMethod retry behaviour' -Tag 'Unit', 'Reliability' {

    It 'gives up immediately on a client error' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            $response = [pscustomobject]@{ StatusCode = 404 }
            $exception = [System.Exception]::new('Not Found')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
            throw $exception
        }
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Start-Sleep {}

        { Invoke-RmaRestMethod -Uri 'https://example.invalid/x' -MaxAttempts 4 } | Should -Throw
        # A 404 will still be a 404 on the fourth attempt; retrying just burns the budget.
        Should -Invoke -ModuleName RMA.Runbooks Invoke-RestMethod -Times 1 -Exactly
    }

    It 'retries a transient failure up to MaxAttempts' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            $response = [pscustomobject]@{ StatusCode = 503 }
            $exception = [System.Exception]::new('Service Unavailable')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
            throw $exception
        }
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Start-Sleep {}

        { Invoke-RmaRestMethod -Uri 'https://example.invalid/x' -MaxAttempts 3 } | Should -Throw
        Should -Invoke -ModuleName RMA.Runbooks Invoke-RestMethod -Times 3 -Exactly
    }

    It 'returns the result as soon as a retry succeeds' {
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Start-Sleep {}
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            if ($script:Calls++ -lt 1) {
                $response = [pscustomobject]@{ StatusCode = 500 }
                $e = [System.Exception]::new('boom')
                $e | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
                throw $e
            }
            [pscustomobject]@{ ok = $true }
        }
        $script:Calls = 0

        (Invoke-RmaRestMethod -Uri 'https://example.invalid/x').ok | Should -BeTrue
        Should -Invoke -ModuleName RMA.Runbooks Invoke-RestMethod -Times 2 -Exactly
    }
}

Describe 'Invoke-RmaRestMethod retry against a real HTTP response' -Tag 'Unit', 'Reliability' {
    # The tests above throw a [pscustomobject] with only StatusCode. A real failure carries
    # an HttpResponseMessage whose Headers are never empty, and the retry branch once
    # assigned them to $headers, which is the -Headers parameter: every 5xx became a type
    # conversion error and every transport retry went out without Authorization (#24).

    BeforeAll {
        function New-HttpFailure {
            param([int] $Status, [System.Net.Http.Headers.RetryConditionHeaderValue] $RetryAfter)
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode] $Status)
            $response.Headers.Add('X-Test', '1')
            if ($RetryAfter) { $response.Headers.RetryAfter = $RetryAfter }
            [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                "Response status code does not indicate success: $Status", $response)
        }
    }

    BeforeEach {
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        $script:Sent = [System.Collections.Generic.List[object]]::new()
        $script:Slept = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName RMA.Runbooks Start-Sleep { $script:Slept.Add($Milliseconds) }
    }

    It 'retries a 500 that carries response headers and reports the status' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod { throw (New-HttpFailure -Status 500) }

        { Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -Method PATCH -Headers @{ a = 1 } -MaxAttempts 2 } |
        Should -Throw '*failed after 2 attempt(s) (HTTP 500)*'
        Should -Invoke -ModuleName RMA.Runbooks Invoke-RestMethod -Times 2 -Exactly
    }

    It 'sends the same headers on a retry after an HTTP 503' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            $script:Sent.Add($Headers)
            if ($script:Sent.Count -eq 1) { throw (New-HttpFailure -Status 503) }
            [pscustomobject]@{ ok = $true }
        }

        (Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -Headers @{ Authorization = 'Basic x' } -MaxAttempts 2).ok |
        Should -BeTrue
        $script:Sent[1].Authorization | Should -Be 'Basic x'
    }

    It 'sends the same headers on a retry after a transport failure' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            $script:Sent.Add($Headers)
            if ($script:Sent.Count -eq 1) { throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }
            [pscustomobject]@{ ok = $true }
        }

        $null = Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -Headers @{ Authorization = 'Basic x' } -MaxAttempts 2
        $script:Sent[1].Authorization | Should -Be 'Basic x'
    }

    It 'waits at least the Retry-After seconds a 429 asks for' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            throw (New-HttpFailure -Status 429 -RetryAfter ([System.Net.Http.Headers.RetryConditionHeaderValue]::new([timespan]::FromSeconds(5))))
        }

        { Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -MaxAttempts 2 } | Should -Throw '*(HTTP 429)*'
        # Jitter may lengthen the server's delay, never shorten it: retrying early earns another 429.
        $script:Slept[0] | Should -BeGreaterOrEqual 5000
        $script:Slept[0] | Should -BeLessOrEqual 6250
    }

    It 'waits until a Retry-After date' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            $when = [System.DateTimeOffset]::UtcNow.AddSeconds(10)
            throw (New-HttpFailure -Status 503 -RetryAfter ([System.Net.Http.Headers.RetryConditionHeaderValue]::new($when)))
        }

        { Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -MaxAttempts 2 } | Should -Throw '*(HTTP 503)*'
        # HTTP dates have one-second resolution, so allow for the second already begun.
        $script:Slept[0] | Should -BeGreaterOrEqual 8000
        $script:Slept[0] | Should -BeLessOrEqual 12500
    }

    It 'fails at once when Retry-After asks for more than MaxRetryAfterSeconds' {
        # An hour-long Retry-After held the job and the run for that hour (#117).
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            throw (New-HttpFailure -Status 429 -RetryAfter ([System.Net.Http.Headers.RetryConditionHeaderValue]::new([timespan]::FromSeconds(3600))))
        }

        { Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -MaxAttempts 4 } |
        Should -Throw '*failed after 1 attempt(s) (HTTP 429): the server asked to wait 3600 s*MaxRetryAfterSeconds (120)*'
        Should -Invoke -ModuleName RMA.Runbooks Invoke-RestMethod -Times 1 -Exactly
        $script:Slept.Count | Should -Be 0
    }

    It 'fails at once when a Retry-After date is further away than MaxRetryAfterSeconds' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            $when = [System.DateTimeOffset]::UtcNow.AddMinutes(10)
            throw (New-HttpFailure -Status 503 -RetryAfter ([System.Net.Http.Headers.RetryConditionHeaderValue]::new($when)))
        }

        { Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -MaxRetryAfterSeconds 300 } |
        Should -Throw '*(HTTP 503): the server asked to wait*MaxRetryAfterSeconds (300)*'
        $script:Slept.Count | Should -Be 0
    }

    It 'waits out a Retry-After up to MaxRetryAfterSeconds' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod {
            throw (New-HttpFailure -Status 429 -RetryAfter ([System.Net.Http.Headers.RetryConditionHeaderValue]::new([timespan]::FromSeconds(120))))
        }

        { Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -MaxAttempts 2 } | Should -Throw '*failed after 2 attempt(s) (HTTP 429): Response*'
        $script:Slept[0] | Should -BeGreaterOrEqual 120000
    }

    It 'falls back to exponential backoff when there is no Retry-After' {
        Mock -ModuleName RMA.Runbooks Invoke-RestMethod { throw (New-HttpFailure -Status 502) }

        { Invoke-RmaRestMethod -Uri 'https://contoso.service-now.com/x' -MaxAttempts 3 -BaseDelayMs 1000 } | Should -Throw
        $script:Slept.Count | Should -Be 2
        $script:Slept[0] | Should -BeGreaterOrEqual 750
        $script:Slept[0] | Should -BeLessOrEqual 1250
        $script:Slept[1] | Should -BeGreaterOrEqual 1500
        $script:Slept[1] | Should -BeLessOrEqual 2500
    }
}
