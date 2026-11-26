<#
.SYNOPSIS
    Silent install / uninstall test of podman-wsl-golden-<ver>-setup.exe (CI or a test VM).
    Needs an elevated session. Does not create a Podman machine.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Setup)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$failures = New-Object System.Collections.Generic.List[string]
function Test-That([string]$Name, [bool]$Condition) {
    if ($Condition) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name"; $failures.Add($Name) }
}

$logDir = Split-Path -Parent $Setup
$image = Join-Path $env:ProgramData 'PodmanGoldenImage\podman-wsl-golden.tar.zst'
$dropin = Join-Path $env:ProgramData 'containers\containers.conf.d\50-podman-golden-image.conf'
$tools = Join-Path $env:ProgramFiles 'PodmanGoldenImage'

# --- install ---------------------------------------------------------------------
$p = Start-Process -FilePath $Setup -ArgumentList '/quiet', '/norestart', '/log', (Join-Path $logDir 'install.log') -Wait -PassThru
Test-That "setup /quiet exit code $($p.ExitCode) is 0 or 3010" ($p.ExitCode -in 0, 3010)

Test-That 'golden image in ProgramData' (Test-Path -LiteralPath $image)
Test-That 'compliance tools installed' (Test-Path -LiteralPath (Join-Path $tools 'Test-WslCompliance.ps1'))
$info = Get-Content -Raw (Join-Path $tools 'bundle-info.json') | ConvertFrom-Json
Test-That 'image matches bundle-info SHA-256' ((Get-FileHash -Algorithm SHA256 $image).Hash.ToLower() -eq $info.imageSha256)

$conf = ''
if (Test-Path -LiteralPath $dropin) { $conf = Get-Content -Raw -LiteralPath $dropin }
Write-Host $conf
Test-That 'containers.conf drop-in sets [machine] image' ($conf -match '(?m)^\[machine\]' -and $conf -match [regex]::Escape("image='$image'"))
Test-That 'containers.conf drop-in sets provider wsl' ($conf -match '(?m)^provider="wsl"')

$acl = Get-Acl -LiteralPath (Split-Path -Parent $image)
$usersWrite = @($acl.Access | Where-Object {
        $_.IdentityReference -match 'Users$' -and $_.AccessControlType -eq 'Allow' -and
        ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]'Write, CreateFiles, AppendData') })
Test-That 'users cannot write the image folder' ($usersWrite.Count -eq 0)

$task = Get-ScheduledTask -TaskPath '\PodmanGoldenImage\' -TaskName 'Podman Golden Image Compliance' -ErrorAction SilentlyContinue
Test-That 'compliance scheduled task registered' ($null -ne $task)
if ($task) { Test-That 'task runs as BUILTIN\Users' ($task.Principal.GroupId -match 'Users|S-1-5-32-545') }
Test-That 'event log source registered' ([System.Diagnostics.EventLog]::SourceExists('PodmanGoldenImage'))

$podman = @("$env:ProgramFiles\RedHat\Podman\podman.exe", "$env:ProgramFiles\Podman\podman.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
Test-That 'Podman installed per-machine' ($null -ne $podman)
if ($podman) {
    $ver = & $podman version --format '{{.Client.Version}}' 2>$null | Select-Object -First 1
    Test-That "Podman version $ver = bundled $($info.podmanVersion)" ("$ver" -eq $info.podmanVersion)
    $help = (& $podman machine init --help 2>&1) -join "`n"
    Test-That 'podman machine init defaults to the golden image' ($help -match [regex]::Escape($image))
}

# --- uninstall -------------------------------------------------------------------
$p = Start-Process -FilePath $Setup -ArgumentList '/uninstall', '/quiet', '/norestart', '/log', (Join-Path $logDir 'uninstall.log') -Wait -PassThru
Test-That "uninstall exit code $($p.ExitCode) is 0 or 3010" ($p.ExitCode -in 0, 3010)
Test-That 'image removed' (-not (Test-Path -LiteralPath $image))
Test-That 'drop-in removed' (-not (Test-Path -LiteralPath $dropin))
Test-That 'task removed' ($null -eq (Get-ScheduledTask -TaskPath '\PodmanGoldenImage\' -TaskName 'Podman Golden Image Compliance' -ErrorAction SilentlyContinue))

if ($failures.Count) { Write-Host "$($failures.Count) check(s) failed"; exit 1 }
Write-Host 'ALL-PASSED'
