function Invoke-RmaRestMethod {
    <#
    .SYNOPSIS
        Invoke-RestMethod with bounded retry, exponential backoff and jitter.
    .DESCRIPTION
        The previous implementation made 274 unguarded REST calls, so a single transient
        502 from ServiceNow failed a job that would have succeeded on a retry.

        Retries only on transient conditions: 408, 429 and 5xx, plus transport-level
        failures. A 4xx other than 408/429 is a caller error and fails immediately, because
        retrying it just delays the inevitable and burns the job's time budget.

        Honours Retry-After when the service supplies it.
    .PARAMETER MaxAttempts
        Total attempts including the first. 1 disables retry.
    .EXAMPLE
        Invoke-RmaRestMethod -Uri $uri -Method GET -Headers $h
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $Uri,

        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string] $Method = 'GET',

        [hashtable] $Headers = @{},

        [object] $Body,

        [string] $ContentType = 'application/json',

        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4,

        [ValidateRange(1, 300)]
        [int] $TimeoutSeconds = 60,

        # Milliseconds. Doubles each attempt, with jitter applied on top.
        [ValidateRange(50, 30000)]
        [int] $BaseDelayMs = 500
    )

    $transient = @(408, 429, 500, 502, 503, 504)
    $attempt = 0

    while ($true) {
        $attempt++
        try {
            $params = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $Headers
                ContentType = $ContentType
                TimeoutSec  = $TimeoutSeconds
                ErrorAction = 'Stop'
            }
            if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) { $params['Body'] = $Body }

            return Invoke-RestMethod @params
        } catch {
            # Every read here is guarded. The exception's shape varies by PowerShell
            # host and by whether the failure was transport or HTTP level, and an
            # unguarded read throws under StrictMode, converting a retryable failure
            # into a hard one.
            $response = Get-RmaProperty -InputObject $_.Exception -Name 'Response'
            $statusRaw = Get-RmaProperty -InputObject $response -Name 'StatusCode'
            $status = if ($null -ne $statusRaw) { [int] $statusRaw } else { $null }

            $isTransient = ($null -eq $status) -or ($transient -contains $status)
            $isLast      = $attempt -ge $MaxAttempts

            if (-not $isTransient -or $isLast) {
                $label = if ($status) { "HTTP $status" } else { 'transport failure' }
                throw "$Method $Uri failed after $attempt attempt(s) ($label): $($_.Exception.Message)"
            }

            # Prefer the server's own guidance when present.
            $delayMs = $BaseDelayMs * [math]::Pow(2, $attempt - 1)
            $headers = Get-RmaProperty -InputObject $response -Name 'Headers'
            if ($headers) {
                $retryAfter = $headers | Where-Object { (Get-RmaProperty -InputObject $_ -Name 'Key') -ieq 'Retry-After' } |
                Select-Object -First 1
                $seconds = 0
                if ($retryAfter -and [int]::TryParse("$((Get-RmaProperty -InputObject $retryAfter -Name 'Value') | Select-Object -First 1)", [ref] $seconds) -and $seconds -gt 0) {
                    $delayMs = $seconds * 1000
                }
            }
            # Jitter prevents a fleet of workers retrying in lockstep.
            $delayMs = [int]($delayMs * (0.75 + (Get-Random -Minimum 0.0 -Maximum 0.5)))

            Write-RmaLog -Level Warning -Message 'Transient request failure, retrying' -Data @{
                uri = $Uri; method = $Method; attempt = $attempt; maxAttempts = $MaxAttempts
                status = $status; delayMs = $delayMs
            }
            Start-Sleep -Milliseconds $delayMs
        }
    }
}
