# Function design

A script with no `[CmdletBinding()]`, no pipeline support, no parameter validation and no help still runs — until it is reused, chained into a pipeline, or someone other than its author has to call it. Advanced-function features exist to make that reuse safe.

## [CmdletBinding()] and what it buys

Adding `[CmdletBinding()]` turns a plain function into an advanced function: PowerShell adds the common parameters (`-Verbose`, `-ErrorAction`, `-WarningAction`, `-Debug`) automatically, and it populates `$PSCmdlet` inside the body. Neither exists on a function without it.

```powershell
# WRONG
function Get-ActiveUser {
    param([string] $Domain)
    Get-ADUser -Filter { Enabled -eq $true } -Server $Domain
}
```

```powershell
# RIGHT
function Get-ActiveUser {
    [CmdletBinding()]
    param([string] $Domain)
    Get-ADUser -Filter { Enabled -eq $true } -Server $Domain
}
```

## [OutputType()]

Declare `[OutputType()]` so `Get-Help` and tab completion can report what the function returns without running it.

```powershell
# WRONG
function Get-ServerStatus {
    [CmdletBinding()]
    param([string] $ComputerName)
    [PSCustomObject]@{ Name = $ComputerName; Online = $true }
}
```

```powershell
# RIGHT
function Get-ServerStatus {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param([string] $ComputerName)
    [PSCustomObject]@{ Name = $ComputerName; Online = $true }
}
```

## Validation attributes over body checks

Put range, set and null checks on the parameter with attributes instead of an `if` at the top of the body. The check then runs during binding, before any of the function's code executes, and shows up in `Get-Help -Full`.

```powershell
# WRONG
function Set-Timeout {
    param([int] $Seconds)
    if ($Seconds -lt 1 -or $Seconds -gt 300) { throw 'Seconds must be 1-300' }
    $Seconds
}
```

```powershell
# RIGHT
function Set-Timeout {
    param([ValidateRange(1, 300)][int] $Seconds)
    $Seconds
}
```

## [Parameter(Mandatory)] versus defaulting

Require a parameter with `[Parameter(Mandatory)]` when there is no reasonable default; give the rest a default value instead of throwing when the caller omits them. A hand-written `if (-not $x) { throw }` fails after binding has already happened, and it never shows up as required in `Get-Help`.

```powershell
# WRONG
function New-Report {
    param([string] $OutputPath)
    if (-not $OutputPath) { throw 'OutputPath is required' }
    "Report written to $OutputPath"
}
```

```powershell
# RIGHT
function New-Report {
    param([Parameter(Mandatory)][string] $OutputPath, [string] $Format = 'json')
    "Report written to $OutputPath as $Format"
}
```

## Pipeline input: begin, process, end

Bind pipeline input with `ValueFromPipeline` to take the whole incoming object, or `ValueFromPipelineByPropertyName` to bind a parameter from a same-named property of the incoming object — confirmed below. Do the per-item work in `process`, which PowerShell calls once for every pipeline item; `begin` and `end` each run exactly once for the whole invocation, so a parameter variable read in `end` holds only whatever the last item bound to it. Verified: piping three items through a function that reads the parameter only in `end` prints just the third one.

```powershell
# WRONG
function Disable-StaleAccount {
    [CmdletBinding()]
    param([Parameter(ValueFromPipelineByPropertyName)][string] $Identity)
    end { Disable-LocalUser -Name $Identity }
}
```

```powershell
# RIGHT
function Disable-StaleAccount {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string] $Identity)
    begin { $count = 0 }
    process { Disable-LocalUser -Name $Identity; $count++ }
    end { Write-Verbose "Disabled $count account(s)." }
}
```

Piped through `[PSCustomObject]@{ Identity = 'alice' }, [PSCustomObject]@{ Identity = 'bob' }`, `ValueFromPipelineByPropertyName` binds `$Identity` from each object's `Identity` property in turn — confirmed against pwsh 7.5.4.

## SupportsShouldProcess and the guard idiom

Declare `SupportsShouldProcess` on any function that changes state, and set `ConfirmImpact = 'High'` when the change is destructive or hard to undo. This alone wires up `-WhatIf` and `-Confirm`: no `-WhatIf` parameter is ever declared by hand. Guard the change itself with `$PSCmdlet.ShouldProcess(...)` and return early when it comes back `$false`.

```powershell
# WRONG
function Disable-Account {
    param([string] $Identity)
    Disable-LocalUser -Name $Identity
}
```

```powershell
# RIGHT
function Disable-Account {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')] param([string] $Identity)
    if (-not $PSCmdlet.ShouldProcess($Identity, 'Disable account')) { return }
    Disable-LocalUser -Name $Identity
}
```

Confirmed against pwsh 7.5.4: calling `Disable-Account -Identity bob -WhatIf` prints `What if: Performing the operation "Disable account" on target "bob".` and never calls `Disable-LocalUser` — with no `-WhatIf` parameter declared anywhere in the function. Because `ConfirmImpact = 'High'` matches the default `$ConfirmPreference` of `High`, calling the function for real (no `-WhatIf`) also prompts for confirmation; pass `-Confirm:$false` to run it unattended, which was confirmed to execute the real action cleanly. Note the difference in scope: `return` inside the guard exits only this function, which is what makes the idiom safe. A bare `return` at *script* scope exits the whole script instead of the block it appears in — this repository enforces that distinction in PSScriptAnalyzer; see `references/house-rules.md`.

## Comment-based help

Put `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` and `.EXAMPLE` in a comment block immediately above the `function` keyword, not buried after other statements. `Get-Help` only finds help placed there or as the first thing inside the function body.

```powershell
# WRONG
function Get-InactiveUser {
    [CmdletBinding()]
    param([int] $DaysAgo = 90)
    Get-LocalUser | Where-Object { $_.LastLogon -lt (Get-Date).AddDays(-$DaysAgo) }
}
```

```powershell
# RIGHT
<#
.SYNOPSIS
    Lists user accounts inactive for a number of days.
.DESCRIPTION
    Filters the accounts returned by Get-LocalUser by last-logon age.
.PARAMETER DaysAgo
    Minimum days since last logon. Defaults to 90.
.EXAMPLE
    Get-InactiveUser -DaysAgo 30
#>
function Get-InactiveUser {
    [CmdletBinding()] param([int] $DaysAgo = 90)
    Get-LocalUser | Where-Object { $_.LastLogon -lt (Get-Date).AddDays(-$DaysAgo) }
}
```

## Approved verbs and Verb-Noun naming

Name every function `Verb-Noun` with a verb from `Get-Verb`. An unapproved verb triggers PowerShell's own module-import warning and breaks the predictability `Get-Verb` exists to guarantee — `Get-Content` and `Get-Process` behave the same shape of way because both start with `Get`.

```powershell
# WRONG
function Create-User {
    [CmdletBinding()]
    param([string] $Name)
    Write-Output "Creating $Name"
}
```

```powershell
# RIGHT
function New-User {
    [CmdletBinding()]
    param([string] $Name)
    Write-Output "Creating $Name"
}
```

Confirmed against `Get-Verb` in pwsh 7.5.4: `Create` is absent; `New` is the approved verb for that action, alongside `Get`, `Set`, `Disable` and `Test`, all of which appear elsewhere in this file.

## One function, one job

A function that validates input, performs the change and formats output for a report is three responsibilities wearing one name — none of them independently testable. Split the validation out.

```powershell
# WRONG
function Update-UserEmail {
    param([string] $SamAccountName, [string] $Email)
    if ($Email -notmatch '^[^@]+@[^@]+$') { throw 'Invalid email' }
    Set-ADUser -Identity $SamAccountName -EmailAddress $Email
}
```

```powershell
# RIGHT
function Test-ValidEmail {
    [CmdletBinding()]
    param([string] $Email)
    $Email -match '^[^@]+@[^@]+$'
}
```

`Update-UserEmail` then becomes `if (-not (Test-ValidEmail -Email $Email)) { throw 'Invalid email' }` followed by the `Set-ADUser` call — the format check and the state change are two functions, each callable and testable on its own.

## Public/Private module layout and FunctionsToExport

Split a module's functions into a `Public/` folder (the supported surface) and a `Private/` folder (helpers). Dot-source both at import time, but export only the public names — never `FunctionsToExport = '*'`, which exports private helpers too and leaves the module's real surface undocumented.

```powershell
# WRONG
# In MyModule.psd1
FunctionsToExport = '*'
```

```powershell
# RIGHT
$public = Get-ChildItem -Path "$PSScriptRoot/Public" -Filter '*.ps1'
foreach ($file in $public) { . $file.FullName }
Export-ModuleMember -Function $public.BaseName
```

The manifest's `FunctionsToExport` should list those same public names explicitly (generated at build time from the `Public/` folder, or maintained by hand) so tooling can see the module's surface from the manifest alone, without importing it.
