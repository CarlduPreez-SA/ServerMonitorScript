# ServerMonitorScript

PowerShell-based server monitor that continuously samples overall CPU/RAM and
per-process CPU/RAM usage, writing structured rows to a date-rotated CSV file.

## Files

- `Monitor-Server.ps1` — main monitoring loop.
- `settings.json` — configuration (interval, output folder, top-N processes, file prefix).
- `Install-ScheduledTask.ps1` — registers a Windows Scheduled Task to run the monitor at logon.

## Configuration (`settings.json`)

| Field             | Description                                                        | Default        |
|-------------------|----------------------------------------------------------------------|----------------|
| `IntervalSeconds` | Seconds between samples. Re-read every cycle, so edits apply live.  | `15`           |
| `OutputFolder`    | Folder for CSV logs. Relative paths resolve against the script dir. | `.\Logs`       |
| `TopNProcesses`   | Number of top processes by CPU and by RAM logged per sample.        | `10`           |
| `LogFilePrefix`   | Prefix for daily CSV file names (`<Prefix>_yyyy-MM-dd.csv`).         | `ServerMonitor`|
| `RetentionDays`   | Delete CSV files older than this many days on each date rollover. `0` = keep forever. | `14` |

## Running manually

```powershell
.\Monitor-Server.ps1
```

Runs in the foreground; stop with Ctrl+C.

## Running unattended (Scheduled Task)

```powershell
.\Install-ScheduledTask.ps1
Start-ScheduledTask -TaskName 'ServerMonitorScript'
```

Registers a task that starts at logon and restarts automatically if it stops.
Re-run `Install-ScheduledTask.ps1` after moving or editing the script to refresh the task.

## CSV schema

One file per day: `<OutputFolder>\<LogFilePrefix>_yyyy-MM-dd.csv`

```
Timestamp,MetricType,ProcessName,ProcessId,CPUPercent,MemoryMB,MemoryPercent,TotalMemoryMB
```

- **System row** (`MetricType=System`, one per sample): overall `CPUPercent`, used RAM in
  `MemoryMB`, used RAM `MemoryPercent`, and `TotalMemoryMB`. `ProcessName`/`ProcessId` blank.
- **Process row** (`MetricType=Process`, top N by CPU and top N by RAM, de-duplicated):
  `ProcessName`, `ProcessId`, process `CPUPercent` (normalized across all cores, like Task
  Manager), `MemoryMB` (working set), `MemoryPercent` (share of total RAM). `TotalMemoryMB` blank.

Both `CPUPercent` figures (system and process) are computed the same way — a delta over the
sample interval (system: idle-time delta from raw perf counters; process: CPU-seconds delta
from `Get-Process`) — so they're directly comparable. **The first sample after the monitor
starts always reports `0`** for every `CPUPercent`, since there's no prior sample to diff
against.

## Log retention

On each day's first sample, the monitor deletes CSV files older than `RetentionDays` in
`OutputFolder`. Set `RetentionDays` to `0` to keep every file forever. A locked or
otherwise undeletable file is logged and skipped rather than stopping the monitor.
