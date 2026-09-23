# House rules

Everything above this file in the skill is deliberately generic. This is the one file
that names this repository's own functions, scripts and numbers, and the one file to
replace when the skill is reused elsewhere. The floor is PowerShell 7.2 (`PowerShellVersion`
in `src/RMA.Runbooks/RMA.Runbooks.psd1`).

## The mandatory gate's five repository-specific analyzer rules

`build/Invoke-Analysis.ps1` enforces five repository-specific rules — `Measure-RmaEmptyCatchBlock`, `Measure-RmaRuntimeModuleInstall`, `Measure-RmaUnpinnedModuleInstall`, `Measure-RmaScriptScopeReturn`, `Measure-RmaUnredactedObjectLogging` — defined in `build/rules/RmaRules.psm1`. Each is explained in its own section below.

## Validating this skill's own examples

Every PowerShell code block in this skill (outside `tools/fixtures/`) must parse and pass
PSScriptAnalyzer, unless its first line marks it `# WRONG` or `# skip-validate`. Check that
before committing an edit to any reference file:

```bash
pwsh -File .claude/skills/powershell-7-expert/tools/Test-SkillExample.ps1 -Path .claude/skills/powershell-7-expert
```

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
statements in its body — `Create-ADGroup.ps1`, a script from the previous library this one
replaced (not present in this repository; see `build/PSScriptAnalyzerSettings.psd1`'s own
comment on where the custom rules come from), once wrapped a job-claim call in `catch {}`, so a
failed claim still ran the job while the queue believed it was still pending, and the next poll
picked up and re-ran the same job. Handle the error, set a failure flag, or re-throw; an empty
block is never acceptable, not even with a comment inside it.

## No bare return at script scope

A bare `return` outside any function exits the entire runbook, not just the enclosing `if`.
`Update-EntraUser.ps1`, another script from that same previous library and likewise not present
here, used one to skip a single step and instead abandoned the whole queue:
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

## Pester is floored at 5.5.0 and capped below 6

Every file under `tests/Unit/` starts with
`#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }` — see
`references/testing-and-security.md` for why a test file should state a version at all.
Note what that means: `ModuleVersion` in `#Requires` is a *floor*, not a pin, so it does
nothing to stop Pester 6 being loaded. `build/Invoke-Tests.ps1` supplies the ceiling with
`Import-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99`, and prints the
version it loaded. Without that cap a machine with Pester 6 installed ran the suite on a
different major version than CI's 5.8.0, and the two only agreed by luck.

## Every exported function is registered and tested

A new public function lives in `src/RMA.Runbooks/Public/`, is listed under
`FunctionsToExport` in `src/RMA.Runbooks/RMA.Runbooks.psd1`, and has a corresponding test in
`tests/Unit/`. An unlisted function is not part of the module's documented surface (see
`references/function-design.md` on `FunctionsToExport`); an untested one drags line coverage
toward the floor below and can fail the build through `build/Assert-Coverage.ps1` instead.

`build/Test-ModuleManifestIntegrity.ps1` enforces the first two by parsing the AST of every
file under `Public/`, so a second function defined inside a file named after another one is
caught, and `.SYNOPSIS` and `[CmdletBinding()]` are checked per function rather than per
file. A helper that only the module calls belongs in `Private/`, where none of this applies.
It runs in CI, in the `module` job, alongside `build/Assert-ModuleVersionBump.ps1`.

## Say which context a function takes

Two context shapes travel through this module. `Connect-RmaServiceNow` returns an
`Rma.ServiceNowContext`, carrying `Instance`, `BaseUri` and `Headers`; `Test-RmaPrerequisite`
returns an `Rma.Context`, which adds `VaultName` and `ManagedIdentityClientId` and also answers
to `Rma.ServiceNowContext` so the queue functions accept it. Declare the one you need with
`[PSTypeName('Rma.Context')]` or `[PSTypeName('Rma.ServiceNowContext')]` rather than
`[pscustomobject]`, so handing `Connect-RmaGraph` the wrong one fails at binding instead of
as a property-not-found further in. A test fixture builds one by putting
`PSTypeName = 'Rma.ServiceNowContext'` in the hashtable literal.

## Coverage floor is 70% of lines

`build/Invoke-Tests.ps1` runs Pester with `CodeCoverage.Enabled` over
`src/RMA.Runbooks/Public` and `src/RMA.Runbooks/Private`, but sets no threshold of its own —
it only produces `tests/Coverage.xml`. The floor itself is enforced separately by
`build/Assert-Coverage.ps1`, whose `-MinimumPercent` defaults to `70`, and CI
(`.github/workflows/ci.yml`) calls it with `-MinimumPercent 70` explicitly. Both agree: 70%.

## Formatting comes from build/Invoke-Format.ps1

`build/PSScriptAnalyzerSettings.psd1` sets 4-space indentation, an opening brace on the same
line, and turns three checks off so assignments and `switch` arms can be aligned into columns
by hand: `PSAlignAssignmentStatement`, and `PSUseConsistentWhitespace`'s `CheckOperator` and
`CheckOpenBrace` (the rest of `PSUseConsistentWhitespace` — inner-brace, pipe and separator
spacing — stays on). `PSUseShouldProcessForStateChangingFunctions` and
`PSAvoidUsingWriteHost` are excluded repository-wide — the former because Pester helper
factories are not state-changing cmdlets, the latter because `Write-RmaLog` is the real
enforcement point for logging, not the analyzer. Run `build/Invoke-Format.ps1` before
committing instead of adjusting whitespace by hand; CI runs it with `-Check` and fails on any
diff it would still make.
