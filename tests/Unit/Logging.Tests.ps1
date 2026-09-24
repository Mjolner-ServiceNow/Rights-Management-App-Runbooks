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
