#Requires -Version 5.1
<#
Pure/testable logic shared by Monitor-Server.ps1: CSV field escaping, settings
validation/clamping, CPU-percent math, process identity keys, and log-retention
selection. Dot-source this file rather than running it directly.
#>

function ConvertTo-CsvField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        $Value
    )

    if ($null -eq $Value) { return '' }
    $text = "$Value"
    if ($text -match '[",\r\n]') {
        return '"' + ($text -replace '"', '""') + '"'
    }
    return $text
}

function ConvertTo-CsvLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object[]]$Fields)

    ($Fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ','
}

function Get-DefaultSettings {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        IntervalSeconds    = 15
        OutputFolder       = '.\Logs'
        TopNProcesses      = 10
        LogFilePrefix      = 'ServerMonitor'
        RetentionDays      = 14
        CpuAlertPercent    = $null
        MemoryAlertPercent = $null
    }
}

function ConvertTo-ValidatedSettings {
    <#
    Merges raw parsed-JSON settings over the defaults, coercing and clamping
    each field. Never throws on bad input - invalid values fall back to the
    default and are reported in Warnings so the caller can log them.
    #>
    [CmdletBinding()]
    param([AllowNull()]$RawSettings)

    $defaults = Get-DefaultSettings
    $result = [pscustomobject]@{
        IntervalSeconds    = $defaults.IntervalSeconds
        OutputFolder       = $defaults.OutputFolder
        TopNProcesses      = $defaults.TopNProcesses
        LogFilePrefix      = $defaults.LogFilePrefix
        RetentionDays      = $defaults.RetentionDays
        CpuAlertPercent    = $defaults.CpuAlertPercent
        MemoryAlertPercent = $defaults.MemoryAlertPercent
    }
    $warnings = New-Object System.Collections.Generic.List[string]

    if (-not $RawSettings) {
        return [pscustomobject]@{ Settings = $result; Warnings = @($warnings) }
    }

    $names = $RawSettings.PSObject.Properties.Name

    if ($names -contains 'IntervalSeconds') {
        $parsed = 0
        if ([int]::TryParse("$($RawSettings.IntervalSeconds)", [ref]$parsed) -and $parsed -ge 1) {
            $result.IntervalSeconds = $parsed
        }
        else {
            $warnings.Add("IntervalSeconds '$($RawSettings.IntervalSeconds)' invalid (must be integer >= 1); using default $($defaults.IntervalSeconds).")
        }
    }

    if ($names -contains 'OutputFolder') {
        $v = "$($RawSettings.OutputFolder)".Trim()
        if ($v) { $result.OutputFolder = $v }
        else { $warnings.Add("OutputFolder was empty; using default '$($defaults.OutputFolder)'.") }
    }

    if ($names -contains 'TopNProcesses') {
        $parsed = 0
        if ([int]::TryParse("$($RawSettings.TopNProcesses)", [ref]$parsed) -and $parsed -ge 1) {
            if ($parsed -gt 200) {
                $warnings.Add("TopNProcesses $parsed exceeds max 200; clamped to 200.")
                $parsed = 200
            }
            $result.TopNProcesses = $parsed
        }
        else {
            $warnings.Add("TopNProcesses '$($RawSettings.TopNProcesses)' invalid (must be integer >= 1); using default $($defaults.TopNProcesses).")
        }
    }

    if ($names -contains 'LogFilePrefix') {
        $v = "$($RawSettings.LogFilePrefix)"
        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        $cleaned = -join ($v.ToCharArray() | Where-Object { $invalidChars -notcontains $_ })
        $cleaned = $cleaned.Trim()
        if ($cleaned) {
            if ($cleaned -ne $v) {
                $warnings.Add("LogFilePrefix '$v' contained invalid filename characters; sanitized to '$cleaned'.")
            }
            $result.LogFilePrefix = $cleaned
        }
        else {
            $warnings.Add("LogFilePrefix '$v' had no valid characters left after sanitizing; using default '$($defaults.LogFilePrefix)'.")
        }
    }

    if ($names -contains 'RetentionDays') {
        $parsed = 0
        if ([int]::TryParse("$($RawSettings.RetentionDays)", [ref]$parsed) -and $parsed -ge 0) {
            $result.RetentionDays = $parsed
        }
        else {
            $warnings.Add("RetentionDays '$($RawSettings.RetentionDays)' invalid (must be integer >= 0); using default $($defaults.RetentionDays).")
        }
    }

    foreach ($alertField in @('CpuAlertPercent', 'MemoryAlertPercent')) {
        if ($names -contains $alertField) {
            $raw = $RawSettings.$alertField
            if ($null -eq $raw -or "$raw" -eq '') {
                $result.$alertField = $null
            }
            else {
                $parsed = 0.0
                if ([double]::TryParse("$raw", [ref]$parsed) -and $parsed -gt 0 -and $parsed -le 100) {
                    $result.$alertField = $parsed
                }
                else {
                    $warnings.Add("$alertField '$raw' invalid (must be > 0 and <= 100, or null to disable); alerting disabled for this metric.")
                    $result.$alertField = $null
                }
            }
        }
    }

    return [pscustomobject]@{ Settings = $result; Warnings = @($warnings) }
}

function Get-ProcessCpuPercent {
    <#
    Normalizes a CPU-seconds delta over the sample interval into a
    Task-Manager-style percent (0-100 across all cores combined).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$PreviousCpuSeconds,
        [Parameter(Mandatory)][double]$CurrentCpuSeconds,
        [Parameter(Mandatory)][double]$ElapsedSeconds,
        [Parameter(Mandatory)][int]$ProcessorCount
    )

    if ($ElapsedSeconds -le 0 -or $ProcessorCount -le 0) { return 0 }

    $delta = $CurrentCpuSeconds - $PreviousCpuSeconds
    if ($delta -lt 0) { $delta = 0 }

    [math]::Round(($delta / $ElapsedSeconds / $ProcessorCount) * 100, 2)
}

function Get-SystemCpuPercentFromRaw {
    <#
    Computes overall CPU% from two Win32_PerfRawData_PerfOS_Processor
    ('_Total') samples, using the same idle-time-delta method the process
    calc uses so the two numbers are directly comparable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$PreviousIdle,
        [Parameter(Mandatory)][double]$CurrentIdle,
        [Parameter(Mandatory)][double]$PreviousTimestamp,
        [Parameter(Mandatory)][double]$CurrentTimestamp
    )

    $deltaTimestamp = $CurrentTimestamp - $PreviousTimestamp
    if ($deltaTimestamp -le 0) { return 0 }

    $deltaIdle = $CurrentIdle - $PreviousIdle
    if ($deltaIdle -lt 0) { $deltaIdle = 0 }

    $pct = 100 - (($deltaIdle / $deltaTimestamp) * 100)
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }

    [math]::Round($pct, 2)
}

function Get-ProcessSampleKey {
    <#
    Identifies a process instance (not just a PID) so a recycled PID between
    samples doesn't get matched against a stale CPU baseline. $StartTimeTicks
    should be $null when StartTime couldn't be read (e.g. Idle/System/protected
    processes) - the caller should skip CPU-delta tracking for those.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [AllowNull()][Nullable[long]]$StartTimeTicks
    )

    if ($null -eq $StartTimeTicks) { return "$ProcessId|unknown" }
    return "$ProcessId|$StartTimeTicks"
}

function Get-LogFilesToPurge {
    <#
    Selects log files older than RetentionDays for deletion. RetentionDays -le 0
    means "keep forever" (returns nothing). Caller performs the actual delete.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Files,
        [Parameter(Mandatory)][int]$RetentionDays,
        [Parameter(Mandatory)][datetime]$Now
    )

    if ($RetentionDays -le 0 -or -not $Files) { return @() }

    $cutoff = $Now.AddDays(-$RetentionDays)
    @($Files | Where-Object { $_.LastWriteTime -lt $cutoff })
}
