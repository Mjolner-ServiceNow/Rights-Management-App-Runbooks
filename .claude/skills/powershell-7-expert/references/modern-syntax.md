# Modern syntax

PowerShell 7.2+ adds operators and cmdlet parameters that replace common 5.1 workarounds. Prefer the modern form below over the pattern it replaces.

## Null-coalescing: ?? and ??=

Use `??` to supply a default only when the left side is `$null` (not merely falsy or empty), and `??=` to assign a variable only if it is currently `$null`.

```powershell
# WRONG
$retries = if ($null -eq $Retries) { 3 } else { $Retries }
```

```powershell
# RIGHT
$retries = $Retries ?? 3
$Config.Timeout ??= 30
```

## Null-conditional access: ?. and ?[]

Wrap a bare variable in parentheses before `?.` or `?[]`. Without parentheses, `$var?` parses as a variable literally named `var?` (PowerShell allows `?` in a bare variable name), so the null-conditional check is silently skipped and the member or index access runs unguarded.

```powershell
# WRONG
$name = $customer?.Profile.DisplayName
```

```powershell
# RIGHT
$name = ($customer)?.Profile?.DisplayName
$first = ($items)?[0]
```

## Ternary: ? :

Use `? :` for a single-expression choice instead of an `if`/`else` that only assigns a variable.

```powershell
# WRONG
if ($count -gt 0) { $status = 'active' } else { $status = 'idle' }
```

```powershell
# RIGHT
$status = $count -gt 0 ? 'active' : 'idle'
```

## Pipeline chain operators: && and ||

`&&` and `||` chain on the left side's success (`$?`), not on its boolean value. A `$false` or empty result that produced no error still counts as success, so using them to gate on a flag runs the right side anyway.

```powershell
# WRONG
$hasItems = $false
$hasItems && (Remove-Item -Path $target -Force)
```

```powershell
# RIGHT
if ($hasItems) { Remove-Item -Path $target -Force }
```

## ConvertFrom-Json -AsHashtable

Add `-AsHashtable` when the result needs new keys added or values reassigned. Plain `ConvertFrom-Json` returns a read-only-shaped `PSCustomObject`: setting an existing property works, but setting a property that was not in the source JSON throws.

```powershell
# WRONG
$config = '{"Timeout":10}' | ConvertFrom-Json
$config.Retries = 3
```

```powershell
# RIGHT
$config = '{"Timeout":10}' | ConvertFrom-Json -AsHashtable
$config['Retries'] = 3
```

## Select-Object -SkipLast

Use `-SkipLast` to drop trailing pipeline items instead of computing an index range against a materialized array.

```powershell
# WRONG
$items = 1..5
$allButLast = $items[0..($items.Count - 2)]
```

```powershell
# RIGHT
$allButLast = 1..5 | Select-Object -SkipLast 1
```

## Split-Path -LeafBase

Use `-LeafBase` to get a filename without its extension instead of trimming the extension with a regex.

```powershell
# WRONG
$name = (Split-Path -Path $Path -Leaf) -replace '\.[^.]+$', ''
```

```powershell
# RIGHT
$name = Split-Path -Path $Path -LeafBase
```

## Get-Error

Run `Get-Error` after a failure to see the full detail record (inner exceptions, invocation info, positional message) instead of formatting `$Error[0]` by hand.

```powershell
# WRONG
$Error[0] | Format-List * -Force
```

```powershell
# RIGHT
Get-Error
```

## Test-Json

Validate JSON structurally with `Test-Json` before parsing it, instead of wrapping `ConvertFrom-Json` in `try`/`catch` to detect malformed input.

```powershell
# WRONG
try { $null = $Body | ConvertFrom-Json } catch { throw 'Invalid JSON' }
```

```powershell
# RIGHT
if (-not (Test-Json -Json $Body)) { throw 'Invalid JSON' }
```

## $IsWindows, $IsLinux, $IsMacOS

Branch on these automatic booleans for OS-specific logic instead of parsing `$env:OS` or `$PSVersionTable.OS`.

```powershell
# WRONG
$isWin = $env:OS -eq 'Windows_NT'
```

```powershell
# RIGHT
if ($IsWindows) { Get-CimInstance -ClassName Win32_OperatingSystem }
```

## Join-Path -AdditionalChildPath

Join more than two path segments in one call with `-AdditionalChildPath` instead of nesting `Join-Path` calls.

```powershell
# WRONG
$path = Join-Path -Path (Join-Path -Path $Root -ChildPath 'logs') -ChildPath 'run.log'
```

```powershell
# RIGHT
$path = Join-Path -Path $Root -ChildPath 'logs' -AdditionalChildPath 'run.log'
```

## Porting 5.1 code

| 5.1 pattern | 7.2+ replacement | Why |
| --- | --- | --- |
| `Invoke-WebRequest -UseBasicParsing` | `Invoke-WebRequest` | The switch is accepted for compatibility but does nothing; basic parsing is the only mode. |
| `Get-WmiObject` | `Get-CimInstance` | The WMI cmdlets do not exist in PowerShell 7. Use the CIM cmdlets, gated on `$IsWindows`. |
| `Get-Content -Encoding Byte` | `Get-Content -AsByteStream` | `Byte` is not a valid `-Encoding` value in PowerShell 7; binding it throws. |
| `Write-Host` for data | `Write-Output` | `Write-Host` now writes to the information stream instead of nowhere, but it is still not pipeline data. |
| No `#Requires -Version` | `#Requires -Version 7.2` | Without it, a script written for one version can silently start running on the other and fail mid-execution instead of refusing to load. |
