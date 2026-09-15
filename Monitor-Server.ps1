#Requires -Version 5.1
<#
Continuously samples system-wide CPU/RAM and per-process CPU/RAM usage,
writing structured rows to a date-rotated CSV file. Configuration is
read from settings.json (next to this script) and re-read every cycle
so changes (e.g. IntervalSeconds) take effect without a restart.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'settings.json')
)

. (Join-Path $PSScriptRoot 'ServerMonitor.Common.ps1')

$MaxConsecutiveFailures = 10
$MaxLogFileSizeBytes = 5MB
$AlertSustainedSamples = 3
$EventLogSource = 'ServerMonitorScript'
$EventLogName = 'Application'
$EventIdCpuAlert = 1001
$EventIdMemoryAlert = 1002

$script:LogFilePath = $null

function Write-Log {
    <#
    Logs to both the console and <LogFilePrefix>.log in OutputFolder. The
    console alone isn't enough: the scheduled task runs with a hidden window,
    so Write-Warning/Write-Host never reach anyone unless it's also on disk.
    #>
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )

    $line = "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') [$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Error $Message -ErrorAction Continue }
        'WARN' { Write-Warning $Message }
        default { Write-Information $line -InformationAction Continue }
    }

    if ($script:LogFilePath) {
        try {
            Invoke-LogFileRollover -Path $script:LogFilePath
            Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8
        }
        catch {
            # Best-effort: if the log file itself can't be written, still let the caller proceed.
            Write-Debug "Could not write to log file '$script:LogFilePath': $_"
        }
    }
}

function Invoke-LogFileRollover {
    <#
    Unlike the dated CSVs, the warnings/errors log has no natural retention -
    it's the same file forever. Roll it over once it crosses
    $MaxLogFileSizeBytes, keeping one prior copy (<name>.log.1).
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $size = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if (Test-LogFileRolloverNeeded -SizeBytes $size -ThresholdBytes $MaxLogFileSizeBytes) {
            Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
        }
    }
    catch {
        # Best-effort: a rollover failure shouldn't block logging.
        Write-Debug "Log file rollover failed for '$Path': $_"
    }
}

function New-SingleInstanceMutex {
    <#
    "Global\" makes the mutex apply across all sessions, so a SYSTEM-run
    scheduled task and an interactive run can't both append to the same CSV.
    Creating a Global\ object requires the "Create global objects" privilege,
    which a non-admin interactive user (the -RunAsUser desktop path) may not
    have - fall back to a session-local mutex rather than letting an
    unhandled .NET exception kill the script before anything is logged.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess('ServerMonitorScript', 'Create single-instance mutex')) {
        return $null
    }

    try {
        return New-Object System.Threading.Mutex($false, 'Global\ServerMonitorScript')
    }
    catch {
        Write-Log -Level WARN -Message "Could not create a Global mutex (requires 'Create global objects' rights): $_. Falling back to a session-local mutex, which only guards against another instance in the same session."
    }

    try {
        return New-Object System.Threading.Mutex($false, 'Local\ServerMonitorScript')
    }
    catch {
        Write-Log -Level ERROR -Message "Could not create a single-instance mutex at all: $_. Exiting."
        exit 1
    }
}

function Get-Settings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log -Level WARN -Message "Config file not found at '$Path'. Using default settings."
        return (Get-DefaultSettings)
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $validated = ConvertTo-ValidatedSettings -RawSettings $raw
        foreach ($w in $validated.Warnings) {
            Write-Log -Level WARN -Message "Config: $w"
        }
        return $validated.Settings
    }
    catch {
        Write-Log -Level WARN -Message "Failed to parse config file '$Path': $_. Using default settings."
        return (Get-DefaultSettings)
    }
}

function Resolve-OutputFolder {
    param([string]$OutputFolder)

    $resolved = $OutputFolder
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $resolved = Join-Path $PSScriptRoot $resolved
    }

    if (-not (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    }

    return $resolved
}

$CsvHeader = 'Timestamp,MetricType,ProcessName,ProcessId,CPUPercent,MemoryMB,MemoryPercent,TotalMemoryMB'

$script:CurrentLogDate = $null

function Update-LogFiles {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OutputFolderResolved,
        [string]$LogFilePrefix,
        [int]$RetentionDays
    )

    $today = (Get-Date).Date
    $dateStamp = $today.ToString('yyyy-MM-dd')
    $csvPath = Join-Path $OutputFolderResolved "${LogFilePrefix}_${dateStamp}.csv"
    $script:LogFilePath = Join-Path $OutputFolderResolved "$LogFilePrefix.log"

    if (-not (Test-Path -LiteralPath $csvPath)) {
        if ($PSCmdlet.ShouldProcess($csvPath, 'Create CSV log file with header')) {
            Set-Content -LiteralPath $csvPath -Value $CsvHeader -Encoding UTF8
        }
    }

    # Sweep for retention on the date's first check (including startup, where
    # CurrentLogDate is still $null) and again on each later rollover - not
    # every cycle.
    if (Test-ShouldSweepLogRetention -CurrentLogDate $script:CurrentLogDate -Today $today) {
        Invoke-LogRetention -OutputFolderResolved $OutputFolderResolved -LogFilePrefix $LogFilePrefix -RetentionDays $RetentionDays
        $script:CurrentLogDate = $today
    }

    return $csvPath
}

function Invoke-LogRetention {
    param(
        [string]$OutputFolderResolved,
        [string]$LogFilePrefix,
        [int]$RetentionDays
    )

    if ($RetentionDays -le 0) { return }

    try {
        $pattern = "$LogFilePrefix`_????-??-??.csv"
        $candidates = Get-ChildItem -LiteralPath $OutputFolderResolved -Filter $pattern -File -ErrorAction Stop
        $toDelete = Get-LogFilesToPurge -Files $candidates -RetentionDays $RetentionDays -Now (Get-Date)
        foreach ($file in $toDelete) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-Log -Level INFO -Message "Deleted expired log '$($file.Name)' (older than $RetentionDays days)."
            }
            catch {
                Write-Log -Level WARN -Message "Could not delete expired log '$($file.Name)': $_"
            }
        }
    }
    catch {
        Write-Log -Level WARN -Message "Log retention sweep failed: $_"
    }
}

# Tracks previous per-process CPU-seconds, and previous system idle/timestamp
# raw counters, so CPU% can be computed as a delta over the sample interval.
$script:PreviousProcessCpu = @{}
$script:PreviousSystemRaw = $null
$script:PreviousSampleTime = $null

# Sustained-breach tracking for alerting (avoid firing on a single noisy sample).
$script:ConsecutiveCpuBreaches = 0
$script:ConsecutiveMemoryBreaches = 0
$script:EventLogAvailable = $null

function Test-EventLogAvailable {
    if ($null -ne $script:EventLogAvailable) { return $script:EventLogAvailable }

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventLogSource)) {
            New-EventLog -LogName $EventLogName -Source $EventLogSource -ErrorAction Stop
        }
        $script:EventLogAvailable = $true
    }
    catch {
        Write-Log -Level WARN -Message "Event log source '$EventLogSource' unavailable (requires admin to create once): $_. Alerts will only be written to the log file."
        $script:EventLogAvailable = $false
    }

    return $script:EventLogAvailable
}

function Invoke-AlertCheck {
    <#
    Fires a single warning-level Application event log entry (and log-file
    entry) once CPU or memory has stayed at or above its threshold for
    $AlertSustainedSamples consecutive samples, rather than on every cycle a
    single noisy sample happens to breach it.
    #>
    param(
        [double]$CpuPercent,
        [double]$MemoryPercent,
        [Nullable[double]]$CpuAlertPercent,
        [Nullable[double]]$MemoryAlertPercent
    )

    if ($CpuAlertPercent) {
        if ($CpuPercent -ge $CpuAlertPercent) { $script:ConsecutiveCpuBreaches++ } else { $script:ConsecutiveCpuBreaches = 0 }

        if ($script:ConsecutiveCpuBreaches -eq $AlertSustainedSamples) {
            $msg = "Sustained high CPU: $CpuPercent% over the last $AlertSustainedSamples samples (threshold $CpuAlertPercent%)."
            Write-Log -Level WARN -Message $msg
            if (Test-EventLogAvailable) {
                Write-EventLog -LogName $EventLogName -Source $EventLogSource -EventId $EventIdCpuAlert -EntryType Warning -Message $msg
            }
        }
    }

    if ($MemoryAlertPercent) {
        if ($MemoryPercent -ge $MemoryAlertPercent) { $script:ConsecutiveMemoryBreaches++ } else { $script:ConsecutiveMemoryBreaches = 0 }

        if ($script:ConsecutiveMemoryBreaches -eq $AlertSustainedSamples) {
            $msg = "Sustained high memory: $MemoryPercent% over the last $AlertSustainedSamples samples (threshold $MemoryAlertPercent%)."
            Write-Log -Level WARN -Message $msg
            if (Test-EventLogAvailable) {
                Write-EventLog -LogName $EventLogName -Source $EventLogSource -EventId $EventIdMemoryAlert -EntryType Warning -Message $msg
            }
        }
    }
}

function Get-SystemSample {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $totalMemMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 2)
    $freeMemMB = [math]::Round($os.FreePhysicalMemory / 1KB, 2)
    $usedMemMB = [math]::Round($totalMemMB - $freeMemMB, 2)
    $usedMemPct = if ($totalMemMB -gt 0) { [math]::Round(($usedMemMB / $totalMemMB) * 100, 2) } else { 0 }

    # Raw (not pre-formatted) counters, diffed the same way as per-process CPU,
    # so the two CPUPercent figures in the CSV are directly comparable instead
    # of coming from two different counter families that don't reconcile.
    $raw = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'"

    $cpuPct = 0
    if ($script:PreviousSystemRaw) {
        $cpuPct = Get-SystemCpuPercentFromRaw `
            -PreviousIdle $script:PreviousSystemRaw.PercentIdleTime `
            -CurrentIdle $raw.PercentIdleTime `
            -PreviousTimestamp $script:PreviousSystemRaw.Timestamp_Sys100NS `
            -CurrentTimestamp $raw.Timestamp_Sys100NS
    }
    $script:PreviousSystemRaw = $raw

    [pscustomobject]@{
        CPUPercent      = $cpuPct
        MemoryUsedMB    = $usedMemMB
        MemoryUsedPct   = $usedMemPct
        TotalMemoryMB   = $totalMemMB
    }
}

function Get-TopProcessSamples {
    param(
        [int]$TopN,
        [double]$TotalMemoryMB,
        [datetime]$SampleTime
    )

    $processorCount = [Environment]::ProcessorCount
    $elapsedSeconds = $null
    if ($script:PreviousSampleTime) {
        $elapsedSeconds = ($SampleTime - $script:PreviousSampleTime).TotalSeconds
    }

    $processes = Get-Process -ErrorAction SilentlyContinue
    $currentCpu = @{}
    $samples = foreach ($proc in $processes) {
        # Key CPU tracking by PID *and* start time - PID alone can be recycled
        # between samples, which would diff a new process's CPU-seconds
        # against an unrelated old process's baseline and produce a phantom
        # spike. Idle/System and some protected processes don't expose
        # StartTime; skip CPU-delta tracking for those rather than throwing.
        $startTicks = $null
        try {
            $startTicks = $proc.StartTime.Ticks
        }
        catch {
            # Idle/System and some protected processes don't expose StartTime - skip CPU-delta tracking for them.
            $startTicks = $null
        }
        $key = Get-ProcessSampleKey -ProcessId $proc.Id -StartTimeTicks $startTicks

        $cpuSeconds = $proc.CPU
        if ($null -ne $cpuSeconds) {
            $currentCpu[$key] = $cpuSeconds
        }

        $cpuPercent = 0
        if ($elapsedSeconds -and $elapsedSeconds -gt 0 -and $null -ne $cpuSeconds -and $script:PreviousProcessCpu.ContainsKey($key)) {
            $cpuPercent = Get-ProcessCpuPercent `
                -PreviousCpuSeconds $script:PreviousProcessCpu[$key] `
                -CurrentCpuSeconds $cpuSeconds `
                -ElapsedSeconds $elapsedSeconds `
                -ProcessorCount $processorCount
        }

        $memMB = [math]::Round($proc.WorkingSet64 / 1MB, 2)
        $memPct = if ($TotalMemoryMB -gt 0) { [math]::Round(($memMB / $TotalMemoryMB) * 100, 2) } else { 0 }

        [pscustomobject]@{
            ProcessName = $proc.ProcessName
            ProcessId   = $proc.Id
            CPUPercent  = $cpuPercent
            MemoryMB    = $memMB
            MemoryPercent = $memPct
        }
    }

    $script:PreviousProcessCpu = $currentCpu
    $script:PreviousSampleTime = $SampleTime

    $topByCpu = $samples | Sort-Object -Property CPUPercent -Descending | Select-Object -First $TopN
    $topByMem = $samples | Sort-Object -Property MemoryMB -Descending | Select-Object -First $TopN

    $combined = @{}
    foreach ($s in @($topByCpu) + @($topByMem)) {
        $combined[$s.ProcessId] = $s
    }

    return $combined.Values
}

# Resolve a log destination before doing anything else - including before
# creating the mutex - so every failure from here on (bad config, mutex
# contention, startup) lands on disk instead of only in the scheduled task's
# hidden console. Start from the defaults in case settings.json itself is
# missing or malformed, then switch to the real configured location once
# Get-Settings has resolved it.
$bootDefaults = Get-DefaultSettings
$script:LogFilePath = Join-Path (Resolve-OutputFolder -OutputFolder $bootDefaults.OutputFolder) "$($bootDefaults.LogFilePrefix).log"

$bootSettings = Get-Settings -Path $ConfigPath
$script:LogFilePath = Join-Path (Resolve-OutputFolder -OutputFolder $bootSettings.OutputFolder) "$($bootSettings.LogFilePrefix).log"

$script:Mutex = New-SingleInstanceMutex

try {
    $acquired = $script:Mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    # A previous instance crashed while holding the mutex. We now own it - proceed normally.
    $acquired = $true
}

if (-not $acquired) {
    Write-Log -Level ERROR -Message 'Another instance of Monitor-Server.ps1 is already running (mutex held). Exiting.'
    exit 1
}

try {
    Write-Log -Level INFO -Message "Server monitor starting. Config: $ConfigPath"

    $consecutiveFailures = 0
    $stopwatch = [System.Diagnostics.Stopwatch]::new()

    while ($true) {
        $stopwatch.Restart()

        try {
            $settings = Get-Settings -Path $ConfigPath
            $outputFolder = Resolve-OutputFolder -OutputFolder $settings.OutputFolder
            $logFile = Update-LogFiles -OutputFolderResolved $outputFolder -LogFilePrefix $settings.LogFilePrefix -RetentionDays $settings.RetentionDays

            $sampleTime = Get-Date
            $timestamp = $sampleTime.ToString('yyyy-MM-ddTHH:mm:ss')

            $sysSample = Get-SystemSample
            $topProcesses = Get-TopProcessSamples -TopN ([int]$settings.TopNProcesses) -TotalMemoryMB $sysSample.TotalMemoryMB -SampleTime $sampleTime

            # Batch the cycle's rows into one write instead of opening/closing the
            # file handle once per row.
            $rows = New-Object System.Collections.Generic.List[string]
            $rows.Add((ConvertTo-CsvLine -Fields @(
                $timestamp, 'System', '', '',
                $sysSample.CPUPercent, $sysSample.MemoryUsedMB, $sysSample.MemoryUsedPct, $sysSample.TotalMemoryMB
            )))
            foreach ($p in $topProcesses) {
                $rows.Add((ConvertTo-CsvLine -Fields @(
                    $timestamp, 'Process', $p.ProcessName, $p.ProcessId,
                    $p.CPUPercent, $p.MemoryMB, $p.MemoryPercent, ''
                )))
            }
            Add-Content -LiteralPath $logFile -Value $rows -Encoding UTF8

            Invoke-AlertCheck -CpuPercent $sysSample.CPUPercent -MemoryPercent $sysSample.MemoryUsedPct `
                -CpuAlertPercent $settings.CpuAlertPercent -MemoryAlertPercent $settings.MemoryAlertPercent

            $consecutiveFailures = 0
        }
        catch {
            $consecutiveFailures++
            Write-Log -Level WARN -Message "Sample cycle failed ($consecutiveFailures/$MaxConsecutiveFailures consecutive): $_"

            if ($consecutiveFailures -ge $MaxConsecutiveFailures) {
                Write-Log -Level ERROR -Message "Giving up after $MaxConsecutiveFailures consecutive failed cycles."
                exit 1
            }
        }

        # Sleep only what's left of the interval after the cycle's own work, so the
        # real cadence is IntervalSeconds rather than IntervalSeconds + execution time.
        $elapsed = $stopwatch.Elapsed.TotalSeconds
        $intervalSeconds = if ($settings) { [int]$settings.IntervalSeconds } else { 15 }
        $remaining = $intervalSeconds - $elapsed

        if ($remaining -le 0) {
            Write-Log -Level WARN -Message "Sample cycle took ${elapsed}s, longer than the ${intervalSeconds}s interval; sampling immediately."
        }
        else {
            Start-Sleep -Seconds $remaining
        }
    }
}
finally {
    $script:Mutex.ReleaseMutex()
    $script:Mutex.Dispose()
}
