<#
.SYNOPSIS
    Installs the hardened Podman WSL golden image for the current user.

.DESCRIPTION
    SCCM wrapper. Runs, in order:
      1. podman machine init --image <golden tar.zst> <name>
      2. harden.sh inside the distro as root
         (wsl -d <distro> -u root --exec /usr/local/libexec/golden-image/harden.sh ...)
      3. podman machine stop / start so the new wsl.conf and fstab take effect
      4. harden.sh --verify, and stores a reference copy of the manifest outside
         the distro (%LOCALAPPDATA%\GoldenImage\<distro>\manifest.sha256) for
         compliance/Test-WslCompliance.ps1.

    Podman machines and WSL distros are PER USER. Deploy this script in the
    logged-on user's context (SCCM: "Run with user's rights" / user-targeted
    deployment), never as SYSTEM.

    Compatible with Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER ImagePath
    Path (or http(s):// or docker:// reference) of podman-wsl-golden-<ver>.tar.zst.

.PARAMETER ExpectedSha256
    Optional SHA-256 of the image file. Checked before init when ImagePath is a local file.

.PARAMETER Force
    Remove an existing machine with the same name first (destroys its containers and images).

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File Invoke-Harden.ps1 -ImagePath "\\sccm\pkg\podman-wsl-golden-5.8.9-1.tar.zst"

.NOTES
    Exit codes: 0 success, 1 failure, 2 precondition not met.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [string]$ExpectedSha256,
    [string]$MachineName = 'podman-machine-default',
    [string]$WindowsUserName = $env:USERNAME,
    [string]$UserProfilePath = $env:USERPROFILE,
    [string]$AppDataPath = $env:APPDATA,
    [string]$VsInstallPath,
    [string]$ExpectedPodmanVersion = '5.8',
    [switch]$Rootful,
    [switch]$Force,
    [string]$PodmanExe = 'podman',
    [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'GoldenImage')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # wsl.exe prints UTF-16 otherwise

$HardenSh = '/usr/local/libexec/golden-image/harden.sh'

function Write-Step([string]$Message) { Write-Host "[Invoke-Harden] $Message" }

function Invoke-Native {
    # Runs a native command, streams its output, throws on non-zero exit.
    param([string]$FilePath, [string[]]$Arguments, [switch]$AllowFailure)
    Write-Step ("> {0} {1}" -f $FilePath, ($Arguments -join ' '))
    & $FilePath @Arguments | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ("{0} exited with code {1}" -f $FilePath, $code)
    }
    return $code
}

function Stop-Precondition([string]$Message) {
    $script:exitCode = 2
    throw "precondition: $Message"
}

function Get-DistroName([string]$Name) {
    # Same rule as Podman's env.WithPodmanPrefix
    if ($Name.StartsWith('podman')) { return $Name }
    return "podman-$Name"
}

function Test-MachineExists([string]$Name) {
    $null = & $PodmanExe machine inspect $Name 2>$null
    return ($LASTEXITCODE -eq 0)
}

$exitCode = 0
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$transcript = Join-Path $StateDir ("Invoke-Harden-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $transcript | Out-Null

try {
    # --- preconditions -------------------------------------------------------
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -eq 'S-1-5-18') {
        Stop-Precondition 'Running as SYSTEM. Podman machines are per user: deploy in the user context.'
    }
    if (-not (Get-Command $PodmanExe -ErrorAction SilentlyContinue)) {
        Stop-Precondition "podman not found ($PodmanExe)."
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Stop-Precondition 'wsl.exe not found.'
    }
    $podmanVersion = (& $PodmanExe version --format '{{.Client.Version}}' 2>$null | Select-Object -First 1)
    Write-Step "Podman client $podmanVersion"
    if ($ExpectedPodmanVersion -and -not ("$podmanVersion".StartsWith($ExpectedPodmanVersion))) {
        Stop-Precondition "Podman $podmanVersion does not match the image's Podman $ExpectedPodmanVersion."
    }

    $isLocalImage = -not ($ImagePath -match '^(https?|docker)://')
    if ($isLocalImage) {
        if (-not (Test-Path -LiteralPath $ImagePath)) { Stop-Precondition "Image not found: $ImagePath" }
        $ImagePath = (Resolve-Path -LiteralPath $ImagePath).ProviderPath
        if ($ExpectedSha256) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $ImagePath).Hash
            if ($actual -ne $ExpectedSha256.ToUpperInvariant()) {
                Stop-Precondition "Image SHA-256 mismatch: $actual"
            }
        }
    }

    $distro = Get-DistroName $MachineName

    # --- 1. podman machine init ---------------------------------------------
    if (Test-MachineExists $MachineName) {
        if ($Force) {
            Write-Step "Removing existing machine $MachineName (-Force)"
            Invoke-Native $PodmanExe @('machine', 'stop', $MachineName) -AllowFailure | Out-Null
            Invoke-Native $PodmanExe @('machine', 'rm', '-f', $MachineName) | Out-Null
        } else {
            Write-Step "Machine $MachineName exists: skipping init, re-applying hardening."
        }
    }
    if (-not (Test-MachineExists $MachineName)) {
        $initArgs = @('machine', 'init', '--image', $ImagePath)
        if ($Rootful) { $initArgs += '--rootful' }
        $initArgs += $MachineName
        Invoke-Native $PodmanExe $initArgs | Out-Null
    }
    Invoke-Native $PodmanExe @('machine', 'stop', $MachineName) -AllowFailure | Out-Null

    # --- 2. Windows folders that are mounted ---------------------------------
    $folders = @(
        (Join-Path $UserProfilePath 'source\repos'),
        (Join-Path $UserProfilePath 'vsdbg'),
        (Join-Path $UserProfilePath '.nuget\packages'),
        (Join-Path $AppDataPath 'Microsoft\UserSecrets'),
        (Join-Path $AppDataPath 'ASP.NET\Https')
    )
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f)) {
            New-Item -ItemType Directory -Force -Path $f | Out-Null
            Write-Step "created $f"
        }
    }

    $hardenArgs = @('-d', $distro, '-u', 'root', '--exec', $HardenSh,
        '--win-user', $WindowsUserName,
        '--profile', $UserProfilePath.TrimEnd('\'),
        '--appdata', $AppDataPath.TrimEnd('\'))

    if (-not $VsInstallPath) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $VsInstallPath = & $vswhere -version '[18.0,19.0)' -products * -latest -property installationPath |
                Select-Object -First 1
        }
    }
    if ($VsInstallPath -and (Test-Path -LiteralPath $VsInstallPath)) {
        Write-Step "Visual Studio 2026: $VsInstallPath"
        $hardenArgs += @('--vs-root', $VsInstallPath.TrimEnd('\'))
    } else {
        Write-Step 'Visual Studio 2026 not found: VS tools folders are not mounted.'
        $hardenArgs += '--skip-vs'
    }
    $nugetFallback = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Shared\NuGetPackages'
    if (-not (Test-Path -LiteralPath $nugetFallback)) { $hardenArgs += '--skip-nuget-fallback' }

    # --- 3. harden.sh as root ------------------------------------------------
    # --exec: no shell in between, so backslashes and spaces arrive verbatim.
    Invoke-Native wsl.exe $hardenArgs | Out-Null

    # --- 4. restart so wsl.conf / fstab apply --------------------------------
    Invoke-Native wsl.exe @('--terminate', $distro) -AllowFailure | Out-Null
    Invoke-Native $PodmanExe @('machine', 'start', $MachineName) | Out-Null

    # --- 5. verify and keep a reference copy of the manifest -----------------
    Invoke-Native wsl.exe @('-d', $distro, '-u', 'root', '--exec', $HardenSh, '--verify') | Out-Null
    $refDir = Join-Path $StateDir $distro
    New-Item -ItemType Directory -Force -Path $refDir | Out-Null
    $manifest = & wsl.exe -d $distro -u root --exec cat /etc/golden-image/manifest.sha256
    if ($LASTEXITCODE -ne 0) { throw 'could not read the manifest' }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $refDir 'manifest.sha256'), (($manifest -join "`n") + "`n"), $utf8NoBom)
    $version = (& wsl.exe -d $distro -u root --exec cat /etc/golden-image/version) -join "`n"
    $record = [ordered]@{
        installedAt   = (Get-Date).ToString('o')
        machine       = $MachineName
        distro        = $distro
        image         = $ImagePath
        podmanVersion = "$podmanVersion"
        goldenVersion = $version
    }
    $record | ConvertTo-Json | Set-Content -Encoding UTF8 -Path (Join-Path $refDir 'install.json')
    Write-Step "Done. Reference manifest: $refDir\manifest.sha256"
}
catch {
    Write-Step "FAILED: $($_.Exception.Message)"
    if ($exitCode -eq 0) { $exitCode = 1 }
}
finally {
    Stop-Transcript | Out-Null
}
exit $exitCode
