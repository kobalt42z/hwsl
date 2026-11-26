<#
.SYNOPSIS
    Installer custom action: registers (or removes) the per-user compliance task and the
    Application event log source. Runs as SYSTEM from the MSI (deferred, not impersonated).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Action,
    [string]$InstallDir
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Not a param default: Windows PowerShell 5.1 leaves $PSScriptRoot empty there when
# started by the MSI custom action.
if (-not $InstallDir) { $InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$taskName = 'Podman Golden Image Compliance'
$taskPath = '\PodmanGoldenImage\'
$source = 'PodmanGoldenImage'

if ($Action -eq 'Install') {
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
        [System.Diagnostics.EventLog]::CreateEventSource($source, 'Application')
    }
    $script = Join-Path $InstallDir 'Test-WslCompliance.ps1'
    $ps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Scheduled"
    # Runs for every interactive user (BUILTIN\Users), in that user's context:
    # WSL distros and Podman machines are per user.
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $atLogon = New-ScheduledTaskTrigger -AtLogOn
    $atLogon.Delay = 'PT5M'
    $every4h = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 4)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Principal $principal `
        -Trigger @($atLogon, $every4h) -Settings $settings `
        -Description 'Checks the Podman WSL golden image (registered distros, versions, manifest, self-heal repairs). Results: %LOCALAPPDATA%\PodmanGoldenImage\compliance.json and the Application event log.' `
        -Force | Out-Null
} else {
    $t = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false }
    if ([System.Diagnostics.EventLog]::SourceExists($source)) {
        [System.Diagnostics.EventLog]::DeleteEventSource($source)
    }
}
exit 0
