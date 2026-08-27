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
        } | Out-String

        $output | Should -Not -Match 'nested-secret'
    }

    It 'emits one parseable JSON object per call' {
        $line = Write-RmaLog -Level Information -Message 'Structured' -Data @{ jobs = 3 } | Out-String
        { $line | ConvertFrom-Json } | Should -Not -Throw

        $parsed = $line | ConvertFrom-Json
        $parsed.level     | Should -Be 'Information'
        $parsed.message   | Should -Be 'Structured'
        $parsed.data.jobs | Should -Be 3
        $parsed.timestamp | Should -Not -BeNullOrEmpty
    }

    It 'covers the common secret-bearing property names' {
        foreach ($name in 'password', 'secret', 'token', 'clientSecret', 'apiKey', 'authorization', 'assertion') {
            $line = Write-RmaLog -Level Information -Message 'x' -Data @{ $name = 'LEAKED' } | Out-String
            $line | Should -Not -Match 'LEAKED' -Because "'$name' should be redacted"
        }
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
