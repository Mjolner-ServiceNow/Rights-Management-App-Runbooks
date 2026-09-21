# Parallel processing

`ForEach-Object -Parallel` and `Start-ThreadJob` trade one cost (creating runspaces, importing modules into each of them) for another (wall-clock time). The trade only pays off when the per-item work is expensive enough to hide that setup cost. Check that before reaching for either.

## When not to parallelize

Runspace creation and per-runspace module import are not free, and short or I/O-light work does not run long enough to amortize them. Measured in this environment: doubling 100 numbers sequentially took about 2 ms; the same 100 numbers through `-Parallel` took about 420 ms — over 200 times slower, because setting up runspaces dominates work that finishes in microseconds. That ratio shrinks as each item does more real work (a network call, a large file, a slow query), so measure your own workload with `Measure-Command` rather than assuming parallel is faster.

```powershell
# WRONG
1..100 | ForEach-Object -Parallel { $_ * 2 }
```

```powershell
# RIGHT
1..100 | ForEach-Object { $_ * 2 }
```

## ForEach-Object -Parallel and -ThrottleLimit

`-ThrottleLimit` caps how many runspaces run at once; omitted, it defaults to 5 — confirmed by timestamping 20 one-item iterations that each sleep 500 ms: only 5 started within the first 100 ms. For CPU-bound work, set it near `[Environment]::ProcessorCount` so runspaces do not contend for cores. For network-bound work, go well above core count: each runspace spends most of its time waiting on the remote call, not the CPU, so more of them can run at once.

```powershell
# WRONG
$urls | ForEach-Object -Parallel { Invoke-RestMethod -Uri $_ }
```

```powershell
# RIGHT
$urls | ForEach-Object -Parallel { Invoke-RestMethod -Uri $_ } -ThrottleLimit 32
```

## The $using: scope rule

A variable from the caller's scope is invisible inside the parallel script block unless it is prefixed with `$using:`. Without the prefix the name does not error or resolve to the outer value — it silently reads as empty. Confirmed: `$prefix = 'run'` followed by a block that interpolates `$prefix` directly prints `[-1]` and `[-2]`, not `[run-1]` and `[run-2]`.

```powershell
# WRONG
$prefix = 'run'
1..5 | ForEach-Object -Parallel { "$prefix-$_" }
```

```powershell
# RIGHT
$prefix = 'run'
1..5 | ForEach-Object -Parallel { "$using:prefix-$_" }
```

## Thread-safe accumulation

`+=` inside a parallel block does not race on the outer array — it discards every item, every time. `$results` is invisible here too (the same rule as `$using:` above), so it reads as `$null`; `+=` on `$null` creates a brand-new, disconnected array each iteration that vanishes when the iteration ends — nothing was ever linked to the caller's variable. Confirmed: pre-seeding `$results` with three items and reading it inside the block still shows `count=0 isnull=True`, and the outer variable is unchanged afterward. Use `[System.Collections.Concurrent.ConcurrentBag[object]]` and `.Add()` through `$using:` instead; confirmed to keep all 2000 items added concurrently at `-ThrottleLimit 16`, with no loss across repeated runs.

```powershell
# WRONG
$results = @()
1..10 | ForEach-Object -Parallel { $results += $_ }
```

```powershell
# RIGHT
$results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
1..10 | ForEach-Object -Parallel { ($using:results).Add($_) }
```

## Error handling inside the block

Wrap each iteration's work in its own `try`/`catch`. An uncaught terminating error in one iteration writes to the error stream but does not stop the others — confirmed: iteration 3 of 5 throwing still left the other four items collected. Also confirmed: `-ErrorAction` cannot be bound on the `ForEach-Object -Parallel` call itself — PowerShell rejects it with "The following common parameters are not currently supported in the Parallel parameter set: ErrorAction, WarningAction, InformationAction, PipelineVariable." Put `-ErrorAction Stop` on the cmdlet call inside the block instead, where a normal `try`/`catch` can react to it.

```powershell
# WRONG
1..5 | ForEach-Object -Parallel { Get-Content -Path $using:path } -ErrorAction Stop
```

```powershell
# RIGHT
1..5 | ForEach-Object -Parallel {
    try { Get-Content -Path $using:path -ErrorAction Stop }
    catch { Write-Warning "Iteration $_ failed: $($_.Exception.Message)" }
}
```

## Start-ThreadJob for long-running or heterogeneous work

`ForEach-Object -Parallel` suits many short, uniform iterations over a pipeline. `Start-ThreadJob` suits a handful of long-running or differently-shaped tasks, since each job is independently addressable, cancellable, and its output collected on its own schedule. `Start-ThreadJob` ships in the `ThreadJob` module; confirmed present as an inbox module under the `pwsh` installation in this environment, resolving without a separate install and autoloading on first use — but check `Get-Module -ListAvailable ThreadJob` on the target machine before relying on it, since a trimmed install could omit it.

```powershell
# WRONG
Start-ThreadJob -ScriptBlock { Invoke-LongRunningTask }
```

```powershell
# RIGHT
$job = Start-ThreadJob -ScriptBlock { Invoke-LongRunningTask }
$job | Wait-Job | Receive-Job -ErrorAction Stop
```

## Module and function visibility per runspace

A runspace created by `-Parallel` starts clean: it does not inherit the caller's imported modules or defined functions. Confirmed: a function defined in the caller's scope is unrecognized inside the block ("term ... is not recognized"), and a module already `Import-Module`-ed in the parent shows as not loaded inside the block even though the parent session has it. A command still auto-loads inside the block if its module sits on `PSModulePath`, which pays the import cost again in every runspace rather than once. `$using:` cannot work around this for a function — PowerShell rejects a scriptblock-valued `$using:` variable outright ("using variable cannot be a script block ... undefined behavior"). Put shared functions in a module and import it inside the block.

```powershell
# WRONG
function Get-Doubled { param($n) $n * 2 }
1..5 | ForEach-Object -Parallel { Get-Doubled -n $_ }
```

```powershell
# RIGHT
1..5 | ForEach-Object -Parallel {
    Import-Module $using:ModulePath -Force
    Get-Doubled -n $_
}
```
