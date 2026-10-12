function Update-RmaConnection {
    <#
    .SYNOPSIS
        Reconnects Graph and Exchange Online before their tokens expire.
    .DESCRIPTION
        Connect-RmaGraph and Connect-RmaExchange give the SDK a federated token that it
        keeps for the whole session and cannot renew, so a run that outlives the token
        failed part-way through, on whichever job it was on (#30). Both register their
        connection with the token's expiry; this function connects again, with a newly
        minted token, any connection that expires within MinimumValidityMinutes.

        Invoke-RmaQueueLoop calls it before every job, so a runbook body never has to. A
        single job that runs for longer than a token lives, such as a full directory
        import, calls it between pages instead. It costs nothing when no connection is
        close to expiry, and does nothing when none was made.
    .PARAMETER MinimumValidityMinutes
        A connection with less time than this left is renewed. It must cover the longest
        stretch between two calls: one job, or one page of an import.
    .EXAMPLE
        Update-RmaConnection
    .EXAMPLE
        foreach ($page in $pages) { Update-RmaConnection; ... }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [ValidateRange(1, 50)]
        [int] $MinimumValidityMinutes = 15
    )

    $threshold = (Get-Date).ToUniversalTime().AddMinutes($MinimumValidityMinutes)

    # A copy of the keys: reconnecting writes the session back into the same dictionary.
    foreach ($kind in @($script:RmaSessions.Keys)) {
        $session = $script:RmaSessions[$kind]
        if ($session.ExpiresOn -gt $threshold) { continue }
        if (-not $PSCmdlet.ShouldProcess($session.Name, 'Reconnect with a new token')) { continue }

        Write-RmaLog -Level Information -Message "Renewing the $($session.Name) connection before its token expires" -Data @{
            expiresOn = $session.ExpiresOn.ToString('o'); minimumValidityMinutes = $MinimumValidityMinutes
        }
        $parameters = $session.Parameters
        switch ($kind) {
            'Graph'    { Connect-RmaGraph @parameters -Force }
            'Exchange' { Connect-RmaExchange @parameters -Force }
        }
    }
}
