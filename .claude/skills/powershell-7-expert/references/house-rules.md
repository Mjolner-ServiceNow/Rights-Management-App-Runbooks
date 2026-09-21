# House rules

Everything above this file in the skill is deliberately generic. This is the one file
that names this repository's own functions, scripts and numbers, and the one file to
replace when the skill is reused elsewhere. The floor is PowerShell 7.2 (`PowerShellVersion`
in `src/RMA.Runbooks/RMA.Runbooks.psd1`).

## Log through Write-RmaLog, not Write-Output or Write-Host

Call `Write-RmaLog -Level <Debug|Information|Warning|Error> -Message <string> -Data <hashtable>`.
Pass values as named fields in `-Data`; each one is routed through `ConvertTo-RmaSafeLogValue`
before it reaches the log line. Passing a whole object to `Write-Output`, `Write-Host` or
`Write-Information` instead skips that redaction — `Measure-RmaUnredactedObjectLogging` flags
a bare `$Payload`, `$Credential`, `$Secret`, `$ParameterObject` or `$JobQueueItem` passed to any
of those three cmdlets. `PSAvoidUsingWriteHost` is excluded repository-wide, so the analyzer
will not stop `Write-Host` on its own; use `Write-RmaLog` anyway so the record carries a level,
a correlation id and a timestamp.

```powershell
# WRONG
Write-Output $Payload
```

```powershell
# RIGHT
Write-RmaLog -Level Information -Message 'Job completed' -Data @{ jobId = $Payload.JobId; status = $Payload.Status }
```

## Call ServiceNow and Graph through Invoke-RmaRestMethod

Never call `Invoke-RestMethod` or `Invoke-WebRequest` directly against ServiceNow or Graph.
`Invoke-RmaRestMethod` (`src/RMA.Runbooks/Public/Invoke-RmaRestMethod.ps1`) wraps them with
bounded retry, exponential backoff and jitter, retrying only 408, 429, 5xx and transport
failures — a bare 4xx fails immediately instead of burning the job's time budget. It is the
repository-specific wrapper around the general `Invoke-RestMethod` patterns in
`references/rest-api.md`; use those patterns for building the URI, body and headers, then make
the call through this function.

```powershell
# WRONG
Invoke-RestMethod -Uri $Uri -Method Get
```

```powershell
# RIGHT
Invoke-RmaRestMethod -Uri $Uri -Method GET
```

## Empty catch blocks are a build failure here

`references/error-handling.md` teaches never to leave a `catch {}` empty; in this repository
that is not just style. `Measure-RmaEmptyCatchBlock` fails the analyzer on any `catch` with zero
statements in its body — `Create-ADGroup.ps1` once wrapped a job-claim call in `catch {}`, so a
failed claim still ran the job while the queue believed it was still pending, and the next poll
picked up and re-ran the same job. Handle the error, set a failure flag, or re-throw; an empty
block is never acceptable, not even with a comment inside it.

## No bare return at script scope

A bare `return` outside any function exits the entire runbook, not just the enclosing `if`.
`Update-EntraUser.ps1` used one to skip a single step and instead abandoned the whole queue:
no write-back to ServiceNow, the job stranded in Work in Progress. `Measure-RmaScriptScopeReturn`
enforces this; the one exception it recognizes is the `ShouldProcess` guard documented in
`references/function-design.md` (`if (-not $PSCmdlet.ShouldProcess(...)) { return }`), because
that `return` is inside a function and only exits the function. Outside a function, move the
logic into one instead of returning from script scope.

```powershell
# WRONG
if (-not $ready) { return }
Invoke-RmaQueueLoop
```

```powershell
# RIGHT
function Start-Runbook {
    if (-not $ready) { return }
    Invoke-RmaQueueLoop
}
Start-Runbook
```

## No module installation inside a runbook

Never call `Install-Module`, `Update-Module`, `Save-Module` or `Install-WindowsFeature` inside
a runbook — `Measure-RmaRuntimeModuleInstall` flags all four. A runtime `Install-Module` with no
pinned version once accumulated every published version on the Hybrid Worker and exhausted its
disk. Declare the dependency with `#Requires` and provision the worker once with
`scripts/Initialize-RmaWorker.ps1`, where every `Install-Module` call must pin
`-RequiredVersion` or `-MaximumVersion` — `Measure-RmaUnpinnedModuleInstall` flags one that
does not.

## Correlation id comes from Invoke-RmaQueueLoop

`Invoke-RmaQueueLoop` sets `$script:RmaCorrelationId` to the ServiceNow job's `sys_id` for the
duration of that job; `Write-RmaLog`'s `-CorrelationId` parameter defaults to it. Do not
generate your own id or thread one through as an extra parameter — read the ambient one so
every log line for a job can be queried by the same `sys_id` end to end.

## Every exported function is registered and tested

A new public function lives in `src/RMA.Runbooks/Public/`, is listed under
`FunctionsToExport` in `src/RMA.Runbooks/RMA.Runbooks.psd1`, and has a corresponding test in
`tests/Unit/`. An unlisted function is not part of the module's documented surface (see
`references/function-design.md` on `FunctionsToExport`); an untested one drags line coverage
toward the floor below and can fail the build through `build/Assert-Coverage.ps1` instead.

## Coverage floor is 70% of lines

`build/Invoke-Tests.ps1` runs Pester with `CodeCoverage.Enabled` over
`src/RMA.Runbooks/Public` and `src/RMA.Runbooks/Private`, but sets no threshold of its own —
it only produces `tests/Coverage.xml`. The floor itself is enforced separately by
`build/Assert-Coverage.ps1`, whose `-MinimumPercent` defaults to `70`, and CI
(`.github/workflows/ci.yml`) calls it with `-MinimumPercent 70` explicitly. Both agree: 70%.

## Formatting comes from build/Invoke-Format.ps1

`build/PSScriptAnalyzerSettings.psd1` sets 4-space indentation, an opening brace on the same
line, and turns `PSAlignAssignmentStatement` off so assignments and `switch` arms can be
aligned into columns by hand. `PSUseShouldProcessForStateChangingFunctions` and
`PSAvoidUsingWriteHost` are excluded repository-wide — the former because Pester helper
factories are not state-changing cmdlets, the latter because `Write-RmaLog` is the real
enforcement point for logging, not the analyzer. Run `build/Invoke-Format.ps1` before
committing instead of adjusting whitespace by hand; CI runs it with `-Check` and fails on any
diff it would still make.
