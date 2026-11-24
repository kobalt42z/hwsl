<#
.SYNOPSIS
    Compliance check for the hardened Podman WSL golden image. Outputs JSON and an exit code.

.DESCRIPTION
    Checks
      lxss.approved-distros  Only approved distros are registered (HKCU\...\Lxss, or
                             every loaded user hive with -AllUsers)
      lxss.wsl2              Every registered distro is WSL 2
      wsl.version            wsl --version >= -MinWslVersion
      podman.version         podman client matches -ExpectedPodmanVersion (prefix)
      golden.version         /etc/golden-image/version exists (and matches -ExpectedGoldenVersion)
      manifest.live          every file in /etc/golden-image/manifest.sha256 hashes to its entry
      manifest.reference     the in-distro manifest equals the copy Invoke-Harden.ps1 stored
                             outside the distro (%LOCALAPPDATA%\GoldenImage\<distro>)
      manifest.fileset       no new files in the watched dirs (e.g. a new sudoers.d file)

    In-distro checks need the user's context (WSL distros are per user). With
    -AllUsers (e.g. SCCM as SYSTEM) only the registry checks run.

    The distro is started for the check if it is not running, and terminated
    again afterwards; a running machine is left alone.

.OUTPUTS
    JSON on stdout (and to -OutFile). Exit code: 0 PASS, 1 FAIL, 2 error.
#>
[CmdletBinding()]
param(
    [string]$MachineName = 'podman-machine-default',
    [string[]]$ApprovedDistros = @('podman-machine-default'),
    [switch]$AllowUserModeNetworkingDistro,
    [string]$ExpectedPodmanVersion = '5.8',
    [string]$ExpectedGoldenVersion,
    [string]$MinWslVersion = '2.4.4',
    [string]$ReferenceManifest,
    [switch]$AllUsers,
    [string]$OutFile,
    [string]$PodmanExe = 'podman'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

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

    $lxssRoots = @()
    if ($AllUsers) {
        $lxssRoots = Get-ChildItem 'Registry::HKEY_USERS' |
            Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
            ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Lxss" }
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
                $registered += [pscustomobject]@{ hive = $root; name = $p.DistributionName; version = $ver; basePath = $p.BasePath }
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
        Add-Result 'in-distro' 'SKIP' '-AllUsers: in-distro checks need the user context'
    } else {
        # --- Podman version ---------------------------------------------------
        $podmanVer = $null
        if (Get-Command $PodmanExe -ErrorAction SilentlyContinue) {
            $podmanVer = (& $PodmanExe version --format '{{.Client.Version}}' 2>$null | Select-Object -First 1)
        }
        if ($podmanVer -and "$podmanVer".StartsWith($ExpectedPodmanVersion)) { Add-Result 'podman.version' 'PASS' "$podmanVer" }
        else { Add-Result 'podman.version' 'FAIL' "found '$podmanVer', expected $ExpectedPodmanVersion*" }

        if (-not ($registered | Where-Object { $_.name -eq $distro })) {
            Add-Result 'distro.present' 'FAIL' "$distro is not registered"
        } else {
            $running = @(& wsl.exe -l --running --quiet 2>$null) | ForEach-Object { "$_".Trim() }
            if ($running -notcontains $distro) { $startedByUs = $true }

            # --- golden version -----------------------------------------------
            $v = Invoke-Distro $distro @('cat', '/etc/golden-image/version')
            if ($v.ExitCode -ne 0) { Add-Result 'golden.version' 'FAIL' '/etc/golden-image/version missing' }
            else {
                $text = $v.Output -join "`n"
                if ($ExpectedGoldenVersion -and ($text -notmatch "(?m)^GOLDEN_VERSION=$([regex]::Escape($ExpectedGoldenVersion))$")) {
                    Add-Result 'golden.version' 'FAIL' $text
                } else { Add-Result 'golden.version' 'PASS' $text }
            }

            # --- manifest: live hashes ----------------------------------------
            $m = Invoke-Distro $distro @('cat', '/etc/golden-image/manifest.sha256')
            if ($m.ExitCode -ne 0 -or $m.Output.Count -eq 0) {
                Add-Result 'manifest.live' 'FAIL' 'manifest missing'
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

                # --- manifest vs reference copy outside the distro -------------
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
                    Add-Result 'manifest.reference' 'FAIL' "no reference copy at $ReferenceManifest"
                }

                # --- file set (new files in watched dirs) ----------------------
                $fs = Invoke-Distro $distro @('/usr/local/libexec/golden-image/harden.sh', '--verify')
                if ($fs.ExitCode -eq 0) { Add-Result 'manifest.fileset' 'PASS' $null }
                else { Add-Result 'manifest.fileset' 'FAIL' 'harden.sh --verify failed (changed, missing or new files)' }
            }
        }
    }

    if (@($results | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0) { $exitCode = 1 }
}
catch {
    Add-Result 'error' 'ERROR' $_.Exception.Message
    $exitCode = 2
}
finally {
    if ($startedByUs) { & wsl.exe --terminate $distro 2>$null | Out-Null }
}

$overall = 'PASS'
if ($exitCode -eq 1) { $overall = 'FAIL' } elseif ($exitCode -eq 2) { $overall = 'ERROR' }
$report = [ordered]@{
    schema    = 'golden-image-compliance/v1'
    timestamp = (Get-Date).ToString('o')
    computer  = $env:COMPUTERNAME
    user      = "$env:USERDOMAIN\$env:USERNAME"
    machine   = $MachineName
    result    = $overall
    checks    = $results
}
$json = $report | ConvertTo-Json -Depth 6
if ($OutFile) { $json | Set-Content -Encoding UTF8 -Path $OutFile }
Write-Output $json
exit $exitCode
