<#
.SYNOPSIS
    Builds the self-contained, offline installer:
    out\installer\podman-wsl-golden-<version>-setup.exe

.DESCRIPTION
    Runs on a Windows build agent with the .NET SDK and WiX 5
    (dotnet tool install --global wix --version 5.0.2). This is the only step that
    may need network access, to fetch the pinned Podman MSI. Point -PodmanMsi (and
    -WslMsi) at pre-downloaded files to build air-gapped as well.

      1. reads the golden image record (podman-wsl-golden-<ver>.json from build/build.sh)
         and checks the image's SHA-256
      2. gets the official Podman MSI for the image's Podman version and checks it:
         SHA-256 against -PodmanMsiSha256, or else the release's `shasums` file;
         Authenticode must be valid when the file is signed (-RequireSignature: always)
      3. optionally takes a Microsoft WSL MSI (-WslMsi) for PCs without WSL
      4. builds PodmanGoldenImage.msi, then the Burn bundle that chains
         [WSL] -> Podman -> PodmanGoldenImage

.EXAMPLE
    .\installer\build-installer.ps1 -GoldenImage .\out\podman-wsl-golden-5.8.9-1.tar.zst

.EXAMPLE
    # fully offline build, with WSL for fresh PCs
    .\installer\build-installer.ps1 -GoldenImage .\out\podman-wsl-golden-5.8.9-1.tar.zst `
        -PodmanMsi .\deps\podman-installer-windows-amd64.msi -PodmanMsiSha256 <sha> `
        -WslMsi .\deps\wsl.2.6.1.0.x64.msi -WslMsiSha256 <sha> -RequireSignature
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GoldenImage,
    [string]$PodmanMsi,
    [string]$PodmanMsiSha256,
    [string]$PodmanReleaseUrl = 'https://github.com/containers/podman/releases/download',
    [string]$WslMsi,
    [string]$WslMsiSha256,
    [switch]$RequireSignature,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\installer'),
    [string]$WixExe = 'wix'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$m) { Write-Host "[build-installer] $m" }

function Assert-Sha256([string]$Path, [string]$Expected, [string]$What) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$What SHA-256 mismatch: $actual (expected $Expected)"
    }
    Write-Step "$What SHA-256 OK ($actual)"
    return $actual
}

function Assert-Signature([string]$Path, [string]$What) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -eq 'Valid') {
        Write-Step "$What signed by: $($sig.SignerCertificate.Subject)"
    } elseif ($sig.Status -eq 'NotSigned' -and -not $RequireSignature) {
        Write-Warning "$What is not Authenticode-signed; relying on the SHA-256 pin. Use -RequireSignature to refuse."
    } else {
        throw "$What signature status: $($sig.Status)"
    }
}

function Invoke-Wix([string[]]$WixArgs) {
    Write-Step ("wix " + ($WixArgs -join ' '))
    & $WixExe @WixArgs
    if ($LASTEXITCODE -ne 0) { throw "wix exited with $LASTEXITCODE" }
}

# --- 1. golden image -----------------------------------------------------------
$GoldenImage = (Resolve-Path -LiteralPath $GoldenImage).ProviderPath
$recordPath = $GoldenImage -replace '\.tar\.zst$', '.json'
if (-not (Test-Path -LiteralPath $recordPath)) { throw "build record not found: $recordPath (from build/build.sh)" }
$record = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
$imageSha = Assert-Sha256 $GoldenImage $record.sha256 'golden image'
$goldenVersion = [string]$record.golden_version
$podmanVersion = [string]$record.podman_version

# Windows Installer / Burn versions are numeric: 5.8.9-1 -> 5.8.9.1
$nums = @([regex]::Matches($goldenVersion, '\d+') | ForEach-Object { $_.Value })
if ($nums.Count -lt 3) { throw "GOLDEN_VERSION '$goldenVersion' needs at least major.minor.patch" }
while ($nums.Count -lt 4) { $nums += '0' }
$msiVersion = ($nums[0..3] -join '.')
Write-Step "golden $goldenVersion (installer version $msiVersion), Podman $podmanVersion"

$stage = Join-Path $OutDir 'stage'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# --- 2. Podman MSI ----------------------------------------------------------------
$podmanAsset = 'podman-installer-windows-amd64.msi'
if (-not $PodmanMsi) {
    $PodmanMsi = Join-Path $OutDir "deps\podman-$podmanVersion-$podmanAsset"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PodmanMsi) | Out-Null
    $url = "$PodmanReleaseUrl/v$podmanVersion/$podmanAsset"
    Write-Step "downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $PodmanMsi
    if (-not $PodmanMsiSha256) {
        $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$PodmanReleaseUrl/v$podmanVersion/shasums").Content
        if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
        $line = @($sums -split "`n" | Where-Object { $_ -match "\s\*?$([regex]::Escape($podmanAsset))\s*$" }) | Select-Object -First 1
        if (-not $line) { throw "no $podmanAsset entry in the release shasums; pass -PodmanMsiSha256" }
        $PodmanMsiSha256 = ($line -split '\s+')[0]
    }
}
if (-not $PodmanMsiSha256) { throw '-PodmanMsiSha256 is required with a local -PodmanMsi' }
$podmanSha = Assert-Sha256 $PodmanMsi $PodmanMsiSha256 'Podman MSI'
Assert-Signature $PodmanMsi 'Podman MSI'

# --- 3. WSL MSI (optional) ----------------------------------------------------------
$wslSha = $null
if ($WslMsi) {
    if (-not $WslMsiSha256) { throw '-WslMsiSha256 is required with -WslMsi' }
    $wslSha = Assert-Sha256 $WslMsi $WslMsiSha256 'WSL MSI'
    Assert-Signature $WslMsi 'WSL MSI'
}

# --- 4. stage + build -------------------------------------------------------------
$repo = Split-Path -Parent $PSScriptRoot
Copy-Item -LiteralPath $GoldenImage -Destination (Join-Path $stage 'podman-wsl-golden.tar.zst')
Copy-Item (Join-Path $repo 'compliance\Test-WslCompliance.ps1') $stage
Copy-Item (Join-Path $repo 'post-init\Invoke-Harden.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'files\Register-GoldenImageTasks.ps1') $stage
[ordered]@{
    bundleVersion   = $msiVersion
    goldenVersion   = $goldenVersion
    podmanVersion   = $podmanVersion
    imageFile       = 'podman-wsl-golden.tar.zst'
    imageSha256     = $imageSha
    podmanMsiSha256 = $podmanSha
    wslMsiSha256    = $wslSha
    sourceCommit    = $record.source_commit
} | ConvertTo-Json | Set-Content -Encoding UTF8 -Path (Join-Path $stage 'bundle-info.json')

$goldenMsi = Join-Path $OutDir "PodmanGoldenImage-$goldenVersion.msi"
Invoke-Wix @('build', '-arch', 'x64', '-ext', 'WixToolset.Util.wixext',
    '-d', "Version=$msiVersion", '-d', "PayloadDir=$stage",
    (Join-Path $PSScriptRoot 'wix\GoldenImage.wxs'), '-o', $goldenMsi)

$setup = Join-Path $OutDir "podman-wsl-golden-$goldenVersion-setup.exe"
$bundleArgs = @('build', '-arch', 'x64', '-ext', 'WixToolset.BootstrapperApplications.wixext',
    '-d', "Version=$msiVersion", '-d', "PodmanMsi=$((Resolve-Path $PodmanMsi).ProviderPath)", '-d', "GoldenMsi=$goldenMsi")
if ($WslMsi) { $bundleArgs += @('-d', "WslMsi=$((Resolve-Path $WslMsi).ProviderPath)") }
$bundleArgs += @((Join-Path $PSScriptRoot 'wix\Bundle.wxs'), '-o', $setup)
Invoke-Wix $bundleArgs

$setupSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash.ToLowerInvariant()
"$setupSha  $(Split-Path -Leaf $setup)" | Set-Content -Encoding ASCII -Path "$setup.sha256"
Copy-Item (Join-Path $stage 'bundle-info.json') (Join-Path $OutDir "podman-wsl-golden-$goldenVersion-setup.json")
Remove-Item -Recurse -Force $stage
Write-Step "done: $setup"
Write-Step "      $goldenMsi (for SCCM admins who deploy the MSIs separately)"
