# REST APIs

`Invoke-RestMethod` and `Invoke-WebRequest` are PowerShell's built-in HTTP clients — no external module needed to make the call itself. Get authentication, body encoding and pagination right, and most integration bugs disappear before they start.

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

Pass a `SecureString` to `-Token` with `-Authentication Bearer` instead of writing `Authorization: Bearer ...` into a `-Headers` hashtable by hand. `-Token` requires a `SecureString`: binding a plain string fails before any network call is made. Confirmed in this environment (pwsh 7.5.4): `Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token 'plain-string-token'` raises `Cannot bind parameter 'Token'. Cannot convert the value of type "System.String" to type "System.Security.SecureString".` — a parameter-binding error, so it never reaches the wire; the same call with a real `SecureString` gets past binding and fails only on DNS resolution. The examples below get that `SecureString` from `Get-Secret`, a cmdlet of the `Microsoft.PowerShell.SecretManagement` module (not built into `pwsh`) that returns a secret already as a `SecureString`; it needs the module installed and a vault registered — never build the `SecureString` by converting a plaintext token, which is its own PSScriptAnalyzer finding (`PSAvoidUsingConvertToSecureStringWithPlainText`).

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

By default, a non-2xx response makes `Invoke-RestMethod` throw a terminating error, so reading the body of a 404 means unwrapping it from the caught exception's `ErrorDetails`. `-SkipHttpErrorCheck` turns that throw off: the call returns normally regardless of status, parsing the body exactly as it would for a 200. Pair it with `-StatusCodeVariable <name>` (a bare variable name, no `$`) to capture the numeric status in a variable of your choosing, since the response no longer carries it via a caught exception. Both parameters are present on `Invoke-RestMethod` in this environment (pwsh 7.5.4 and 7.6.0 — confirmed via `(Get-Command Invoke-RestMethod).Parameters.Keys`) and are commonly documented as landing in PowerShell 7.4, but that version number is not verified here: no pre-7.4 `pwsh` was available locally to test against. Treat them as probably needing 7.4+ and confirm with `(Get-Command Invoke-RestMethod).Parameters.Keys` on your actual target runtime before relying on them.

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

Set a timeout on every outbound call. `Invoke-WithRetry` only reacts once a call returns or throws, so an unbounded call never reaches its `catch` and never gets retried — it just hangs. `-TimeoutSec` bounds only the time to establish the connection; a server that accepts the connection and then stalls mid-response is not covered by it. Add `-OperationTimeoutSeconds` alongside it when the whole call, not just the connect phase, needs a ceiling.

```powershell
# WRONG
Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $Token
```

```powershell
# RIGHT
Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $Token -TimeoutSec 10 -OperationTimeoutSeconds 30
```

Confirmed in this environment: `(Get-Command Invoke-RestMethod).Parameters['OperationTimeoutSeconds'].Aliases` returns nothing — `-OperationTimeoutSeconds` has no alias. Enumerating which parameter actually carries the `TimeoutSec` alias instead — `(Get-Command Invoke-RestMethod).Parameters.GetEnumerator() | Where-Object { $_.Value.Aliases -contains 'TimeoutSec' } | ForEach-Object { $_.Key }` — returns `ConnectionTimeoutSeconds`. So `-TimeoutSec` is the portable, 7.2-floor spelling for the connect-phase bound only; `-ConnectionTimeoutSeconds` is its full 7.4+ name, and `-OperationTimeoutSeconds` (probably also 7.4+, unverified here — see the `-SkipHttpErrorCheck` section above) is the separate, newer parameter for the whole-call bound.

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
