function Get-RmaWorkerId {
    <#
    .SYNOPSIS
        Returns an identifier unique to this runbook execution.
    .DESCRIPTION
        Machine plus something unique to the execution, so two runs on the same worker are
        distinguishable. The claim read-back and the heartbeat's worker filter both depend
        on that: two runs that share an id both believe they won the same claim.

        The part after the slash is the first of these that is available:

          1. The Automation job id, from $PSPrivateMetadata. Older sandboxes set it, and it
             is the most useful value because it names the job in Azure.
          2. The sandbox id, from AUTOMATION_ASSET_SANDBOX_ID. A Hybrid Worker job on a
             runtime environment (PowerShell 7.x) has no $PSPrivateMetadata variable, and
             the environment variable of that name holds the literal text
             'System.Collections.Hashtable', so the job id is not available anywhere. The
             sandbox id is a GUID unique per job, including for two jobs running at once.
          3. The process, by id and start time. Anywhere else: a local run, a test, a dev
             run on a worker over SSH.

        Every source is process-wide, so the id is the same from any runspace in the
        process, including the heartbeat thread's.

        This used to fall back to 'local'. On a runtime environment that was every real
        job, so every job on a worker shared the id '<machine>/local'.
    .NOTES
        Internal. It lived in Public/Request-RmaJobClaim.ps1 and was never listed in
        FunctionsToExport, so it was unreachable from a runbook while looking exported.
        Test-ModuleManifestIntegrity.ps1 compared file names rather than function names and
        could not see it; it now parses the AST.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $execution = $null

    if (Get-Variable -Name PSPrivateMetadata -Scope Global -ErrorAction SilentlyContinue) {
        $meta = Get-Variable -Name PSPrivateMetadata -Scope Global -ValueOnly
        $jobId = if ($meta) { Get-RmaProperty -InputObject $meta -Name 'JobId' }
        if ($jobId) { $execution = "$jobId" }
    }

    if (-not $execution) {
        # A GUID or nothing. The value comes from the environment, and a malformed one must
        # not end up inside the sysparm_query the claim and the heartbeat build from it.
        $sandbox = [guid]::Empty
        if ([guid]::TryParse("$env:AUTOMATION_ASSET_SANDBOX_ID", [ref] $sandbox) -and $sandbox -ne [guid]::Empty) {
            $execution = "sandbox-$sandbox"
        }
    }

    if (-not $execution) {
        $process = [Diagnostics.Process]::GetCurrentProcess()
        $execution = 'process-{0}-{1:yyyyMMddTHHmmssfff}' -f $process.Id, $process.StartTime.ToUniversalTime()
    }

    # Not $env:COMPUTERNAME: that is null off Windows, and a worker id of '/local' makes
    # the claim read-back meaningless when the suite runs on a Linux CI runner.
    '{0}/{1}' -f [Environment]::MachineName, $execution
}
