# ServerMonitorScript

PowerShell-based server monitor that continuously samples overall CPU/RAM and
per-process CPU/RAM usage, writing structured rows to a date-rotated CSV file.

## Files

- `Monitor-Server.ps1` — main monitoring loop.
- `ServerMonitor.Common.ps1` — pure logic (CSV escaping, settings validation, CPU-percent
  math, process identity keys, log-retention selection), dot-sourced by the monitor and
  covered by `ServerMonitor.Common.Tests.ps1`.
- `settings.json` — configuration (interval, output folder, top-N processes, retention,
  alert thresholds).
- `Install-ScheduledTask.ps1` — registers a Windows Scheduled Task to run the monitor.
- `PSScriptAnalyzerSettings.psd1` — lint rule overrides, used locally and in CI.
- `.github/workflows/lint.yml` — runs PSScriptAnalyzer and Pester on every push/PR.

## Configuration (`settings.json`)

| Field                | Description                                                          | Default        |
|----------------------|------------------------------------------------------------------------|----------------|
| `IntervalSeconds`    | Target seconds between samples. Re-read every cycle, so edits apply live. | `15`        |
| `OutputFolder`       | Folder for CSV/log files. Relative paths resolve against the script dir. | `.\Logs`    |
| `TopNProcesses`      | Number of top processes by CPU and by RAM logged per sample (max 200).| `10`           |
| `LogFilePrefix`      | Prefix for daily CSV/log file names (`<Prefix>_yyyy-MM-dd.csv`).      | `ServerMonitor`|
| `RetentionDays`      | Delete CSV files older than this many days on each date rollover. `0` = keep forever. | `14` |
| `CpuAlertPercent`    | System CPU% threshold. `null` disables. See Alerting below.          | `null`         |
| `MemoryAlertPercent` | System memory% threshold. `null` disables.                           | `null`         |

Invalid values (wrong type, out of range) are ignored with a warning and the field falls
back to its default — the monitor never fails to start over a bad config value.

## Running manually

```powershell
.\Monitor-Server.ps1
```

Runs in the foreground; stop with Ctrl+C. A `Global\ServerMonitorScript` mutex prevents
two instances (e.g. a manual run and the scheduled task) from writing to the same CSV at
once — the second instance logs an error and exits immediately.

## Running unattended (Scheduled Task)

```powershell
# Service mode (default): runs at startup as SYSTEM. Requires an elevated prompt.
.\Install-ScheduledTask.ps1
Start-ScheduledTask -TaskName 'ServerMonitorScript'

# Desktop/dev mode: runs at logon as the current interactive user. No elevation needed.
.\Install-ScheduledTask.ps1 -RunAsUser
```

Running as SYSTEM isn't just about surviving before/without a logon — `Get-Process` can't
read `.CPU` for processes owned by other users unless the caller is elevated, so an
interactive, non-admin task silently under-reports CPU on a multi-user or RDP box. SYSTEM
mode avoids that. The registered task restarts automatically on failure and refuses a
second concurrent instance (`-MultipleInstances IgnoreNew`).

Re-run `Install-ScheduledTask.ps1` after moving or editing the script to refresh the task.

## CSV schema

One file per day: `<OutputFolder>\<LogFilePrefix>_yyyy-MM-dd.csv`

```
Timestamp,MetricType,ProcessName,ProcessId,CPUPercent,MemoryMB,MemoryPercent,TotalMemoryMB
```

- **System row** (`MetricType=System`, one per sample): overall `CPUPercent`, used RAM in
  `MemoryMB`, used RAM `MemoryPercent`, and `TotalMemoryMB`. `ProcessName`/`ProcessId` blank.
- **Process row** (`MetricType=Process`, top N by CPU and top N by RAM, de-duplicated):
  `ProcessName`, `ProcessId`, process `CPUPercent`, `MemoryMB` (working set), `MemoryPercent`
  (share of total RAM). `TotalMemoryMB` blank.

Both `CPUPercent` figures (system and process) are computed the same way — a delta over the
sample interval (system: idle-time delta from raw perf counters; process: CPU-seconds delta
from `Get-Process`) — so they're directly comparable. **The first sample after the monitor
starts always reports `0`** for every `CPUPercent`, since there's no prior sample to diff
against.

Process identity for the CPU delta is tracked by PID *and* start time, not PID alone, so a
recycled PID between samples doesn't get matched against a stale baseline and produce a
phantom spike.

A `<OutputFolder>\<LogFilePrefix>.log` file also accumulates warnings/errors (config
problems, failed cycles, retention deletions, alert breaches) — useful since the scheduled
task runs with a hidden window and nothing goes to a visible console. Unlike the dated
CSVs, this file has no natural rollover, so it's size-capped instead: once it reaches 5 MB
it's rolled to `<LogFilePrefix>.log.1` (one prior copy kept) and a fresh file started.

## Log retention

On each day's first sample, the monitor deletes CSV files older than `RetentionDays` in
`OutputFolder`. Set `RetentionDays` to `0` to keep every file forever. A locked or
otherwise undeletable file is logged and skipped rather than stopping the monitor.

## Alerting

Set `CpuAlertPercent` and/or `MemoryAlertPercent` (0–100) to get a warning-level entry in
the Windows **Application** event log (source `ServerMonitorScript`, event ID `1001` for
CPU / `1002` for memory) when the corresponding metric stays at or above the threshold for
3 consecutive samples, and a matching information-level "recovered" entry (event ID `1003`
CPU / `1004` memory) the next time it drops back below threshold. Each fires exactly once
per breach — not a fire-every-cycle alarm, and not a substitute for real alerting/paging —
see "When not to use this" below.

Creating the event log source requires admin rights once; if that fails (e.g. desktop mode,
non-elevated), alerts still land in `<LogFilePrefix>.log` but skip the event log.

## Failure handling

A failed sample cycle (WMI hiccup, transient error) is logged and the loop continues. After
10 consecutive failed cycles, the monitor logs a terminal error and exits non-zero, so a
scheduled task's restart policy takes over instead of spinning silently forever.

## Development

```powershell
# Lint
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Tests
Invoke-Pester -Path .\ServerMonitor.Common.Tests.ps1
```

Both run in CI on every push/PR (`.github/workflows/lint.yml`).

## When not to use this

This is a single-server, local-file tool by design — no remote shipping, no database, no
dashboard. If you need any of the following, reach for a purpose-built tool instead:

- **Fleet-wide monitoring / dashboards** — [windows_exporter](https://github.com/prometheus-community/windows_exporter)
  + Prometheus + Grafana.
- **Cloud-native / Azure infrastructure** — Azure Monitor / VM insights.
- **Real alerting (paging, escalation, on-call)** — the event-log entries here are a
  starting point, not a replacement for an actual alerting pipeline.

## A note on the data

The CSVs contain process names, which can reveal internal application or service names.
Sanitize or redact before sharing a log file outside your organization.
