#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# .claude/skills/migrate-runbook/scripts/ConvertFrom-RmaJobStream.ps1 is how a migration's
# end-to-end test learns why a queue row failed. It used to drop every Error record
# without a word (#147). The stream entries below copy the shape Automation stored for a
# real job, one line per entry, with synthetic values.

BeforeAll {
    $script:Convert = (Resolve-Path "$PSScriptRoot/../../.claude/skills/migrate-runbook/scripts/ConvertFrom-RmaJobStream.ps1").Path

    function New-Entry([string] $Type, [string] $Text) { [pscustomobject]@{ Type = $Type; Text = $Text } }

    # The error view of one 'Job failed' record, wrapped where Automation wrapped it.
    function New-ErrorView([string] $Timestamp, [string] $Head, [string[]] $Tail) {
        New-Entry Error 'Write-RmaLog: C:\Program Files\PowerShell\Modules\RMA.Runbooks\2.2.0\Public\Invoke-RmaQueueLoop.ps1:240'
        New-Entry Error 'Line |'
        New-Entry Error " 240 |  .             Write-RmaLog -Level Error -Message 'Job failed' -Data @{  ."
        New-Entry Error '     |                ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
        New-Entry Error "     | {`"timestamp`":`"$Timestamp`",`"level`":`"Error`",$Head"
        foreach ($line in $Tail) { New-Entry Error "     | $line" }
    }

    $script:SysId = '0123456789abcdef0123456789abcdef'
    $script:Processing = New-Entry Output ('{"timestamp":"2026-10-13T12:05:34.6Z","level":"Information","message":"Processing job",' +
        "`"runbook`":`"Invoke-RmaQueueLoop`",`"correlationId`":`"$SysId`",`"worker`":`"contoso-hw01`",`"data`":{`"sysId`":`"$SysId`"}}")
}

Describe 'ConvertFrom-RmaJobStream' -Tag 'Unit' {

    It 'returns a Job failed record that Automation wrapped across error stream entries' {
        $stream = @(
            $Processing
            New-ErrorView -Timestamp '2026-10-13T12:05:34.7Z' -Head '"message":"Job' -Tail @(
                "failed`",`"runbook`":`"Invoke-RmaQueueLoop`",`"correlationId`":`"$SysId`",`"worker`":`"contoso-hw01`",`"data`":{`"sysId`":`"$SysId`",`"error`":`"Payload field 'group' is empty. (at line 71)`"}}"
            )
        )

        $records = @(& $Convert -Stream $stream)

        $records.Count | Should -Be 2
        $failed = $records | Where-Object level -EQ 'Error'
        $failed.message | Should -Be 'Job failed'
        $failed.data.sysId | Should -Be $SysId
        $failed.data.error | Should -Be "Payload field 'group' is empty. (at line 71)"
    }

    It 'joins the lines of one error record when output entries fall between them' {
        $view = @(New-ErrorView -Timestamp '2026-10-13T12:05:35.1Z' -Head '"message":"Job' -Tail @(
                "failed`",`"data`":{`"sysId`":`"$SysId`",`"error`":`"Graph refused the"
                'request. (at line 71)"}}'
            ))
        $stream = @($view[0..4]) + @($Processing) + @($view[5..6])

        $records = @(& $Convert -Stream $stream)

        ($records | Where-Object level -EQ 'Error').data.error | Should -Be 'Graph refused the request. (at line 71)'
    }

    It 'rejoins a wrap that split a number, where a space would not parse' {
        $stream = @(New-ErrorView -Timestamp '2026-10-13T12:05:36.0Z' -Head '"message":"Retry","data":{"attempt":1' -Tail @(
                '2}}'
            ))

        (@(& $Convert -Stream $stream)).data.attempt | Should -Be 12
    }

    It 'returns every record of several error views in a row' {
        $stream = foreach ($n in 1..3) {
            New-ErrorView -Timestamp "2026-10-13T12:05:3$($n).0Z" -Head '"message":"Job' -Tail @("failed`",`"data`":{`"error`":`"row $n`"}}")
        }

        (@(& $Convert -Stream $stream)).data.error | Should -Be @('row 1', 'row 2', 'row 3')
    }

    It 'reads one-line records from the output, warning and verbose streams' {
        $stream = @(
            $Processing
            New-Entry Warning 'WARNING: {"timestamp":"2026-10-13T12:13:05.4Z","level":"Warning","message":"Nothing to remove"}'
            New-Entry Verbose 'VERBOSE: {"timestamp":"2026-10-13T12:13:05.5Z","level":"Debug","message":"Job claim lost to another worker"}'
        )

        (@(& $Convert -Stream $stream)).level | Should -Be @('Information', 'Warning', 'Debug')
    }

    It 'ignores an error that is not a log record' {
        # The runbook's own throw at the end of a job with failed rows.
        $stream = @(
            New-Entry Error 'Exception: C:\Temp\runbook.ps1:131'
            New-Entry Error 'Line |'
            New-Entry Error ' 131 |      throw "$($summary.Failed) of $($summary.Processed) job(s) failed. .'
            New-Entry Error '     |      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
            New-Entry Error '     | 6 of 11 job(s) failed. Individual reasons are on the ServiceNow records.'
        )

        @(& $Convert -Stream $stream).Count | Should -Be 0
    }
}
