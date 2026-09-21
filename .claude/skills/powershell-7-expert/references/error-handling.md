# Error handling

PowerShell has two error kinds, and `try`/`catch` only reacts to one of them by default. Get that distinction right first; everything else in this file builds on it.

## Terminating vs. non-terminating errors

A cmdlet's own internal failures (file not found, access denied) are non-terminating by default: the error is written to the error stream and the cmdlet's script keeps running. `try`/`catch` only intercepts terminating errors, so a bare `try` around a non-terminating call does not catch it — the `catch` block never runs, and execution falls through to the line after the call, inside the `try`.

```powershell
# WRONG
try {
    Get-Content -Path $LogPath
} catch {
    Write-Warning "Could not read log: $($_.Exception.Message)"
}
```

```powershell
# RIGHT
try {
    Get-Content -Path $LogPath -ErrorAction Stop
} catch {
    Write-Warning "Could not read log: $($_.Exception.Message)"
}
```

## -ErrorAction Stop vs. $ErrorActionPreference

`-ErrorAction Stop` on a single call is easy to forget on every new line added later. Setting `$ErrorActionPreference = 'Stop'` at script scope makes every cmdlet call in the script terminating by default, so a bare `try`/`catch` catches all of them without per-call flags.

```powershell
# WRONG
try {
    Get-Item -Path $Source -ErrorAction Stop
    Copy-Item -Path $Source -Destination $Target
} catch {
    throw
}
```

```powershell
# RIGHT
$ErrorActionPreference = 'Stop'
try {
    Get-Item -Path $Source
    Copy-Item -Path $Source -Destination $Target
} catch {
    throw
}
```

## try/catch/finally cleanup

Use `finally` for cleanup that must run whether the `try` succeeded or threw — closing a connection, removing a temp file. Do not duplicate the cleanup call in both the success path and the `catch`.

```powershell
# WRONG
$connection = Open-DbConnection
try {
    Invoke-DbQuery -Connection $connection
    $connection.Close()
} catch {
    $connection.Close()
    throw
}
```

```powershell
# RIGHT
$connection = Open-DbConnection
try {
    Invoke-DbQuery -Connection $connection
} finally {
    $connection.Close()
}
```

## Catch a specific exception type before the general one

List a typed `catch` ahead of the general `catch` so a known failure gets its own handling while everything else still falls through. This is not just a style preference — the parser rejects a general `catch` placed before a typed one (`Catch block must be the last catch block.`), so a typed handler always has to be written first. Confirmed against a real `System.IO.FileNotFoundException`: the typed block matches and the general block does not run.

```powershell
# WRONG
try {
    [System.IO.File]::ReadAllText($Path)
} catch {
    throw "Could not read $Path : $($_.Exception.Message)"
}
```

```powershell
# RIGHT
try {
    [System.IO.File]::ReadAllText($Path)
} catch [System.IO.FileNotFoundException] {
    throw "File $Path does not exist. Check the path and retry."
} catch {
    throw "Could not read $Path : $($_.Exception.Message)"
}
```

## throw vs. Write-Error

`throw` raises a terminating error: the current scope stops immediately. `Write-Error` writes a non-terminating error and execution continues on the next line, so calling it and expecting the function to stop is wrong.

```powershell
# WRONG
function Get-Config {
    param([string] $Path)
    if (-not (Test-Path -Path $Path)) {
        Write-Error "Config file not found: $Path"
    }
    Get-Content -Path $Path -Raw | ConvertFrom-Json
}
```

```powershell
# RIGHT
function Get-Config {
    param([string] $Path)
    if (-not (Test-Path -Path $Path)) {
        throw "Config file not found: $Path"
    }
    Get-Content -Path $Path -Raw | ConvertFrom-Json
}
```

## $PSCmdlet.ThrowTerminatingError() in a function

Inside an advanced function, prefer `$PSCmdlet.ThrowTerminatingError()` over a bare `throw` when rethrowing a caught error. `throw` wraps the message in a new exception and adds this function's line to the stack trace; `ThrowTerminatingError()` passes the original `ErrorRecord` through unchanged, so the caller sees the real exception type and origin.

```powershell
# WRONG
function Get-RemoteFile {
    [CmdletBinding()]
    param([string] $Uri)
    try {
        Invoke-RestMethod -Uri $Uri -ErrorAction Stop
    } catch {
        throw $_
    }
}
```

```powershell
# RIGHT
function Get-RemoteFile {
    [CmdletBinding()]
    param([string] $Uri)
    try {
        Invoke-RestMethod -Uri $Uri -ErrorAction Stop
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
```

## What goes in an error message

State what failed, which input caused it, and what to do next. A message with none of those sends whoever reads the log back to the source code to find out what happened.

```powershell
# WRONG
throw 'Operation failed'
```

```powershell
# RIGHT
throw "Failed to upload '$FileName' to '$Container': blob already exists. Pass -Force to overwrite."
```

## $_.Exception.Message vs. dumping $_

`$_.Exception.Message` gives the plain message text. Writing `$_` on its own runs it through PowerShell's default error formatter, which adds the exception type name, the script path, line and column, and a caret pointer at the failing expression — useful at an interactive prompt, noisy in a log line or a message shown to a user.

```powershell
# WRONG
catch {
    Write-Warning "Upload failed: $_"
}
```

```powershell
# RIGHT
catch {
    Write-Warning "Upload failed: $($_.Exception.Message)"
}
```

## Empty catch blocks

A `catch {}` with nothing in it swallows the failure: the run reports success while the actual error is discarded. Handle the error or re-throw it; never leave the block empty. This repository enforces the rule in PSScriptAnalyzer — see `references/house-rules.md`.

```powershell
# WRONG
try {
    Remove-Item -Path $TempFile -ErrorAction Stop
} catch {}
```

```powershell
# RIGHT
try {
    Remove-Item -Path $TempFile -ErrorAction Stop
} catch {
    Write-Warning "Could not remove temp file '$TempFile': $($_.Exception.Message)"
}
```

## Retry with exponential backoff

Wrap a flaky call in a retry helper instead of hand-rolling a loop at every call site. `Invoke-WithRetry` below rethrows the original exception once `MaxAttempts` is exhausted, and doubles the delay after each failed attempt.

```powershell
# RIGHT
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $ScriptBlock,
        [ValidateRange(1, 10)][int] $MaxAttempts = 3,
        [ValidateRange(1, 60)][int] $DelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return & $ScriptBlock }
        catch {
            if ($attempt -eq $MaxAttempts) { throw }
            Write-Verbose "Attempt $attempt failed: $($_.Exception.Message). Retrying."
            Start-Sleep -Seconds ($DelaySeconds * [math]::Pow(2, $attempt - 1))
        }
    }
}
```
