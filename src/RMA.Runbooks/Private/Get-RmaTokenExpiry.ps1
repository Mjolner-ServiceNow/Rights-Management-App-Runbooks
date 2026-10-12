function Get-RmaTokenExpiry {
    <#
    .SYNOPSIS
        Returns when an access token expires, in UTC, from its own exp claim.
    .DESCRIPTION
        Connect-RmaGraph and Connect-RmaExchange hand the SDKs a token that the SDKs keep
        for the life of the session, so the session expires with it (#30). Reading exp from
        the token itself means the expiry is the one Entra issued, whichever cache or
        exchange produced the token.

        A token that cannot be read, for example one that is not a JWT, is treated as
        expiring after the fallback, which is shorter than Entra's shortest default
        lifetime, so the session is renewed too early rather than too late.
    .NOTES
        Internal. Never logs or returns the token.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $AccessToken,
        [ValidateRange(1, 1440)] [int] $FallbackMinutes = 55
    )

    $now = (Get-Date).ToUniversalTime()
    $parts = $AccessToken.Split('.')
    if ($parts.Count -ne 3) { return $now.AddMinutes($FallbackMinutes) }

    try {
        # base64url to base64, padded to a multiple of four.
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        $exp = Get-RmaProperty -InputObject $claims -Name 'exp'
        if ($null -eq $exp) { return $now.AddMinutes($FallbackMinutes) }
        return [DateTimeOffset]::FromUnixTimeSeconds([long] $exp).UtcDateTime
    } catch {
        # Not a readable JWT. The token is still used; only its expiry is guessed.
        Write-Verbose "Token expiry not readable, assuming $FallbackMinutes minutes: $($_.Exception.Message)"
        return $now.AddMinutes($FallbackMinutes)
    }
}
