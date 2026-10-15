function Request-RmaJobRetry {
    <#
    .SYNOPSIS
        Asks Invoke-RmaQueueLoop to run the current job's body again shortly.
    .DESCRIPTION
        For a condition that clears on its own within a minute or two, where failing the job
        would only make someone queue it again. The case it was written for: Graph finds a
        user created moments ago, while another Graph endpoint, such as the authentication
        methods, does not know the user yet (#146).

        It throws. Invoke-RmaQueueLoop recognises the error, keeps the job claimed and runs
        the body again after each of its RetryDelaySeconds, 15, 30 and 60 by default. If the
        body asks once more after the last of them, the job fails with Reason, or completes
        with Reason as a warning when CompleteWhenExhausted is given. Any other error fails
        the job at once, as before. After a few jobs in a row have used up their retries, the
        loop stops retrying for the rest of the run, so a cause that will not clear does not
        make every job wait.

        A runbook body never retries or sleeps itself (docs/DECISIONS.md D1, D18). It calls
        this and lets the loop decide. Call it outside any try/catch of the body's own, or
        rethrow it from there, or the loop never sees it. Outside Invoke-RmaQueueLoop it is an
        ordinary terminating error.
    .PARAMETER Reason
        What is not ready yet, written for whoever reads the failed job: it becomes the job's
        exception if the retries run out.
    .PARAMETER CompleteWhenExhausted
        Complete the job, instead of failing it, if it is still not ready after the retries.
        For a delete or a removal whose object is not found: either it is gone, and the
        outcome ServiceNow asked for is true (docs/DECISIONS.md D15), or it has not reached
        Graph yet, and the retries give it the time to (D19).
    .EXAMPLE
        Request-RmaJobRetry -Reason "Entra ID user '$upn' exists, but Graph's authentication methods do not know it yet."
    .EXAMPLE
        Request-RmaJobRetry -CompleteWhenExhausted -Reason 'Entra user not found; nothing to delete'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $Reason,

        [switch] $CompleteWhenExhausted
    )

    # The error id is how Invoke-RmaQueueLoop tells this apart from a real failure, and the
    # target object carries what to do once the retries are used.
    $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($Reason),
            'RmaJobRetry',
            [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
            [pscustomobject]@{ CompleteWhenExhausted = $CompleteWhenExhausted.IsPresent }))
}
