<#
.SYNOPSIS
    Compliance check for the hardened Podman WSL golden image. Outputs JSON and an exit code.

.DESCRIPTION
    Checks
      lxss.approved-distros  only approved distros are registered (HKCU\...\Lxss, or every
                             loaded user hive with -AllUsers)
      lxss.wsl2              every registered distro is WSL 2
      wsl.version            wsl --version >= -MinWslVersion
      podman.version         podman client = the version the installer bundled
      podman.default-image   no per-user containers.conf overrides [machine] image
      golden.version         the machine was built from the golden image (FAIL if not), and
                             from the installed one (WARN if older: recreate the machine)
      manifest.live          every file in /etc/golden-image/manifest.sha256 hashes to its entry
      manifest.fileset       harden.sh --verify (also catches new files, e.g. in sudoers.d)
      manifest.reference     the in-distro manifest equals a reference copy kept outside the
                             distro, when one exists (Invoke-Harden.ps1 writes it)
      selfheal.repairs       repairs the boot-time self-heal made since the last check (WARN)

    Expected versions come from bundle-info.json next to this script (written by the
    installer), or from -ExpectedPodmanVersion / -ExpectedGoldenVersion.

    In-distro checks need the user's context (WSL distros are per user). With -NoStart
    (and -Scheduled) a stopped machine is not started: in-distro checks are skipped.
    Without it, a stopped distro is started for the check and terminated afterwards.

.PARAMETER Scheduled
    Mode used by the installed scheduled task: -NoStart, -EventLog, and -OutFile
    %LOCALAPPDATA%\PodmanGoldenImage\compliance.json.

.OUTPUTS
    JSON on stdout (and to -OutFile). Exit code: 0 PASS, 1 FAIL, 2 ERROR, 3 WARN.
#>
[CmdletBinding()]
param(
    [string]$MachineName = 'podman-machine-default',
    [string[]]$ApprovedDistros = @('podman-machine-default'),
    [switch]$AllowUserModeNetworkingDistro,
    [string]$ExpectedPodmanVersion,
    [string]$ExpectedGoldenVersion,
    [string]$MinWslVersion = '2.4.4',
    [string]$ReferenceManifest,
    [switch]$AllUsers,
    [switch]$NoStart,
    [switch]$EventLog,
    [switch]$Scheduled,
    [string]$OutFile,
    [string]$PodmanExe = 'podman'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

$stateDir = Join-Path $env:LOCALAPPDATA 'PodmanGoldenImage'
if ($Scheduled) {
    $NoStart = $true; $EventLog = $true
    if (-not $OutFile) { $OutFile = Join-Path $stateDir 'compliance.json' }
}
$EventSource = 'PodmanGoldenImage'

# Expected versions from the installer, unless given explicitly
$bundleInfo = $null
$bundleInfoPath = Join-Path $PSScriptRoot 'bundle-info.json'
if (Test-Path -LiteralPath $bundleInfoPath) {
    $bundleInfo = Get-Content -Raw -LiteralPath $bundleInfoPath | ConvertFrom-Json
    if (-not $ExpectedPodmanVersion) { $ExpectedPodmanVersion = $bundleInfo.podmanVersion }
    if (-not $ExpectedGoldenVersion) { $ExpectedGoldenVersion = $bundleInfo.goldenVersion }
}
if (-not $ExpectedPodmanVersion) { $ExpectedPodmanVersion = '5.8' }

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Name, [string]$Status, $Detail) {
    $results.Add([ordered]@{ check = $Name; status = $Status; detail = $Detail })
}

function Get-DistroName([string]$Name) {
    if ($Name.StartsWith('podman')) { return $Name }
    return "podman-$Name"
}

function Invoke-Distro {
    # Runs a command in the distro as root without a shell; returns stdout lines.
    param([string]$Distro, [string[]]$Command)
    $out = & wsl.exe -d $Distro -u root --exec @Command 2>$null
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
}

function ConvertFrom-Manifest([string[]]$Lines) {
    $map = [ordered]@{}
    foreach ($l in $Lines) {
        if ($l -match '^([0-9a-f]{64})\s+\*?(.+)$') { $map[$Matches[2]] = $Matches[1] }
    }
    return $map
}

$distro = Get-DistroName $MachineName
$exitCode = 0
$startedByUs = $false

try {
    # --- registry: registered distros ----------------------------------------
    $approved = @($ApprovedDistros | ForEach-Object { Get-DistroName $_ })
    if ($AllowUserModeNetworkingDistro) { $approved += 'podman-net-usermode' }

    if ($AllUsers) {
        $lxssRoots = @(Get-ChildItem 'Registry::HKEY_USERS' |
            Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
            ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Lxss" })
    } else {
        $lxssRoots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss')
    }
    $registered = @()
    foreach ($root in $lxssRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath
            if ($p.PSObject.Properties['DistributionName']) {
                $ver = 0; if ($p.PSObject.Properties['Version']) { $ver = [int]$p.Version }
                $registered += [pscustomobject]@{ hive = $root; name = $p.DistributionName; version = $ver }
            }
        }
    }
    $unapproved = @($registered | Where-Object { $approved -notcontains $_.name })
    if ($unapproved.Count -eq 0) {
        Add-Result 'lxss.approved-distros' 'PASS' @{ registered = @($registered | ForEach-Object { $_.name }) }
    } else {
        Add-Result 'lxss.approved-distros' 'FAIL' @{ unapproved = @($unapproved | ForEach-Object { $_.name }); approved = $approved }
    }
    $notWsl2 = @($registered | Where-Object { $_.version -ne 2 })
    if ($notWsl2.Count -eq 0) { Add-Result 'lxss.wsl2' 'PASS' $null }
    else { Add-Result 'lxss.wsl2' 'FAIL' @{ distros = @($notWsl2 | ForEach-Object { $_.name }) } }

    # --- WSL version ---------------------------------------------------------
    $wslVersionText = (& wsl.exe --version 2>$null) -join "`n"
    if ($wslVersionText -match '(?m)^\s*WSL[^:\r\n]*:\s*([0-9]+(\.[0-9]+){1,3})') {
        $wslVer = [version]$Matches[1]
        if ($wslVer -ge [version]$MinWslVersion) { Add-Result 'wsl.version' 'PASS' "$wslVer" }
        else { Add-Result 'wsl.version' 'FAIL' "$wslVer < $MinWslVersion" }
    } else {
        Add-Result 'wsl.version' 'FAIL' 'could not parse wsl --version (inbox WSL is not supported)'
    }

    if ($AllUsers) {
        Add-Result 'in-distro' 'SKIP' '-AllUsers: per-user checks need the user context'
    } else {
        # --- Podman version ---------------------------------------------------
        $podmanVer = $null
        if (Get-Command $PodmanExe -ErrorAction SilentlyContinue) {
            $podmanVer = (& $PodmanExe version --format '{{.Client.Version}}' 2>$null | Select-Object -First 1)
        }
        if ($podmanVer -and "$podmanVer".StartsWith($ExpectedPodmanVersion)) { Add-Result 'podman.version' 'PASS' "$podmanVer" }
        else { Add-Result 'podman.version' 'FAIL' "found '$podmanVer', expected $ExpectedPodmanVersion" }

        # --- per-user override of the default machine image -------------------
        $userConf = Join-Path $env:APPDATA 'containers\containers.conf'
        $confFiles = @()
        if (Test-Path -LiteralPath $userConf) { $confFiles += $userConf }
        if (Test-Path -LiteralPath "$userConf.d") { $confFiles += @(Get-ChildItem -LiteralPath "$userConf.d" -File | ForEach-Object { $_.FullName }) }
        $overrides = @($confFiles | Where-Object { Select-String -LiteralPath $_ -Pattern '^\s*image\s*=' -Quiet })
        if ($overrides.Count -eq 0) { Add-Result 'podman.default-image' 'PASS' $null }
        else { Add-Result 'podman.default-image' 'WARN' @{ overriddenIn = $overrides } }

        if (-not ($registered | Where-Object { $_.name -eq $distro })) {
            Add-Result 'distro.present' 'SKIP' "$distro is not created yet (podman machine init)"
        } else {
            $running = @(& wsl.exe -l --running --quiet 2>$null) | ForEach-Object { "$_".Trim() }
            $isRunning = $running -contains $distro
            if (-not $isRunning -and $NoStart) {
                Add-Result 'in-distro' 'SKIP' "$distro is stopped (-NoStart)"
            } else {
                if (-not $isRunning) { $startedByUs = $true }

                # --- golden version -------------------------------------------
                $v = Invoke-Distro $distro @('cat', '/etc/golden-image/version')
                if ($v.ExitCode -ne 0) {
                    Add-Result 'golden.version' 'FAIL' 'not built from the golden image (/etc/golden-image/version missing)'
                } else {
                    $text = $v.Output -join "`n"
                    if ($ExpectedGoldenVersion -and ($text -notmatch "(?m)^GOLDEN_VERSION=$([regex]::Escape($ExpectedGoldenVersion))$")) {
                        Add-Result 'golden.version' 'WARN' "machine image differs from the installed golden image $ExpectedGoldenVersion; recreate the machine. $text"
                    } else { Add-Result 'golden.version' 'PASS' $text }
                }

                # --- manifest: live hashes ------------------------------------
                $m = Invoke-Distro $distro @('cat', '/etc/golden-image/manifest.sha256')
                if ($m.ExitCode -ne 0 -or $m.Output.Count -eq 0) {
                    Add-Result 'manifest.live' 'FAIL' 'manifest missing (machine never booted with the self-heal, or not a golden image)'
                } else {
                    $expected = ConvertFrom-Manifest $m.Output
                    $paths = @($expected.Keys)
                    $live = Invoke-Distro $distro (@('sha256sum', '--') + $paths)
                    $actual = ConvertFrom-Manifest $live.Output
                    $mismatch = @()
                    foreach ($p in $paths) {
                        if (-not $actual.Contains($p)) { $mismatch += "${p}: missing" }
                        elseif ($actual[$p] -ne $expected[$p]) { $mismatch += "${p}: changed" }
                    }
                    if ($mismatch.Count -eq 0) { Add-Result 'manifest.live' 'PASS' "$($paths.Count) files" }
                    else { Add-Result 'manifest.live' 'FAIL' $mismatch }

                    $fs = Invoke-Distro $distro @('/usr/local/libexec/golden-image/harden.sh', '--verify')
                    if ($fs.ExitCode -eq 0) { Add-Result 'manifest.fileset' 'PASS' $null }
                    else { Add-Result 'manifest.fileset' 'FAIL' 'harden.sh --verify failed (changed, missing or new files)' }

                    # --- reference copy outside the distro (optional) ----------
                    if (-not $ReferenceManifest) {
                        $ReferenceManifest = Join-Path $env:LOCALAPPDATA "GoldenImage\$distro\manifest.sha256"
                    }
                    if (Test-Path -LiteralPath $ReferenceManifest) {
                        $ref = ConvertFrom-Manifest (Get-Content -LiteralPath $ReferenceManifest)
                        $diff = @()
                        foreach ($p in (@($ref.Keys) + @($expected.Keys) | Select-Object -Unique)) {
                            if (-not $ref.Contains($p)) { $diff += "${p}: not in reference" }
                            elseif (-not $expected.Contains($p)) { $diff += "${p}: removed from manifest" }
                            elseif ($ref[$p] -ne $expected[$p]) { $diff += "${p}: manifest rewritten" }
                        }
                        if ($diff.Count -eq 0) { Add-Result 'manifest.reference' 'PASS' $ReferenceManifest }
                        else { Add-Result 'manifest.reference' 'FAIL' $diff }
                    } else {
                        Add-Result 'manifest.reference' 'SKIP' 'no reference copy (optional)'
                    }
                }

                # --- self-heal repairs since the last check -------------------
                $r = Invoke-Distro $distro @('cat', '/var/log/golden-image/repairs.log')
                $repairs = @($r.Output | Where-Object { $_ -match ' REPAIR ' })
                $seenFile = Join-Path $stateDir "$distro.repairs-seen"
                $seen = 0
                if (Test-Path -LiteralPath $seenFile) { $seen = [int](Get-Content -LiteralPath $seenFile | Select-Object -First 1) }
                if ($repairs.Count -lt $seen) { $seen = 0 }  # machine was recreated
                $new = @($repairs | Select-Object -Skip $seen)
                if ($new.Count -eq 0) { Add-Result 'selfheal.repairs' 'PASS' "$($repairs.Count) repairs in total" }
                else { Add-Result 'selfheal.repairs' 'WARN' @{ newRepairs = $new; details = @($r.Output) } }
                New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
                Set-Content -LiteralPath $seenFile -Value $repairs.Count
            }
        }
    }

    if (@($results | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0) { $exitCode = 1 }
    elseif (@($results | Where-Object { $_.status -eq 'WARN' }).Count -gt 0) { $exitCode = 3 }
}
catch {
    Add-Result 'error' 'ERROR' $_.Exception.Message
    $exitCode = 2
}
finally {
    if ($startedByUs) { & wsl.exe --terminate $distro 2>$null | Out-Null }
}

$overall = switch ($exitCode) { 0 { 'PASS' } 1 { 'FAIL' } 2 { 'ERROR' } 3 { 'WARN' } }
$report = [ordered]@{
    schema        = 'golden-image-compliance/v2'
    timestamp     = (Get-Date).ToString('o')
    computer      = $env:COMPUTERNAME
    user          = "$env:USERDOMAIN\$env:USERNAME"
    machine       = $MachineName
    bundleVersion = $(if ($bundleInfo) { $bundleInfo.bundleVersion } else { $null })
    result        = $overall
    checks        = $results
}
$json = $report | ConvertTo-Json -Depth 6
if ($OutFile) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    $json | Set-Content -Encoding UTF8 -Path $OutFile
}
if ($EventLog) {
    # Source registered by the installer; ignore if missing (manual runs).
    try {
        $type = switch ($exitCode) { 0 { 'Information' } 3 { 'Warning' } default { 'Error' } }
        $eventId = 1000 + $exitCode
        [System.Diagnostics.EventLog]::WriteEntry($EventSource, $json, $type, $eventId)
    } catch {
        Write-Verbose "event log write skipped: $($_.Exception.Message)"
    }
}
Write-Output $json
exit $exitCode
