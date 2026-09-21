function Get-RmaWorkerId {
    <#
    .SYNOPSIS
        Returns an identifier unique to this runbook execution.
    .DESCRIPTION
        Machine plus Automation job id, so two runs on the same worker are distinguishable.
        PSPrivateMetadata is set by Azure Automation and absent everywhere else, which is
        why it is read defensively rather than assumed.
    .NOTES
        Internal. It lived in Public/Request-RmaJobClaim.ps1 and was never listed in
        FunctionsToExport, so it was unreachable from a runbook while looking exported.
        Test-ModuleManifestIntegrity.ps1 compared file names rather than function names and
        could not see it; it now parses the AST.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $jobId = 'local'
    if (Get-Variable -Name PSPrivateMetadata -Scope Global -ErrorAction SilentlyContinue) {
        $meta = Get-Variable -Name PSPrivateMetadata -Scope Global -ValueOnly
        if ($meta -and $meta.PSObject.Properties.Name -contains 'JobId' -and $meta.JobId) {
            $jobId = "$($meta.JobId)"
        }
    }
    # Not $env:COMPUTERNAME: that is null off Windows, and a worker id of '/local' makes
    # the claim read-back meaningless when the suite runs on a Linux CI runner.
    '{0}/{1}' -f [Environment]::MachineName, $jobId
}
