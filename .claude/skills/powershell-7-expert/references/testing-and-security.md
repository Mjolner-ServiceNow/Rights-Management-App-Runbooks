# Testing and security

Code that hides its cmdlet calls behind private wrappers or `.NET` objects cannot be mocked, so its bugs surface in production instead of in a test run. Code that mishandles secrets or untrusted input creates its own incidents. The examples below target the Pester 5 API (`Describe`/`Context`/`It`, `Should -Invoke`); pin `#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '<version>' }` to whichever Pester 5.x version your repository pins — see `references/house-rules.md` for the version this one pins. A newer Pester major version can be installed alongside 5.x — `Invoke-Pester` with no version pinned resolves to whichever is highest, which may not be the one a test file was written against. Check `Get-Module Pester` (or `Get-Module -ListAvailable Pester`) before assuming which API is loaded.

## Design for mockability

`Mock` intercepts PowerShell commands — cmdlets and functions — not method calls on a .NET object. Call `Invoke-RestMethod` (or another cmdlet) directly from the function under test so a test can mock it; wrapping the same call behind `$client.SendAsync(...)` on a raw .NET HTTP client removes the seam `Mock` needs, and nothing in Pester can intercept it.

```powershell
# WRONG
function Get-JobStatus {
    param([string] $JobId)
    $client = [System.Net.Http.HttpClient]::new()
    $client.GetStringAsync("https://api.example.com/jobs/$JobId").Result
}
```

```powershell
# RIGHT
function Get-JobStatus {
    param([string] $JobId)
    Invoke-RestMethod -Uri "https://api.example.com/jobs/$JobId"
}
```

## Take dependencies as parameters

A function that builds or resolves its own collaborator internally — constructs a client, reads a fixed config path, calls `Get-Date` mid-calculation — forces a test to reach for a global `Mock` of that ambient dependency instead of substituting it directly, and a global mock is heavier, leaks across tests in the same scope, and couples the test to an implementation detail. Take the collaborator as a parameter with a sensible default: production call sites stay just as short, and a test can pass a fake with no mock at all.

```powershell
# WRONG
function Get-JobAge {
    param([datetime] $Started)
    (Get-Date) - $Started
}
```

```powershell
# RIGHT
function Get-JobAge {
    param([datetime] $Started, [datetime] $Now = (Get-Date))
    $Now - $Started
}
```

## Keep side effects at the edges

One function that fetches, computes and writes forces a test of the computation to also mock the I/O around it. Split the computation into a pure function — data in, data out — and keep the fetching and writing in a thin caller around it; the pure part then needs no mocks at all.

```powershell
# WRONG
function Update-JobBudget {
    param([string] $JobId)
    $job = Invoke-RestMethod -Uri "https://api.example.com/jobs/$JobId"
    $job.Budget = $job.Spent * 1.1; Invoke-RestMethod -Uri $job.Uri -Method Put -Body $job
}
```

```powershell
# RIGHT
function Get-UpdatedBudget {
    param($Job)
    $Job.Budget = $Job.Spent * 1.1
    $Job
}
```

## Mock -ParameterFilter

A `Mock` with no `-ParameterFilter` replaces every call to that command with the same canned result, no matter what arguments it receives — a function under test that calls the same cmdlet against two different endpoints gets the same fake answer for both, and a bug that mixes them up passes anyway. Add `-ParameterFilter` so each mock only answers the calls it actually describes; stack several filtered mocks to cover several inputs.

```powershell
# WRONG
It 'reports the job and its parent as different statuses' {
    Mock Invoke-RestMethod { @{ status = 'Completed' } }
    Get-JobWithParent -JobId 42 -ParentId 1
}
```

```powershell
# RIGHT
It 'reports the job and its parent as different statuses' {
    Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/jobs/42' } -MockWith { @{ status = 'Completed' } }
    Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/jobs/1' } -MockWith { @{ status = 'Blocked' } }
    Get-JobWithParent -JobId 42 -ParentId 1
}
```

## Should -Invoke -Times -Exactly

Asserting only the return value lets a duplicate or missing side-effecting call pass unnoticed — the function can send a notification twice and the test still goes green. Assert the call count too. Confirmed in this environment (Pester 5.7.1): `Should -Invoke Get-Thing -Times 5 -Exactly` against 2 actual calls fails with `Expected Get-Thing to be called 5 times exactly, but was called 2 times`; the same assertion against `-Times 2` passes.

```powershell
# WRONG
It 'sends exactly one notification' {
    Mock Send-Notification
    Invoke-JobCompletionHandler -JobId 42
}
```

```powershell
# RIGHT
It 'sends exactly one notification' {
    Mock Send-Notification
    Invoke-JobCompletionHandler -JobId 42
    Should -Invoke Send-Notification -Times 1 -Exactly
}
```

## InModuleScope for private functions

A function a module does not export is invisible to a test file that only imported the module normally — calling it directly throws `CommandNotFoundException`. Wrap the call in `InModuleScope` instead of exporting the function just to make it reachable. Confirmed in this environment: calling a non-exported function from the test's own scope throws, while the same call inside `InModuleScope <ModuleName> { ... }` succeeds.

```powershell
# WRONG
It 'formats the job id' {
    Format-JobIdInternal -JobId 42 | Should -Be 'JOB-0042'
}
```

```powershell
# RIGHT
It 'formats the job id' {
    InModuleScope JobsModule {
        Format-JobIdInternal -JobId 42 | Should -Be 'JOB-0042'
    }
}
```

## BeforeAll versus BeforeEach

`BeforeAll` runs once per `Describe`/`Context`, not once per `It` — a mutable object (a `List[T]`, a hashtable) it creates is the *same instance* shared by every test in the block, so one test's mutation of it is visible to the next. `BeforeEach` runs before every `It` and gives each test its own instance. Confirmed in this environment: a `List[string]` created in `BeforeAll` and added to inside each `It` accumulates across tests (count 1, then count 2, not 1 then 1 again); moving the same creation into `BeforeEach` resets it before every test, so each `It` sees count 1. A plain scalar reassigned inside one `It`, by contrast, does not leak into the next `It` — only mutation of a shared reference leaks, not reassignment.

```powershell
# WRONG
Describe 'Job queue' {
    BeforeAll { $seen = [System.Collections.Generic.List[string]]::new() }
    It 'records the first job' { $seen.Add('a'); $seen.Count | Should -Be 1 }
    It 'records the second job' { $seen.Add('b'); $seen.Count | Should -Be 1 }
}
```

```powershell
# RIGHT
Describe 'Job queue' {
    BeforeEach { $seen = [System.Collections.Generic.List[string]]::new() }
    It 'records the first job' { $seen.Add('a'); $seen.Count | Should -Be 1 }
    It 'records the second job' { $seen.Add('b'); $seen.Count | Should -Be 1 }
}
```

## -Tag for integration tests

Tag any `Describe`/`Context` that hits a live dependency, and exclude that tag from the run that fires on every commit. Without a tag, a flaky endpoint or a network outage fails a suite that should have been able to run offline. Confirmed in this environment: with `$config.Filter.ExcludeTag = 'Integration'` set on a `PesterConfiguration`, `Invoke-Pester` reported the integration `Describe` as `NotRun` and skipped it entirely — its body, which would have thrown, never executed.

```powershell
# WRONG
Describe 'Get-JobFromApi' {
    It 'reaches the live API' {
        Get-JobFromApi -JobId 42 | Should -Not -BeNullOrEmpty
    }
}
```

```powershell
# RIGHT
Describe 'Get-JobFromApi' -Tag 'Integration' {
    It 'reaches the live API' {
        Get-JobFromApi -JobId 42 | Should -Not -BeNullOrEmpty
    }
}
```

## SecureString and PSCredential, not plaintext

Accept a credential as `[PSCredential]`, not as separate username and plaintext-password parameters — a plaintext `-Password` parameter can be logged, appears in `Get-History`, and shows in transcripts. Let the caller supply the credential interactively (`Get-Credential`) or from a secret store, never as a literal string your function converts. `ConvertTo-SecureString -AsPlainText -Force` is a smell everywhere except the one narrow point where a value first arrives as plaintext from a trust boundary you control (for example, a secret returned in-process by an already-authenticated, TLS-protected vault call, immediately wrapped and discarded) — PSScriptAnalyzer's `PSAvoidUsingConvertToSecureStringWithPlainText` (severity `Error`, confirmed in this environment) flags the pattern unconditionally because it cannot see that context, so any use still needs justifying in review rather than a blanket suppression.

```powershell
# WRONG
function Connect-RemoteHost {
    param([string] $UserName, [string] $Password)
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    New-PSSession -ComputerName $Server -Credential ([PSCredential]::new($UserName, $secure))
}
```

```powershell
# RIGHT
function Connect-RemoteHost {
    param([PSCredential] $Credential = (Get-Credential))
    New-PSSession -ComputerName $Server -Credential $Credential
}
```

At the one narrow point where this is legitimate, wrap the value the instant it arrives and drop the plaintext copy immediately — this still trips the analyzer rule unconditionally, which is why it is marked `skip-validate` rather than `RIGHT`:

```powershell
# skip-validate
$plaintextSecret = (Invoke-RestMethod -Uri $VaultUri -Authentication Bearer -Token $VaultToken).data.value
$secureSecret = ConvertTo-SecureString -String $plaintextSecret -AsPlainText -Force
Remove-Variable -Name plaintextSecret
```

## Retrieve secrets at run time

Fetch a secret from a store when the function runs instead of embedding it as a literal. `Get-Secret` belongs to `Microsoft.PowerShell.SecretManagement` (also used in `references/rest-api.md`), not built into `pwsh` — it needs that module installed and a vault registered, and it hands back a `SecureString` or plaintext depending on the parameter used, never a value you had to build from a literal yourself.

```powershell
# WRONG
$apiKey = 'PLACEHOLDER-NOT-A-REAL-KEY'
Invoke-RestMethod -Uri $Uri -Headers @{ Authorization = "Bearer $apiKey" }
```

```powershell
# RIGHT
$secureApiKey = Get-Secret -Name 'ApiKey'
Invoke-RestMethod -Uri $Uri -Authentication Bearer -Token $secureApiKey
```

## Redact before logging

Log named fields, never a whole response or request object — an object dumped to the log stream carries whatever it happens to contain, including tokens, connection strings and personal data that were never meant to leave the process. This repository enforces this in PSScriptAnalyzer — see `references/house-rules.md`.

```powershell
# WRONG
Write-Verbose "Job completed: $response"
```

```powershell
# RIGHT
Write-Verbose "Job $($response.JobId) completed with status $($response.Status)."
```

## Never Invoke-Expression

`Invoke-Expression` runs whatever string is handed to it as code — if any part of that string came from a caller, a file, or an API response, that source can run arbitrary commands. Splat a hashtable at the cmdlet you actually mean to call instead of assembling a command as text.

```powershell
# WRONG
Invoke-Expression "Get-ChildItem -Path $userPath -Filter $userFilter"
```

```powershell
# RIGHT
$params = @{ Path = $userPath; Filter = $userFilter }
Get-ChildItem @params
```

## Validate untrusted input with attributes

Data that crosses a trust boundary — a webhook payload, a REST request body, an argument passed from outside your own automation — needs validation at the parameter, not a hand-rolled `if` check buried in the function body. A validation attribute rejects the call during parameter binding, before a single line of the body runs; a hand-rolled check only fires once the body starts executing, so any body code placed above it — logging, a partial write, another call — still runs first on bad input.

```powershell
# WRONG
function Test-JobName {
    param([string] $JobName)
    if ($JobName -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Invalid job name' }
    $true
}
```

```powershell
# RIGHT
function Test-JobName {
    param([ValidatePattern('^[a-zA-Z0-9_-]+$')][string] $JobName)
    $true
}
```
