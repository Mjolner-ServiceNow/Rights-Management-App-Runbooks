# REST APIs

`Invoke-RestMethod` and `Invoke-WebRequest` are PowerShell's built-in HTTP clients; nothing here needs an external module. Get authentication, body encoding and pagination right, and most integration bugs disappear before they start.

## Invoke-RestMethod vs. Invoke-WebRequest

`Invoke-RestMethod` parses the response body for you (JSON, XML) and hands back the parsed object directly — the right default for calling a REST API. Reach for `Invoke-WebRequest` only when the status code, response headers or raw content matter alongside the body; wrapping every call in `Invoke-WebRequest` just to reach `.Content` throws away parsing `Invoke-RestMethod` already does for free.

```powershell
# WRONG
$response = Invoke-WebRequest -Uri $Uri -Authentication Bearer -Token $Token
$data = $response.Content | ConvertFrom-Json
```

```powershell
# RIGHT
$data = Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $Token
```

## -Authentication Bearer -Token instead of a hand-built header

Pass a `SecureString` to `-Token` with `-Authentication Bearer` instead of writing `Authorization: Bearer ...` into a `-Headers` hashtable by hand. `-Token` requires a `SecureString`: binding a plain string fails before any network call is made. Confirmed in this environment (pwsh 7.5.4): `Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token 'plain-string-token'` raises `Cannot bind parameter 'Token'. Cannot convert the value of type "System.String" to type "System.Security.SecureString".` — a parameter-binding error, so it never reaches the wire; the same call with a real `SecureString` gets past binding and fails only on DNS resolution.

```powershell
# WRONG
$headers = @{ Authorization = "Bearer $token" }
Invoke-RestMethod -Uri $Uri -Headers $headers
```

```powershell
# RIGHT
$secureToken = Get-Secret -Name 'ApiToken'
Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $secureToken
```

## Request bodies: ConvertTo-Json -Depth

`ConvertTo-Json`'s default `-Depth` is 2: once serialization has expanded two levels of *nested objects*, anything further in is stringified as its .NET type name instead of its content, and a warning goes to the error stream. Verified in this environment: a hashtable nested three levels deep (two levels of contained objects below the root) still serializes in full, because only two nested-object levels are in play; add one more level and the innermost object collapses to the literal string `System.Collections.Hashtable`. Use `-Depth 10` (or deeper, for irregular payloads) for any body with more than a shallow, flat shape — the failure mode is silent unless you are watching the warning stream.

```powershell
# WRONG
$body = @{ user = @{ profile = @{ name = @{ first = 'Ada' } } } } | ConvertTo-Json
```

```powershell
# RIGHT
$body = @{ user = @{ profile = @{ name = @{ first = 'Ada' } } } } | ConvertTo-Json -Depth 10
```

## -ContentType

Set `-ContentType` explicitly on any call that sends a body. Without it, the server may reject the request or guess wrong about how to parse the payload.

```powershell
# WRONG
Invoke-RestMethod -Uri $Uri -Method Post -Body $body
```

```powershell
# RIGHT
Invoke-RestMethod -Uri $Uri -Method Post -Body $body -ContentType 'application/json'
```

## Handling 4xx without an exception: -SkipHttpErrorCheck and -StatusCodeVariable

By default, a non-2xx response makes `Invoke-RestMethod` throw a terminating error, so reading the body of a 404 means unwrapping it from the caught exception's `ErrorDetails`. `-SkipHttpErrorCheck` turns that throw off: the call returns normally regardless of status, parsing the body exactly as it would for a 200. Pair it with `-StatusCodeVariable <name>` (a bare variable name, no `$`) to capture the numeric status in a variable of your choosing, since the response no longer carries it via a caught exception. Both parameters are present on `Invoke-RestMethod` in this environment (pwsh 7.5.4 and 7.6.0 — confirmed via `(Get-Command Invoke-RestMethod).Parameters.Keys`); no pre-7.4 `pwsh` was available locally to pin the exact version that introduced them, so check `(Get-Command Invoke-RestMethod).Parameters.Keys` on your target runtime before depending on them below the 7.2 floor this skill targets.

```powershell
# WRONG
try { $result = Invoke-RestMethod -Uri $Uri -ErrorAction Stop }
catch { $result = $_.ErrorDetails.Message | ConvertFrom-Json }
```

```powershell
# RIGHT
$result = Invoke-RestMethod -Uri $Uri -SkipHttpErrorCheck -StatusCodeVariable statusCode
if ($statusCode -ge 400) { Write-Warning "Request failed with status $statusCode" }
```

## Retrying 429 and 5xx, honouring Retry-After

Wrap the call in `Invoke-WithRetry` (`references/error-handling.md`) instead of hand-rolling another retry loop. `Invoke-WithRetry` itself does not read HTTP status codes — it retries whatever exception its script block throws, doubling its own delay each time — so honour a `Retry-After` response header from inside the script block: catch the failure, sleep for the server-requested delay if one was given, then re-throw so `Invoke-WithRetry` still counts the attempt and applies its own backoff on top.

```powershell
# WRONG
for ($i = 0; $i -lt 3; $i++) {
    try { Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $Token; break }
    catch { Start-Sleep -Seconds 5 }
}
```

```powershell
# RIGHT
Invoke-WithRetry -MaxAttempts 5 -ScriptBlock {
    try { Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $Token -ErrorAction Stop }
    catch {
        $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
        if ($retryAfter) { Start-Sleep -Seconds $retryAfter }; throw
    }
}
```

`Retry-After` can also arrive as an HTTP date instead of a delta in seconds; the example above handles only the seconds form, which is what 429 responses use in practice — check `.Headers.RetryAfter.Date` too if an API you call sends the date form.

## -TimeoutSec

Set a timeout on every outbound call. `Invoke-WithRetry` only reacts once a call returns or throws — it does nothing for a call that hangs forever, so the timeout is what turns a stuck connection into a retryable failure in the first place.

```powershell
# WRONG
Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $Token
```

```powershell
# RIGHT
Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $Token -TimeoutSec 30
```

Confirmed in this environment: `-TimeoutSec` still binds and works — it is now an alias for `-OperationTimeoutSeconds` (`(Get-Command Invoke-RestMethod).Parameters['OperationTimeoutSeconds'].Aliases` returns `TimeoutSec`). Newer code targeting 7.4+ can use `-ConnectionTimeoutSeconds` and `-OperationTimeoutSeconds` directly for separate control over the connect phase versus the whole call; `-TimeoutSec` is the portable spelling at the 7.2 floor this skill targets.

## Pagination: @odata.nextLink

Follow the continuation link the server hands back instead of assuming one response holds every item. Loop until the server stops returning a next link.

```powershell
# WRONG
$items = (Invoke-RestMethod -Uri 'https://api.example.com/v1/items' -Authentication Bearer -Token $Token).value
```

```powershell
# RIGHT
$items = [System.Collections.Generic.List[object]]::new()
$uri = 'https://api.example.com/v1/items'
while ($uri) {
    $response = Invoke-RestMethod -Uri $uri -Authentication Bearer -Token $Token
    $items.AddRange($response.value)
    $uri = $response.'@odata.nextLink'
}
```

## Pagination: Link header

`Invoke-WebRequest`'s response object exposes `RelationLink`, a hashtable of the parsed `Link` header keyed by relation (`next`, `prev`, `last`) — use it instead of parsing the raw header text yourself.

```powershell
# WRONG
$page = Invoke-WebRequest -Uri 'https://api.example.com/v1/items?limit=100' -Authentication Bearer -Token $Token
$items = $page.Content | ConvertFrom-Json
```

```powershell
# RIGHT
$items = [System.Collections.Generic.List[object]]::new()
$uri = 'https://api.example.com/v1/items?limit=100'
while ($uri) {
    $page = Invoke-WebRequest -Uri $uri -Authentication Bearer -Token $Token
    $items.AddRange(($page.Content | ConvertFrom-Json))
    $uri = $page.RelationLink['next']
}
```

## Pagination: offset/limit

Advance the offset by the page size and keep requesting pages until a short page (fewer items than the limit) signals the end.

```powershell
# WRONG
$items = (Invoke-RestMethod -Uri 'https://api.example.com/v1/items?offset=0&limit=100' -Authentication Bearer -Token $Token).value
```

```powershell
# RIGHT
$items = [System.Collections.Generic.List[object]]::new()
$offset = 0; $limit = 100
do {
    $page = Invoke-RestMethod -Uri "https://api.example.com/v1/items?offset=$offset&limit=$limit" -Authentication Bearer -Token $Token
    $items.AddRange($page.value)
    $offset += $limit
} while ($page.value.Count -eq $limit)
```

## Never put a token or PII in the URL

A query string ends up in web server access logs, proxy logs and browser or shell history. Put a token in a header or in `-Token`, and never append personal data to the URI, even for a `GET`.

```powershell
# WRONG
Invoke-RestMethod -Uri "https://api.example.com/v1/items?api_key=$token&email=$userEmail"
```

```powershell
# RIGHT
$secureToken = Get-Secret -Name 'ApiToken'
Invoke-RestMethod -Uri 'https://api.example.com/v1/items' -Authentication Bearer -Token $secureToken
```
