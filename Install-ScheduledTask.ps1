<#
Registers (or re-registers) a Windows Scheduled Task that runs Monitor-Server.ps1
at logon, restarting it automatically if it ever stops. Re-run this script any
time after editing Monitor-Server.ps1 or its location to refresh the task.
#>

param(
    [string]$TaskName = 'ServerMonitorScript',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Monitor-Server.ps1')
)

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Monitor script not found at '$ScriptPath'."
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Existing task '$TaskName' found. Unregistering before re-creating."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Continuously logs system and per-process CPU/RAM usage to CSV.' | Out-Null

Write-Host "Scheduled task '$TaskName' registered to run at logon for $env:USERNAME."
Write-Host "Start it now with: Start-ScheduledTask -TaskName '$TaskName'"
