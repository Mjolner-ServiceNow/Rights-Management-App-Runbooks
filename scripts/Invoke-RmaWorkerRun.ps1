#Requires -Version 7.2

<#
.SYNOPSIS
    Runs a runbook from the local working tree on a test Hybrid Worker, without a push.
.DESCRIPTION
    Copies src/RMA.Runbooks, as the version in its manifest, and src/runbooks to a scratch
    folder on the worker. Puts that module folder first on PSModulePath for this one session,
    so each runbook's #Requires resolves to the copy. Then runs the named runbook there. The
    module installed on the worker is left alone, so a job that runs meanwhile still gets
    the released version.

    The runbook's parameters come from the config file. Keys the runbook does not declare,
    and empty values, are ignored. -Parameters is merged on top and wins. One config file
    therefore serves every runbook.

    Connects over PowerShell SSH remoting, through an Azure Bastion tunnel on
    localhost:<Worker.Port>, with a key dedicated to this. If nothing is listening on that
    port, it starts the tunnel. The tunnel is left running for the next call, and
    -StopTunnel closes it. docs/CONTRIBUTING.md describes the one-time setup on the worker.

    This is for a test environment. The key grants administrator access to the worker.
    The code runs as that SSH user, not as SYSTEM like a real Hybrid Worker job, so a final
    check still belongs in a real job.
.PARAMETER Runbook
    Name of a runbook in src/runbooks, with or without .ps1.
.PARAMETER Parameters
    Runbook parameters that override or add to those in the config file.
.PARAMETER ScriptBlock
    Code to run on the worker instead of a runbook, with the working tree's RMA.Runbooks
    imported. For exercising one function without a runbook around it.
.PARAMETER StopTunnel
    Close the tunnel this script opened, and do nothing else.
.PARAMETER ConfigPath
    JSON config. Its Worker object says how to reach the worker. Every other top-level key
    is a runbook parameter. Defaults to rma-worker.local.json at the repository root, which
    is gitignored. rma-worker.example.json shows the shape.
.PARAMETER RemoteRoot
    Scratch folder on the worker. Deleted and recreated on every run.
.EXAMPLE
    ./scripts/Invoke-RmaWorkerRun.ps1 Test-RmaHealth
.EXAMPLE
    ./scripts/Invoke-RmaWorkerRun.ps1 Test-RmaHealth -Parameters @{ AdSecretName = 'other-secret' }
.EXAMPLE
    ./scripts/Invoke-RmaWorkerRun.ps1 -ScriptBlock { Get-Module RMA.Runbooks | Select-Object Version, ModuleBase }
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Runbook')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Runbook', Position = 0)][ValidateNotNullOrEmpty()]
    [string] $Runbook,

    [Parameter(ParameterSetName = 'Runbook')]
    [hashtable] $Parameters = @{},

    [Parameter(Mandatory, ParameterSetName = 'ScriptBlock')]
    [scriptblock] $ScriptBlock,

    [Parameter(Mandatory, ParameterSetName = 'StopTunnel')]
    [switch] $StopTunnel,

    [ValidateNotNullOrEmpty()]
    [string] $ConfigPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'rma-worker.local.json'),

    [ValidatePattern('^[A-Za-z]:/')]
    [string] $RemoteRoot = 'C:/RmaDev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSStyle.OutputRendering = 'PlainText'

# The host colours an uncaught error on stderr whatever OutputRendering says, which buries
# the message when the output is read from a log or a transcript. Report it plainly here;
# the exit code stays 1.
trap {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent

function Get-WorkerConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -Path $Path)) {
        throw "Config not found: $Path. Copy rma-worker.example.json to rma-worker.local.json and fill it in."
    }
    $config = Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $config.ContainsKey('Worker')) { throw "$Path has no Worker object." }
    $worker = $config['Worker']
    $required = 'ResourceGroup', 'BastionName', 'VmName', 'UserName', 'KeyFilePath', 'KnownHostsFile', 'Port'
    $missing = @($required | Where-Object { -not $worker.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$worker[$_]) })
    if ($missing) { throw "Worker in $Path is missing: $($missing -join ', ')" }
    $config
}

function Get-TunnelProcessId {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int] $Port)

    # The az command hands the tunnel to a child process and that child is what listens,
    # so the tunnel is found by its port rather than by the process that started it.
    if ($IsWindows) {
        @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).OwningProcess
    } else {
        @(& lsof -nP -t "-iTCP:$Port" -sTCP:LISTEN 2>$null) | Where-Object { $_ } | ForEach-Object { [int]$_ }
    }
}

function Start-WorkerTunnel {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][hashtable] $Worker)

    if (Get-TunnelProcessId -Port $Worker.Port) { return }

    Write-Host "Starting Bastion tunnel on localhost:$($Worker.Port) ..."
    $vmId = & az vm show -g $Worker.ResourceGroup -n $Worker.VmName --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $vmId) {
        throw "Could not resolve VM '$($Worker.VmName)' with az. Is az signed in to the right subscription?"
    }
    $log = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "rma-tunnel-$($Worker.Port).log"
    $tunnelArguments = @(
        'network', 'bastion', 'tunnel', '-g', $Worker.ResourceGroup, '-n', $Worker.BastionName,
        '--target-resource-id', $vmId, '--resource-port', '22', '--port', "$($Worker.Port)"
    )
    $null = Start-Process -FilePath (Get-Command -Name az).Source -ArgumentList $tunnelArguments `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"

    $deadline = [datetime]::UtcNow.AddSeconds(45)
    while (-not (Get-TunnelProcessId -Port $Worker.Port)) {
        if ([datetime]::UtcNow -gt $deadline) { throw "The tunnel did not open on $($Worker.Port) within 45 s. See $log.err." }
        Start-Sleep -Milliseconds 500
    }
}

function Stop-WorkerTunnel {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([Parameter(Mandatory)][int] $Port)

    $ids = @(Get-TunnelProcessId -Port $Port)
    if (-not $ids) {
        Write-Host "No tunnel is listening on $Port."
        return
    }
    if ($PSCmdlet.ShouldProcess("process $($ids -join ', ') on port $Port", 'Stop tunnel')) {
        $ids | ForEach-Object { Stop-Process -Id $_ }
        Write-Host "Stopped the tunnel on $Port."
    }
}

function Get-RunbookParameter {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable] $Override
    )

    # Parsed rather than read with Get-Command, which would evaluate the runbook's
    # #Requires here, where the version it pins may not be installed.
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $declared = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

    $result = @{}
    foreach ($key in $Config.Keys) {
        if ($key -in $declared -and -not [string]::IsNullOrWhiteSpace([string]$Config[$key])) {
            $result[$key] = $Config[$key]
        }
    }
    foreach ($key in $Override.Keys) { $result[$key] = $Override[$key] }

    $unknown = @($result.Keys | Where-Object { $_ -notin $declared })
    if ($unknown) { throw "$(Split-Path -Path $Path -Leaf) does not declare: $($unknown -join ', ')" }
    $result
}

function Invoke-WorkerRun {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [string] $Runbook,
        [hashtable] $Parameters = @{},
        [scriptblock] $ScriptBlock,
        [switch] $StopTunnel,
        [Parameter(Mandatory)][string] $ConfigPath,
        [Parameter(Mandatory)][string] $RemoteRoot
    )

    $config = Get-WorkerConfig -Path $ConfigPath
    $worker = $config['Worker']

    if ($StopTunnel) {
        Stop-WorkerTunnel -Port $worker.Port
        return
    }

    $runbookName = $null
    $runParameters = @{}
    if (-not $ScriptBlock) {
        $runbookName = [IO.Path]::GetFileNameWithoutExtension($Runbook) + '.ps1'
        $localRunbook = Join-Path -Path $repoRoot -ChildPath "src/runbooks/$runbookName"
        if (-not (Test-Path -Path $localRunbook)) { throw "Runbook not found: $localRunbook" }
        $runParameters = Get-RunbookParameter -Path $localRunbook -Config $config -Override $Parameters
    }
    $moduleVersion = (Import-PowerShellDataFile -Path (Join-Path -Path $repoRoot -ChildPath 'src/RMA.Runbooks/RMA.Runbooks.psd1')).ModuleVersion
    $what = if ($runbookName) { "run $runbookName" } else { 'run a script block' }

    if (-not $PSCmdlet.ShouldProcess("$($worker.VmName):$RemoteRoot", "Replace with RMA.Runbooks $moduleVersion and the runbooks from the working tree, then $what")) {
        return
    }

    Start-WorkerTunnel -Worker $worker

    $sessionParameters = @{
        HostName    = 'localhost'
        Port        = $worker.Port
        UserName    = $worker.UserName
        KeyFilePath = $worker.KeyFilePath
        Options     = @{
            UserKnownHostsFile    = (Resolve-Path -Path $worker.KnownHostsFile).Path
            StrictHostKeyChecking = 'yes'
            IdentitiesOnly        = 'yes'
        }
    }
    $session = New-PSSession @sessionParameters
    try {
        Invoke-Command -Session $session -ScriptBlock {
            $root = $using:RemoteRoot
            if (Test-Path -Path $root) { Remove-Item -Path $root -Recurse -Force }
            $null = New-Item -ItemType Directory -Force -Path @(
                (Join-Path -Path $root -ChildPath "Modules/RMA.Runbooks/$using:moduleVersion"),
                (Join-Path -Path $root -ChildPath 'runbooks'))
        }
        Copy-Item -ToSession $session -Recurse -Path (Join-Path -Path $repoRoot -ChildPath 'src/RMA.Runbooks/*') `
            -Destination "$RemoteRoot/Modules/RMA.Runbooks/$moduleVersion"
        Copy-Item -ToSession $session -Path (Join-Path -Path $repoRoot -ChildPath 'src/runbooks/*.ps1') `
            -Destination "$RemoteRoot/runbooks"

        $shown = if ($runbookName) { " [$(($runParameters.Keys | Sort-Object) -join ', ')]" } else { '' }
        Write-Host "Running $(if ($runbookName) { $runbookName } else { 'script block' }) with RMA.Runbooks $moduleVersion on $($worker.VmName) as $($worker.UserName)$shown"
        Write-Host ('-' * 78)

        # A scriptblock crosses the session as text and is rebuilt on the far side.
        $code = "$ScriptBlock"
        Invoke-Command -Session $session -ScriptBlock {
            $root = $using:RemoteRoot
            $env:PSModulePath = (Join-Path -Path $root -ChildPath 'Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
            if ($using:runbookName) {
                $runbookParameters = $using:runParameters
                & (Join-Path -Path $root -ChildPath "runbooks/$using:runbookName") @runbookParameters
            } else {
                Import-Module -Name RMA.Runbooks -RequiredVersion $using:moduleVersion -Force
                & ([scriptblock]::Create($using:code))
            }
        }
    } finally {
        Remove-PSSession -Session $session
    }
}

# Defaults are not in $PSBoundParameters, so the two with defaults are added explicitly.
$invokeParameters = @{} + $PSBoundParameters
$invokeParameters['ConfigPath'] = $ConfigPath
$invokeParameters['RemoteRoot'] = $RemoteRoot
Invoke-WorkerRun @invokeParameters
