#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Turns a Windows VM into a host that can run PowerShell 7 runbooks, then hands over to
    Initialize-RmaWorker.ps1. Idempotent.
.DESCRIPTION
    Initialize-RmaWorker.ps1 provisions the module set, but it declares
    `#Requires -Version 7.2` and so cannot run until PowerShell 7 exists. This script
    closes that gap. It runs under the Windows PowerShell 5.1 that ships with the operating
    system, and does three things Initialize-RmaWorker.ps1 cannot do for itself.

    1. Installs PowerShell 7 from the MSI, verified against the release's own hash.

    2. Creates the machine environment variable that tells the Hybrid Worker extension
       where pwsh.exe is. This is not PATH and it is not optional. An extension-based
       Windows worker looks for a variable named after the runbook's runtime version:
       `powershell_7_6_path`, `powershell_7_4_path`, `powershell_7_2_path`. Without it
       every PowerShell 7 job fails to start, on a worker that otherwise reports healthy,
       with nothing in the job output that points at the cause.

       Microsoft documents the 7.4 and 7.2 names. The 7.6 name follows the same pattern and
       is what this script sets, but at the time of writing the Hybrid Worker article has
       not been updated for 7.6. Prove it on a new worker by running a runbook linked to a
       PowerShell 7.6 Runtime environment on the hybrid group: a job that sits in Queued
       means the variable name is wrong.

    3. Bootstraps the NuGet package provider inside PowerShell 7, so the Install-Module
       calls in Initialize-RmaWorker.ps1 do not stop to fetch it. The provider is served
       from a different host to the gallery and is a common firewall omission.

    Then restarts HybridWorkerService, which is when the environment variable takes effect.

    Run once per worker, before Initialize-RmaWorker.ps1, and again after changing
    -PowerShellVersion.
.PARAMETER PowerShellVersion
    The PowerShell 7 version to install. Pinned for the same reason the module versions are
    pinned: the interpreter is part of the runtime contract, so moving it should be a
    reviewed, released change rather than a side effect of provisioning on a later day.

    Keep this on a version Azure Automation offers as a runtime version, and on an LTS line.
    7.6 is the current PowerShell LTS, supported until 14 November 2028. 7.4 leaves support
    on 10 November 2026, and 7.2 is already out of support in PowerShell and retires in
    Azure Automation on 30 September 2026.
.PARAMETER Sha256
    Overrides the expected MSI hash. By default the release's hashes.sha256 asset is
    downloaded and used, which is what you want. Supply this only for a mirror where that
    asset is not available.
.PARAMETER SkipLegacyPaths
    Do not also register the interpreter under the older runtime version names
    (`powershell_7_4_path` and `powershell_7_2_path`).

    Those aliases let runbooks move to 7.6 one at a time: a runbook still linked to a 7.4
    Runtime environment keeps starting on a worker that has only 7.6 installed. Pass this
    switch once every runbook is on 7.6, so that a runbook left behind on an old runtime
    version fails loudly rather than quietly running on an interpreter it did not declare.
.PARAMETER SkipRestart
    Leave HybridWorkerService alone. The environment variables do not take effect until the
    service restarts or the VM reboots.
.EXAMPLE
    ./scripts/Initialize-RmaWorkerHost.ps1 -WhatIf
.EXAMPLE
    # From a workstation, with no inbound access to the VM and no checkout on it. Run
    # Command executes as local SYSTEM, which is the account the jobs themselves use.
    az vm run-command invoke `
        --resource-group rg-rma-prod --name vm-rma-01 `
        --command-id RunPowerShellScript `
        --scripts @scripts/Initialize-RmaWorkerHost.ps1
.NOTES
    Order on a new worker:
      1. scripts/Initialize-RmaWorkerHost.ps1  (this script, Windows PowerShell 5.1)
      2. scripts/Initialize-RmaWorker.ps1      (pwsh 7)
      3. the Test-RmaHealth runbook, run on the worker
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^7\.\d+\.\d+$')]
    [string] $PowerShellVersion = '7.6.5',

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $Sha256,

    [switch] $SkipLegacyPaths,

    [switch] $SkipRestart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$target       = [version] $PowerShellVersion
$pwshPath     = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$pathVariable = 'powershell_7_{0}_path' -f $target.Minor
$msiName      = "PowerShell-$PowerShellVersion-win-x64.msi"
$releaseUri   = "https://github.com/PowerShell/PowerShell/releases/download/v$PowerShellVersion"
$serviceName  = 'HybridWorkerService'

# Asking the interpreter is more reliable than reading a product code or a file version.
# Returns $null when PowerShell 7 is absent or will not run.
function Get-InstalledPwshVersion {
    [OutputType([version])]
    param()

    if (-not (Test-Path -LiteralPath $script:pwshPath)) { return $null }

    $reported = & $script:pwshPath -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.ToString()'
    if ($LASTEXITCODE -ne 0 -or -not $reported) { return $null }
    return [version] $reported.Trim()
}

# Reads the expected MSI hash from the release's own hashes.sha256 asset. Using that rather
# than a hash pinned in this file keeps a version bump to one line. It proves the download
# arrived intact and unaltered in transit; it is not a defence against a compromised
# release, which is what the MSI's Authenticode signature is for.
function Get-ReleaseHash {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $Staging
    )

    $hashFile = Join-Path $Staging 'hashes.sha256'
    Invoke-WebRequest -Uri "$script:releaseUri/hashes.sha256" -OutFile $hashFile -UseBasicParsing

    # The asset is UTF-16LE with a byte order mark. Sniff it rather than assume, so that a
    # future change of encoding fails clearly instead of producing mojibake and no match.
    $bytes = [IO.File]::ReadAllBytes($hashFile)
    $text = if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    } else {
        [Text.Encoding]::UTF8.GetString($bytes)
    }

    # Lines are '<64 hex> *<file name>'. Concatenated rather than built with -f, because
    # the format operator reads the regex quantifier {64} as a placeholder and throws.
    $pattern = '^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($script:msiName) + '\s*$'
    foreach ($line in $text -split '\r?\n') {
        if ($line -match $pattern) { return $Matches[1].ToLowerInvariant() }
    }

    throw ("hashes.sha256 for v$script:PowerShellVersion does not list $script:msiName. " +
        'Pass -Sha256 with the expected hash, or check that the version exists.')
}

Write-Host '=== Host ==='
Write-Host ('  {0,-22}{1}' -f 'identity', [Security.Principal.WindowsIdentity]::GetCurrent().Name)

# Read the caption from the registry rather than Win32_OperatingSystem. Importing CimCmdlets
# under -WhatIf echoes a What-if line for every alias that module defines, which buries the
# output an operator ran -WhatIf to read in the first place.
$productName = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductName').ProductName
Write-Host ('  {0,-22}{1}' -f 'operating system', $productName)
Write-Host ('  {0,-22}{1}' -f 'windows powershell', $PSVersionTable.PSVersion)

# The extension is what reads the environment variable set below. Microsoft documents 1.3.63
# as the floor for PowerShell 7.4 runbooks and publishes no floor for 7.6, so 1.3.63 is
# treated as the minimum for both.
$extension = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Azure\HybridWorker' -ErrorAction SilentlyContinue |
ForEach-Object { $_.PSChildName -as [version] } |
Where-Object { $_ } |
Sort-Object -Descending |
Select-Object -First 1

if (-not $extension) {
    Write-Warning ('Hybrid Worker extension not found. Register this VM in the Hybrid Worker Group ' +
        'first: the extension is what reads the environment variables this script sets.')
} elseif ($extension -lt [version] '1.3.63') {
    Write-Warning ("Hybrid Worker extension is $extension. PowerShell 7.x runbooks need 1.3.63 or " +
        'above. Upgrade the extension, or the jobs will not start whatever this script does.')
} else {
    Write-Host ('  {0,-22}{1}' -f 'worker extension', $extension)
}

Write-Host ''
Write-Host '=== PowerShell 7 ==='

$installed = Get-InstalledPwshVersion
if ($installed) { Write-Host ('  {0,-22}{1}' -f 'present', $installed) }

if ($installed -eq $target) {
    Write-Host '  requested version already installed'
} elseif ($PSCmdlet.ShouldProcess("PowerShell $PowerShellVersion", 'Download, verify and install the MSI')) {

    # Windows PowerShell 5.1 still negotiates TLS 1.0 by default on some images, and GitHub
    # refuses it. Process-scoped: nothing here changes the machine's SCHANNEL policy.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $staging = Join-Path ([IO.Path]::GetTempPath()) "rma-pwsh-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $staging -Force

    try {
        $msiPath = Join-Path $staging $msiName

        Write-Host "  downloading $msiName"
        Invoke-WebRequest -Uri "$releaseUri/$msiName" -OutFile $msiPath -UseBasicParsing

        $expected = if ($Sha256) { $Sha256.ToLowerInvariant() } else { Get-ReleaseHash -Staging $staging }
        $actual = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($actual -ne $expected) {
            throw ("$msiName failed hash verification. Expected $expected, got $actual. " +
                'The download was truncated or altered. Nothing was installed.')
        }
        Write-Host '  hash verified'

        # USE_MU and ENABLE_MU are off deliberately. Microsoft Update servicing would move
        # the interpreter under a running worker with no release, which is exactly what
        # pinning the module versions exists to prevent.
        $arguments = @(
            '/i', ('"{0}"' -f $msiPath)
            '/qn'
            '/norestart'
            'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0'
            'ENABLE_PSREMOTING=0'
            'REGISTER_MANIFEST=1'
            'USE_MU=0'
            'ENABLE_MU=0'
        )

        Write-Host '  running msiexec'
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru

        # 3010 is success with a reboot pending, which the restart at the end covers.
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "msiexec exited with $($process.ExitCode) installing $msiName."
        }

        $installed = Get-InstalledPwshVersion
        if ($installed -ne $target) {
            throw "Expected PowerShell $target at '$pwshPath' after installation, found '$installed'."
        }
        Write-Host ('  {0,-22}{1}  INSTALLED' -f 'installed', $installed)
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '=== Runtime discovery ==='

$variables = [ordered] @{ $pathVariable = $pwshPath }
if (-not $SkipLegacyPaths) {
    # Aliases for the older runtime versions Azure Automation still offers, so a runbook not
    # yet moved to a 7.6 Runtime environment still finds an interpreter on this worker.
    foreach ($legacy in 'powershell_7_4_path', 'powershell_7_2_path') {
        if ($legacy -ne $pathVariable) { $variables[$legacy] = $pwshPath }
    }
}

foreach ($name in $variables.Keys) {
    $wanted  = $variables[$name]
    $current = [Environment]::GetEnvironmentVariable($name, 'Machine')

    if ($current -eq $wanted) {
        Write-Host ('  {0,-22}{1}  already set' -f $name, $current)
    } elseif ($PSCmdlet.ShouldProcess($name, "Set machine environment variable to $wanted")) {
        [Environment]::SetEnvironmentVariable($name, $wanted, 'Machine')
        Write-Host ('  {0,-22}{1}  SET' -f $name, $wanted)
    }
}

Write-Host ''
Write-Host '=== Package provider (PowerShell 7) ==='

if (-not (Test-Path -LiteralPath $pwshPath)) {
    Write-Warning 'PowerShell 7 is not present, so the package provider was not bootstrapped.'
} elseif ($PSCmdlet.ShouldProcess('NuGet package provider', 'Bootstrap for AllUsers inside PowerShell 7')) {

    # Install-Module in Initialize-RmaWorker.ps1 otherwise fetches this on first use, from a
    # different host to the gallery. That host is often missing from firewall allow-lists
    # that already permit the gallery, and the resulting error names the module rather than
    # the provider, which sends you looking in the wrong place.
    & $pwshPath -NoProfile -NoLogo -Command @'
$ErrorActionPreference = 'Stop'
if (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue) {
    Write-Host '  NuGet provider already present'
} else {
    $null = Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Scope AllUsers -Force
    Write-Host '  NuGet provider installed'
}
'@

    if ($LASTEXITCODE -ne 0) {
        throw "Bootstrapping the NuGet package provider in PowerShell 7 failed with exit code $LASTEXITCODE."
    }
}

Write-Host ''
Write-Host '=== Hybrid worker service ==='

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Warning ("$serviceName not found, so nothing was restarted. The environment variables " +
        'take effect once the extension is installed and the VM restarts.')
} elseif ($SkipRestart) {
    Write-Host '  -SkipRestart given. Restart the service or reboot the VM before the variables take effect.'
} elseif ($PSCmdlet.ShouldProcess($serviceName, 'Restart so the new environment variables are read')) {
    Restart-Service -Name $serviceName -Force
    Write-Host ('  {0,-22}{1}' -f $serviceName, (Get-Service -Name $serviceName).Status)
}

Write-Host ''
Write-Host 'Host provisioning complete.'
Write-Host 'Next: scripts/Initialize-RmaWorker.ps1 from an elevated pwsh, then the Test-RmaHealth runbook.'
