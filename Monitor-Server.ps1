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

# Tracks previous per-process CPU-seconds so CPU% can be computed as a delta over the sample interval.
$script:PreviousProcessCpu = @{}
$script:PreviousSampleTime = $null

function Get-SystemSample {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $totalMemMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 2)
    $freeMemMB = [math]::Round($os.FreePhysicalMemory / 1KB, 2)
    $usedMemMB = [math]::Round($totalMemMB - $freeMemMB, 2)
    $usedMemPct = if ($totalMemMB -gt 0) { [math]::Round(($usedMemMB / $totalMemMB) * 100, 2) } else { 0 }

    $cpuCounter = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    $cpuPct = [math]::Round($cpuCounter.PercentProcessorTime, 2)

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
        $cpuSeconds = $proc.CPU
        $currentCpu[$proc.Id] = $cpuSeconds

        $cpuPercent = 0
        if ($elapsedSeconds -and $elapsedSeconds -gt 0 -and $null -ne $cpuSeconds -and $script:PreviousProcessCpu.ContainsKey($proc.Id)) {
            $deltaCpu = $cpuSeconds - $script:PreviousProcessCpu[$proc.Id]
            if ($deltaCpu -lt 0) { $deltaCpu = 0 }
            $cpuPercent = [math]::Round(($deltaCpu / $elapsedSeconds / $processorCount) * 100, 2)
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

while ($true) {
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

    Start-Sleep -Seconds ([int]$settings.IntervalSeconds)
}
