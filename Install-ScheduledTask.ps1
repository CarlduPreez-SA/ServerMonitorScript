#Requires -Version 5.1
<#
Registers (or re-registers) a Windows Scheduled Task that runs Monitor-Server.ps1
at startup as SYSTEM, restarting it automatically if it ever stops. Running as
SYSTEM also avoids a silent under-reporting bug: Get-Process can't read .CPU
for processes owned by other users without elevation, so an interactive,
non-elevated task undercounts CPU on a multi-user box.

Pass -RunAsUser for desktop/dev use: runs at logon under the current
interactive user instead of SYSTEM (no elevation required, no cross-user
process visibility).

Re-run this script any time after editing Monitor-Server.ps1 or moving it, to
refresh the task.
#>

[CmdletBinding()]
param(
    [string]$TaskName = 'ServerMonitorScript',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Monitor-Server.ps1'),
    [switch]$RunAsUser
)

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Monitor script not found at '$ScriptPath'."
}

if (-not $RunAsUser) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Registering the SYSTEM-mode scheduled task requires an elevated (Run as Administrator) PowerShell session. Either re-run elevated, or pass -RunAsUser to install the desktop/dev variant under the current user instead."
    }
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Information "Existing task '$TaskName' found. Unregistering before re-creating." -InformationAction Continue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

if ($RunAsUser) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $modeDescription = "at logon as $env:USERNAME (desktop/dev mode)"
}
else {
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $modeDescription = 'at startup as SYSTEM (service mode)'
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Continuously logs system and per-process CPU/RAM usage to CSV.' | Out-Null

Write-Information "Scheduled task '$TaskName' registered to run $modeDescription." -InformationAction Continue
Write-Information "Start it now with: Start-ScheduledTask -TaskName '$TaskName'" -InformationAction Continue
