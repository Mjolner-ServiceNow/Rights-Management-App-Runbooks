function Get-RmaGlideDateTime {
    <#
    .SYNOPSIS
        Formats a moment as a ServiceNow Date/Time value: UTC, 'yyyy-MM-dd HH:mm:ss'.
    .DESCRIPTION
        The Table API reads a Date/Time field in the internal format, which is UTC without
        a 'T', an offset or fractions of a second. It does not reject anything else. Given
        ISO 8601 ('2026-09-30T12:24:25.8533277Z') it keeps the date, drops the time and
        stores midnight. That was found on a real instance: every claimed_at read as
        00:00:00, so a heartbeat renewed nothing, and from half past midnight the watchdog
        saw every running job as stale.
    .PARAMETER Date
        The moment to format. Defaults to now. Converted to UTC first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [datetime] $Date = [datetime]::UtcNow
    )

    $Date.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}
