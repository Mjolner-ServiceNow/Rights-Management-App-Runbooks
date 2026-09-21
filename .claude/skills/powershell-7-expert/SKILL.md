---
name: powershell-7-expert
description: Use when writing, reviewing, modernizing or debugging PowerShell 7+ code (.ps1, .psm1, .psd1, pwsh scripts, modules and runbooks) - covers modern language features, error handling, function and parameter design, ForEach-Object -Parallel, Invoke-RestMethod integrations, cross-platform paths, Pester testability and PSScriptAnalyzer compliance.
---

# PowerShell 7 Expert

## Non-negotiables

1. Target PowerShell 7.2+. Start every standalone script with `#Requires -Version 7.2`.
2. Put `[CmdletBinding()]` on every function. Add `[OutputType()]` when it returns something.
3. Make every `catch` either handle the error or re-throw. Never leave one empty.
4. Add `-ErrorAction Stop` to any cmdlet call whose failure `try`/`catch` must catch.
5. Never accumulate with `+=` in a loop. Emit to the pipeline, or use `[System.Collections.Generic.List[T]]`.
6. Build paths with `Join-Path`. Never write a literal `\`.
7. Validate parameters with attributes (`ValidateSet`, `ValidateNotNullOrEmpty`, `ValidateRange`), not with `if` checks in the body.
8. Declare `SupportsShouldProcess` on any function or script that creates, deletes, writes or modifies something outside its own process, and honor `$PSCmdlet.ShouldProcess`.
9. Keep secrets in `SecureString` or fetch them at run time. Never log a whole payload object — log named fields.
10. Never use `Invoke-Expression`.
11. Write to the right stream: `Write-Output` for data, `Write-Verbose`/`Write-Warning`/`Write-Error` for everything else. Not `Write-Host`.

Examples in the reference files below are trimmed to the lesson at hand and may omit one or more of these; all eleven still apply to real code.

## Where to look

| If the task involves | Read |
| --- | --- |
| `??`, `?.`, ternary, `&&`/`\|\|`, or porting 5.1 code | `references/modern-syntax.md` |
| try/catch, retries, `$ErrorActionPreference`, error messages | `references/error-handling.md` |
| writing a function, parameters, pipeline input, `-WhatIf` | `references/function-design.md` |
| `ForEach-Object -Parallel`, `Start-ThreadJob`, throttling | `references/parallel-processing.md` |
| `Invoke-RestMethod`, auth, pagination, HTTP retries | `references/rest-api.md` |
| Pester tests, mocking, secrets, input validation | `references/testing-and-security.md` |
| anything in this repository | `references/house-rules.md` |

## Anti-patterns

| Anti-pattern | Why it bites | Do this |
| --- | --- | --- |
| Hard-coded `\` in paths | Breaks on Linux and macOS | `Join-Path` |
| Windows-only cmdlets (`Get-WmiObject`, `Get-EventLog`) | Absent on non-Windows | CIM cmdlets; gate on `$IsWindows` |
| Over-parallelizing | Runspace setup costs more than the work | Tune `-ThrottleLimit`; stay sequential for light work |
| Empty `catch {}` | Failure disappears; the run reports success | Handle it, or `throw` |
| Assuming WinRM | Not cross-platform | SSH remoting |
| `$result += $item` in a loop | Rebuilds the array every iteration; O(n²) | Emit to the pipeline, or `List[T].Add()` |
| `try`/`catch` around a cmdlet without `-ErrorAction Stop` | Non-terminating errors are never caught | Add `-ErrorAction Stop` |
| `Write-Host` for data | Not capturable, not pipeable | `Write-Output`; `Write-Verbose` for commentary |
| `Invoke-Expression` on built strings | Code injection | Call the command directly with a parameter splat |
| Logging a whole response object | Leaks tokens and PII into the job log | Log named fields |
| Parameter checked with `if (-not $x) { throw }` | Fails late, absent from `Get-Help` | `[Parameter(Mandatory)]` + validation attributes |

## Before you call it done

After changing any `.ps1`, `.psm1` or `.psd1` file, run all three commands and show the output. Do not claim the code is finished, correct, or ready to commit without them. This matches what CI (`.github/workflows/ci.yml`) actually runs — a gate weaker than CI can go green here and still fail there. If analysis fails, fix the code — not the analyzer settings.

```bash
pwsh -File build/Invoke-Format.ps1 -Check
```

```bash
pwsh -File build/Invoke-Analysis.ps1 -FailOn Error, Warning
```

```bash
pwsh -File build/Invoke-Tests.ps1
```

In another repository, where `build/` does not exist, these three commands are replaced by that repository's own equivalents — see `references/house-rules.md`. As a generic fallback with no repository-specific settings to load:

```bash
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning"
```

```bash
pwsh -NoProfile -Command "Invoke-Pester"
```

A generic formatting-check fallback is omitted here because it only makes sense against a settings file the target repository owns; use that repository's own format-check command if it has one.
