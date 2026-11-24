<#
.SYNOPSIS
    Acceptance tests for the hardened Podman WSL golden image (run on a Windows dev PC).

.DESCRIPTION
    Automates the acceptance criteria that can be automated and lists the rest
    as MANUAL. Run in the developer's (non-elevated) user context.

      AC1  podman machine init --image <tar> and podman machine start succeed (WSL provider)
      AC2  only the approved Windows folders are mounted; no other drive is mounted
      AC3  "podman pull alpine" resolves to Artifactory; direct docker.io access fails
      AC4  VS 2026 Compose up / F5 breakpoint / Hot Reload       (MANUAL + mount check)
      AC5  manifest still matches after a machine restart (and after a Podman
           minor upgrade: re-run with -SkipInstall after upgrading)
      AC6  running a Windows exe from inside the distro fails (interop off)
      AC7  compliance PASS on a clean install, FAIL after editing wsl.conf

    WARNING: without -SkipInstall this runs Invoke-Harden.ps1 -Force, which
    REMOVES an existing machine with the same name.

.EXAMPLE
    .\tests\acceptance.ps1 -ImagePath .\out\podman-wsl-golden-5.8.9-1.tar.zst -ArtifactoryHost artifactory.example.com

.EXAMPLE
    # After upgrading Podman for Windows to the next minor (AC5, upgrade half)
    .\tests\acceptance.ps1 -SkipInstall -ArtifactoryHost artifactory.example.com
#>
[CmdletBinding()]
param(
    [string]$ImagePath,
    [Parameter(Mandatory = $true)][string]$ArtifactoryHost,
    [string]$MachineName = 'podman-test-golden',
    [switch]$SkipInstall,
    [ValidateSet('redirect', 'block')][string]$RegistryMode = 'redirect',
    [string]$VsContainer,
    [string]$OutFile = (Join-Path $PSScriptRoot 'acceptance-result.json'),
    [string]$PodmanExe = 'podman'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

$repo = Split-Path -Parent $PSScriptRoot
$distro = if ($MachineName.StartsWith('podman')) { $MachineName } else { "podman-$MachineName" }
$compliance = Join-Path $repo 'compliance\Test-WslCompliance.ps1'
$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Id, [string]$Name, [string]$Status, $Detail) {
    $results.Add([ordered]@{ id = $Id; name = $Name; status = $Status; detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("[{0}] {1,-6} {2}" -f $Id, $Status, $Name) -ForegroundColor $color
}

function Invoke-Root([string[]]$Command) {
    $out = & wsl.exe -d $distro -u root --exec @Command 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($out) -join "`n") }
}

function Invoke-MachineSsh([string]$Command) {
    # Runs inside Podman's systemd namespace as "user" (where containers run).
    $out = & $PodmanExe machine ssh $MachineName $Command 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($out) -join "`n") }
}

function Test-Compliance {
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compliance `
        -MachineName $MachineName -ApprovedDistros @($MachineName) 2>$null
    return $LASTEXITCODE
}

function Get-ApprovedTargets {
    $p = $env:USERPROFILE; $a = $env:APPDATA
    $list = @("$p\source\repos", "$p\vsdbg", "$p\.nuget\packages", "$a\Microsoft\UserSecrets", "$a\ASP.NET\Https")
    return @($list | ForEach-Object { '/mnt/' + $_.Substring(0, 1).ToLower() + ($_.Substring(2) -replace '\\', '/') })
}

# ---------------------------------------------------------------- AC1
try {
    if (-not $SkipInstall) {
        if (-not $ImagePath) { throw '-ImagePath is required unless -SkipInstall' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'post-init\Invoke-Harden.ps1') `
            -ImagePath $ImagePath -MachineName $MachineName -Force | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Invoke-Harden.ps1 exited $LASTEXITCODE" }
    } else {
        & $PodmanExe machine start $MachineName 2>$null | Out-Host
    }
    $state = (& $PodmanExe machine inspect $MachineName --format '{{.State}}' 2>$null) -join ''
    $vmType = (& $PodmanExe machine inspect $MachineName --format '{{.VMType}}' 2>$null) -join ''
    if ($state -eq 'running' -and $vmType -eq 'wsl') { Add-Result 'AC1' 'machine init/start on WSL' 'PASS' "$vmType/$state" }
    else { Add-Result 'AC1' 'machine init/start on WSL' 'FAIL' "$vmType/$state" }
} catch {
    Add-Result 'AC1' 'machine init/start on WSL' 'FAIL' $_.Exception.Message
}

# ---------------------------------------------------------------- AC2
# Windows file systems show up as 9p (drvfs) or virtiofs in /proc/mounts.
$mnt = Invoke-MachineSsh 'cat /proc/self/mounts'
$mounted = @($mnt.Output -split "`n" | ForEach-Object {
        $f = $_ -split ' '
        if ($f.Count -ge 3 -and @('9p', 'drvfs', 'virtiofs') -contains $f[2]) { $f[1] -replace '\\040', ' ' }
    } | Where-Object { $_ -like '/mnt/*' -and $_ -notlike '/mnt/wsl*' })
$approved = Get-ApprovedTargets
$unexpected = @($mounted | Where-Object {
        $m = $_
        -not ($approved | Where-Object { $m -eq $_ }) -and
        -not ($m -like '/mnt/c/Program Files*Microsoft Visual Studio*')
    })
$drives = Invoke-Root @('ls', '-1', '/mnt')
$extraDrives = @($drives.Output -split "`n" | Where-Object { $_ -match '^[a-z]$' -and $_ -ne 'c' })
$cTop = Invoke-Root @('ls', '-1', '/mnt/c')
$cTopEntries = @($cTop.Output -split "`n" | Where-Object { $_ })
$badTop = @($cTopEntries | Where-Object { @('Users', 'Program Files', 'Program Files (x86)') -notcontains $_ })
$windowsVisible = (Invoke-Root @('test', '-e', '/mnt/c/Windows/System32')).ExitCode -eq 0
if ($unexpected.Count -eq 0 -and $extraDrives.Count -eq 0 -and $badTop.Count -eq 0 -and -not $windowsVisible -and $mounted.Count -gt 0) {
    Add-Result 'AC2' 'only approved folders mounted' 'PASS' @{ mounted = $mounted; mntC = $cTopEntries }
} else {
    Add-Result 'AC2' 'only approved folders mounted' 'FAIL' @{ unexpected = $unexpected; drives = $extraDrives; mntC = $badTop; windowsVisible = $windowsVisible; mounted = $mounted }
}

# ---------------------------------------------------------------- AC3
$pull = Invoke-MachineSsh 'podman --log-level=debug pull alpine 2>&1'
$viaArtifactory = $pull.ExitCode -eq 0 -and ($pull.Output -match [regex]::Escape($ArtifactoryHost))
$directHub = Invoke-MachineSsh 'curl -sS -m 15 -o /dev/null -w %{http_code} https://registry-1.docker.io/v2/ 2>&1; echo; podman pull registry-1.docker.io/library/alpine 2>&1'
$hubReachable = $directHub.Output -match '(?m)^(200|401)'
$hubPull = $directHub.Output -match 'Writing manifest|Storing signatures'
$blockedPull = $true
if ($RegistryMode -eq 'block') {
    $b = Invoke-MachineSsh 'podman pull docker.io/library/alpine 2>&1'
    $blockedPull = $b.ExitCode -ne 0
}
if ($viaArtifactory -and -not $hubReachable -and -not $hubPull -and $blockedPull) {
    Add-Result 'AC3' 'pull via Artifactory, docker.io direct fails' 'PASS' $null
} else {
    Add-Result 'AC3' 'pull via Artifactory, docker.io direct fails' 'FAIL' @{
        alpineViaArtifactory = $viaArtifactory; dockerHubReachable = $hubReachable; directPullWorked = $hubPull; blockedPull = $blockedPull
        log = ($pull.Output -split "`n" | Select-String -Pattern 'Trying to|Error' | ForEach-Object { "$_" })
    }
}

# ---------------------------------------------------------------- AC4
if ($VsContainer) {
    $mj = (& $PodmanExe inspect $VsContainer --format '{{json .Mounts}}' 2>$null) -join ''
    $mounts = @()
    if ($mj) { $mounts = @($mj | ConvertFrom-Json) }
    $sources = @($mounts | ForEach-Object { $_.Source } | Where-Object { $_ -like '/mnt/*' })
    $outside = @($sources | Where-Object {
            $s = $_
            -not ($mounted | Where-Object { $s -eq $_ -or $s.StartsWith("$_/") })
        })
    if ($outside.Count -eq 0 -and $sources.Count -gt 0) {
        Add-Result 'AC4a' "VS container $VsContainer uses only approved mounts" 'PASS' $sources
    } else {
        Add-Result 'AC4a' "VS container $VsContainer uses only approved mounts" 'FAIL' @{ outside = $outside; all = $sources }
    }
} else {
    Add-Result 'AC4a' 'VS container mount check' 'MANUAL' 'Start a VS 2026 Compose debug session, then re-run with -VsContainer <name>'
}
Add-Result 'AC4b' 'VS 2026: Compose up, F5 breakpoint hit, Hot Reload' 'MANUAL' 'See README "Manual acceptance steps"'

# ---------------------------------------------------------------- AC5
$before = Test-Compliance
& $PodmanExe machine stop $MachineName 2>$null | Out-Host
& $PodmanExe machine start $MachineName 2>$null | Out-Host
$after = Test-Compliance
if ($before -eq 0 -and $after -eq 0) { Add-Result 'AC5' 'manifest matches after restart' 'PASS' $null }
else { Add-Result 'AC5' 'manifest matches after restart' 'FAIL' @{ before = $before; after = $after } }
Add-Result 'AC5b' 'manifest matches after Podman minor upgrade' 'MANUAL' 'Upgrade Podman for Windows, then run: acceptance.ps1 -SkipInstall'

# ---------------------------------------------------------------- AC6
# With interop off, WSL does not register the WSLInterop binfmt handler, so a PE
# file is not handed to Windows. We build a minimal "MZ" file and try to run it.
$interop = Invoke-Root @('sh', '-c',
    'ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -i interop; ' +
    'for f in /proc/sys/fs/binfmt_misc/WSLInterop*; do [ -f "$f" ] && head -n1 "$f"; done; ' +
    'printf "MZ" > /tmp/probe.exe; chmod +x /tmp/probe.exe; /tmp/probe.exe; echo "rc=$?"; rm -f /tmp/probe.exe; ' +
    'test -e /mnt/c/Windows/System32/cmd.exe && echo cmd-visible')
$handlerEnabled = $interop.Output -match '(?m)^enabled$'
$cmdVisible = $interop.Output -match 'cmd-visible'
$sshInterop = Invoke-MachineSsh 'printf MZ > /tmp/p.exe; chmod +x /tmp/p.exe; /tmp/p.exe; echo rc=$?; rm -f /tmp/p.exe'
if (-not $handlerEnabled -and -not $cmdVisible -and $interop.Output -match 'rc=(126|127|2)' -and $sshInterop.Output -match 'rc=(126|127|2)') {
    Add-Result 'AC6' 'Windows exe from distro fails (interop off)' 'PASS' $null
} else {
    Add-Result 'AC6' 'Windows exe from distro fails (interop off)' 'FAIL' @{ root = $interop.Output; ssh = $sshInterop.Output }
}

# ---------------------------------------------------------------- AC7
$clean = Test-Compliance
$null = Invoke-Root @('sh', '-c', 'echo "# acceptance tamper test" >> /etc/wsl.conf')
$tampered = Test-Compliance
# restore: harden.sh rewrites wsl.conf to the same content, so the manifest matches again
$null = Invoke-Root @('sh', '-c', 'sed -i "/# acceptance tamper test/d" /etc/wsl.conf')
$restored = Test-Compliance
if ($clean -eq 0 -and $tampered -eq 1 -and $restored -eq 0) {
    Add-Result 'AC7' 'compliance PASS clean / FAIL after wsl.conf edit' 'PASS' $null
} else {
    Add-Result 'AC7' 'compliance PASS clean / FAIL after wsl.conf edit' 'FAIL' @{ clean = $clean; tampered = $tampered; restored = $restored }
}

# ---------------------------------------------------------------- report
$failed = @($results | Where-Object { $_.status -eq 'FAIL' }).Count
$report = [ordered]@{
    timestamp = (Get-Date).ToString('o'); machine = $MachineName; registryMode = $RegistryMode
    result = $(if ($failed -eq 0) { 'PASS' } else { 'FAIL' }); results = $results
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $OutFile
Write-Host "Report: $OutFile"
if ($failed -gt 0) { exit 1 } else { exit 0 }
