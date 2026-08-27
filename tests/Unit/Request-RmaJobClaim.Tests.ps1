#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    $script:Context = [pscustomobject]@{
        Instance = 'contoso'
        BaseUri  = 'https://contoso.service-now.com'
        Headers  = @{ Authorization = 'Basic redacted' }
    }
    $script:SysId = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'
}

Describe 'Request-RmaJobClaim' -Tag 'Unit', 'Concurrency' {

    Context 'when this worker wins the race' {
        It 'returns true and filters the update on status=1' {
            $captured = $null
            Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
                $script:captured = $PesterBoundParameters
                [pscustomobject]@{ result = [pscustomobject]@{ worker_id = 'WORKER-A/job-1'; status = '2' } }
            }

            $won = Request-RmaJobClaim -Context $script:Context -SysId $script:SysId -WorkerId 'WORKER-A/job-1'

            $won | Should -BeTrue
            # The filter is the entire safety property. Without it the PATCH is
            # unconditional and two workers both "claim" the same job.
            Should -Invoke -ModuleName RMA.Runbooks Invoke-RmaRestMethod -Times 1 -ParameterFilter {
                $Uri -like '*sysparm_query=status%3D1*' -and $Method -eq 'PATCH'
            }
        }
    }

    Context 'when another worker already claimed the job' {
        It 'returns false so the job is not executed twice' {
            Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
                # The filtered PATCH matched nothing, or matched a row another worker owns.
                [pscustomobject]@{ result = [pscustomobject]@{ worker_id = 'WORKER-B/job-9'; status = '2' } }
            }

            Request-RmaJobClaim -Context $script:Context -SysId $script:SysId -WorkerId 'WORKER-A/job-1' |
            Should -BeFalse
        }

        It 'returns false when the filtered update matched no row at all' {
            Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ result = $null } }

            Request-RmaJobClaim -Context $script:Context -SysId $script:SysId -WorkerId 'WORKER-A/job-1' |
            Should -BeFalse
        }
    }

    Context 'when the claim request itself fails' {
        It 'returns false rather than proceeding unclaimed' {
            # This is the Create-ADGroup defect. The old code caught the failure and ran
            # the job anyway, leaving it Pending so the next poll re-executed it.
            Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { throw 'ServiceNow 503' }
            Mock -ModuleName RMA.Runbooks Write-RmaLog {}

            Request-RmaJobClaim -Context $script:Context -SysId $script:SysId -WorkerId 'WORKER-A/job-1' |
            Should -BeFalse
        }

        It 'logs a warning so a persistent failure is visible' {
            Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { throw 'ServiceNow 503' }
            Mock -ModuleName RMA.Runbooks Write-RmaLog {}

            $null = Request-RmaJobClaim -Context $script:Context -SysId $script:SysId -WorkerId 'W/1'

            Should -Invoke -ModuleName RMA.Runbooks Write-RmaLog -Times 1 -ParameterFilter {
                $Level -eq 'Warning'
            }
        }
    }

    Context 'input validation' {
        It 'rejects a malformed sys_id' {
            { Request-RmaJobClaim -Context $script:Context -SysId 'not-a-sys-id' -WorkerId 'W/1' } |
            Should -Throw
        }
    }
}
