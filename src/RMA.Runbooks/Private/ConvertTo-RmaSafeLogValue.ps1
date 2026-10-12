function ConvertTo-RmaSafeLogValue {
    <#
    .SYNOPSIS
        Redacts values whose property name suggests a secret, and secrets inside strings.
    .DESCRIPTION
        Defence in depth for logging. A previous incident wrote a new user's password to the
        job log by emitting a whole payload object; anything routed through Write-RmaLog is
        scrubbed so that mistake cannot recur silently.

        Property names are matched by pattern, after dropping case, '_', '-', '.' and
        spaces, so access_token, client-secret and adPassword are caught as well as
        password. An exact list missed all three (#29).

        Every string, including Write-RmaLog's -Message, is scanned for secrets that
        travel inside text: Bearer and Basic credentials, JWTs, key=value or "key":"value"
        pairs with a secret-like key, and SAS signatures. Error messages and URIs are
        where these turn up.
    .NOTES
        Internal. Redaction is a safety net, not a licence: log named fields, never a
        whole payload (RmaAvoidUnredactedObjectLogging).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $InputObject,
        [int] $Depth = 0
    )

    $secretName = 'password|passwd|pwd|secret|token|credential|authorization|assertion|thumbprint|cookie|connectionstring|(api|private|account|access|client|signing|shared)key'

    if ($null -eq $InputObject) { return $null }
    if ($Depth -ge 8) { return '<max-depth>' }

    if ($InputObject -is [string]) {
        $text = $InputObject
        # Bearer and Basic carry the credential itself.
        $text = $text -replace '(?i)\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+/]+=*', '$1 <redacted>'
        # A JWT, wherever it appears: three base64url segments, the first two JSON.
        $text = $text -replace 'eyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*', '<redacted>'
        # key=value, key: value and "key":"value", when the key looks like a secret.
        $text = $text -replace "(?i)([`"']?[\w.-]*(?:$secretName)[\w.-]*[`"']?\s*[:=]\s*)(`"[^`"]*`"|'[^']*'|[^\s&,;`"'}]+)", '$1<redacted>'
        # A SAS token's signature.
        $text = $text -replace '(?i)([?&]sig=)[^&\s"]+', '$1<redacted>'
        return $text
    }

    if ($InputObject.GetType().IsPrimitive -or $InputObject -is [datetime] -or
        $InputObject -is [datetimeoffset] -or $InputObject -is [guid] -or $InputObject -is [enum]) {
        return $InputObject
    }

    $isSecret = { param($Name) ("$Name" -replace '[\s_.-]', '') -match "(?i)$secretName" }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $InputObject.Keys) {
            $out[$key] = if (& $isSecret $key) { '<redacted>' }
            else { ConvertTo-RmaSafeLogValue -InputObject $InputObject[$key] -Depth ($Depth + 1) }
        }
        return $out
    }

    # The comma keeps the array whole. A returned array is unrolled into the pipeline, so an
    # empty one reached the log as null and a one-element one as a bare scalar: a field's JSON
    # type depended on how many items it held, and a KQL mv-expand on it broke at one.
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return , @(foreach ($item in $InputObject) { ConvertTo-RmaSafeLogValue -InputObject $item -Depth ($Depth + 1) })
    }

    $out = @{}
    foreach ($prop in $InputObject.PSObject.Properties) {
        $out[$prop.Name] = if (& $isSecret $prop.Name) { '<redacted>' }
        else { ConvertTo-RmaSafeLogValue -InputObject $prop.Value -Depth ($Depth + 1) }
    }
    return $out
}
