<#
Continuously samples system-wide CPU/RAM and per-process CPU/RAM usage,
writing structured rows to a date-rotated CSV file. Configuration is
read from settings.json (next to this script) and re-read every cycle
so changes (e.g. IntervalSeconds) take effect without a restart.
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'settings.json')
)

. (Join-Path $PSScriptRoot 'ServerMonitor.Common.ps1')

function Get-Settings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Config file not found at '$Path'. Using default settings."
        return (Get-DefaultSettings)
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $validated = ConvertTo-ValidatedSettings -RawSettings $raw
        foreach ($w in $validated.Warnings) {
            Write-Warning "Config: $w"
        }
        return $validated.Settings
    }
    catch {
        Write-Warning "Failed to parse config file '$Path': $_. Using default settings."
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

function Get-CurrentLogFile {
    param(
        [string]$OutputFolderResolved,
        [string]$LogFilePrefix
    )

    $dateStamp = Get-Date -Format 'yyyy-MM-dd'
    $fileName = "${LogFilePrefix}_${dateStamp}.csv"
    $filePath = Join-Path $OutputFolderResolved $fileName

    if (-not (Test-Path -LiteralPath $filePath)) {
        Set-Content -LiteralPath $filePath -Value $CsvHeader -Encoding UTF8
    }

    return $filePath
}

# Tracks previous per-process CPU-seconds, and previous system idle/timestamp
# raw counters, so CPU% can be computed as a delta over the sample interval.
$script:PreviousProcessCpu = @{}
$script:PreviousSystemRaw = $null
$script:PreviousSampleTime = $null

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

Write-Host "Server monitor starting. Config: $ConfigPath"

$stopwatch = [System.Diagnostics.Stopwatch]::new()

while ($true) {
    $stopwatch.Restart()

    try {
        $settings = Get-Settings -Path $ConfigPath
        $outputFolder = Resolve-OutputFolder -OutputFolder $settings.OutputFolder
        $logFile = Get-CurrentLogFile -OutputFolderResolved $outputFolder -LogFilePrefix $settings.LogFilePrefix

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
    }
    catch {
        Write-Warning "Sample cycle failed: $_"
    }

    # Sleep only what's left of the interval after the cycle's own work, so the
    # real cadence is IntervalSeconds rather than IntervalSeconds + execution time.
    $elapsed = $stopwatch.Elapsed.TotalSeconds
    $intervalSeconds = if ($settings) { [int]$settings.IntervalSeconds } else { 15 }
    $remaining = $intervalSeconds - $elapsed

    if ($remaining -le 0) {
        Write-Warning "Sample cycle took ${elapsed}s, longer than the ${intervalSeconds}s interval; sampling immediately."
    }
    else {
        Start-Sleep -Seconds $remaining
    }
}
