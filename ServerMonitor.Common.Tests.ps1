#Requires -Version 5.1
<#
Pester tests for ServerMonitor.Common.ps1. Run with: Invoke-Pester (from repo root).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'ServerMonitor.Common.ps1')
}

Describe 'ConvertTo-CsvField' {
    It 'passes plain text through unchanged' {
        ConvertTo-CsvField -Value 'svchost' | Should -Be 'svchost'
    }

    It 'quotes and escapes embedded double quotes' {
        ConvertTo-CsvField -Value 'say "hi"' | Should -Be '"say ""hi"""'
    }

    It 'quotes fields containing a comma' {
        ConvertTo-CsvField -Value 'a,b' | Should -Be '"a,b"'
    }

    It 'quotes fields containing a newline' {
        ConvertTo-CsvField -Value "line1`nline2" | Should -Be "`"line1`nline2`""
    }

    It 'returns an empty string for $null' {
        ConvertTo-CsvField -Value $null | Should -Be ''
    }
}

Describe 'ConvertTo-ValidatedSettings' {
    It 'returns all defaults when given $null' {
        $result = ConvertTo-ValidatedSettings -RawSettings $null
        $result.Settings.IntervalSeconds | Should -Be 15
        $result.Settings.TopNProcesses | Should -Be 10
        $result.Warnings.Count | Should -Be 0
    }

    It 'falls back to the default and warns on a non-numeric IntervalSeconds' {
        $raw = [pscustomobject]@{ IntervalSeconds = 'not-a-number' }
        $result = ConvertTo-ValidatedSettings -RawSettings $raw
        $result.Settings.IntervalSeconds | Should -Be 15
        $result.Warnings.Count | Should -Be 1
    }

    It 'rejects IntervalSeconds below 1' {
        $raw = [pscustomobject]@{ IntervalSeconds = 0 }
        $result = ConvertTo-ValidatedSettings -RawSettings $raw
        $result.Settings.IntervalSeconds | Should -Be 15
        $result.Warnings.Count | Should -Be 1
    }

    It 'clamps TopNProcesses to the 200 maximum' {
        $raw = [pscustomobject]@{ TopNProcesses = 5000 }
        $result = ConvertTo-ValidatedSettings -RawSettings $raw
        $result.Settings.TopNProcesses | Should -Be 200
        $result.Warnings.Count | Should -Be 1
    }

    It 'sanitizes invalid characters out of LogFilePrefix' {
        $raw = [pscustomobject]@{ LogFilePrefix = 'bad:name*' }
        $result = ConvertTo-ValidatedSettings -RawSettings $raw
        $result.Settings.LogFilePrefix | Should -Be 'badname'
        $result.Warnings.Count | Should -Be 1
    }

    It 'accepts a valid CpuAlertPercent' {
        $raw = [pscustomobject]@{ CpuAlertPercent = 90 }
        $result = ConvertTo-ValidatedSettings -RawSettings $raw
        $result.Settings.CpuAlertPercent | Should -Be 90
    }

    It 'disables alerting and warns on an out-of-range CpuAlertPercent' {
        $raw = [pscustomobject]@{ CpuAlertPercent = 150 }
        $result = ConvertTo-ValidatedSettings -RawSettings $raw
        $result.Settings.CpuAlertPercent | Should -Be $null
        $result.Warnings.Count | Should -Be 1
    }

    It 'treats an empty string alert setting as disabled without warning' {
        $raw = [pscustomobject]@{ MemoryAlertPercent = '' }
        $result = ConvertTo-ValidatedSettings -RawSettings $raw
        $result.Settings.MemoryAlertPercent | Should -Be $null
        $result.Warnings.Count | Should -Be 0
    }
}

Describe 'Get-ProcessCpuPercent' {
    It 'computes percent normalized across all cores' {
        # 2 CPU-seconds consumed over 4 wall-seconds on an 8-core box = 6.25%
        Get-ProcessCpuPercent -PreviousCpuSeconds 10 -CurrentCpuSeconds 12 -ElapsedSeconds 4 -ProcessorCount 8 | Should -Be 6.25
    }

    It 'clamps a negative delta (process restarted with lower CPU-seconds) to 0' {
        Get-ProcessCpuPercent -PreviousCpuSeconds 50 -CurrentCpuSeconds 5 -ElapsedSeconds 15 -ProcessorCount 4 | Should -Be 0
    }

    It 'returns 0 when elapsed seconds is 0' {
        Get-ProcessCpuPercent -PreviousCpuSeconds 10 -CurrentCpuSeconds 12 -ElapsedSeconds 0 -ProcessorCount 4 | Should -Be 0
    }
}

Describe 'Get-SystemCpuPercentFromRaw' {
    It 'computes busy percent from an idle-time delta' {
        # 100ns units: total elapsed 1,000,000; idle elapsed 250,000 -> 75% busy
        Get-SystemCpuPercentFromRaw -PreviousIdle 0 -CurrentIdle 250000 -PreviousTimestamp 0 -CurrentTimestamp 1000000 | Should -Be 75
    }

    It 'clamps to 0 when idle delta exceeds timestamp delta' {
        Get-SystemCpuPercentFromRaw -PreviousIdle 0 -CurrentIdle 2000000 -PreviousTimestamp 0 -CurrentTimestamp 1000000 | Should -Be 0
    }

    It 'returns 0 when the timestamp delta is 0 (first sample)' {
        Get-SystemCpuPercentFromRaw -PreviousIdle 0 -CurrentIdle 0 -PreviousTimestamp 0 -CurrentTimestamp 0 | Should -Be 0
    }
}

Describe 'Get-ProcessSampleKey (PID reuse handling)' {
    It 'produces different keys for the same PID with different start times' {
        $key1 = Get-ProcessSampleKey -ProcessId 4242 -StartTimeTicks 1000
        $key2 = Get-ProcessSampleKey -ProcessId 4242 -StartTimeTicks 2000
        $key1 | Should -Not -Be $key2
    }

    It 'produces the same key for the same PID and start time' {
        $key1 = Get-ProcessSampleKey -ProcessId 4242 -StartTimeTicks 1000
        $key2 = Get-ProcessSampleKey -ProcessId 4242 -StartTimeTicks 1000
        $key1 | Should -Be $key2
    }

    It 'falls back to an "unknown" marker when start time is unavailable' {
        Get-ProcessSampleKey -ProcessId 4 -StartTimeTicks $null | Should -Be '4|unknown'
    }
}

Describe 'Test-ShouldSweepLogRetention' {
    It 'is true on the very first check, where CurrentLogDate is $null' {
        Test-ShouldSweepLogRetention -CurrentLogDate $null -Today (Get-Date '2026-09-15') | Should -Be $true
    }

    It 'is false when the date has not changed' {
        $today = Get-Date '2026-09-15'
        Test-ShouldSweepLogRetention -CurrentLogDate $today -Today $today | Should -Be $false
    }

    It 'is true once the date has rolled over' {
        Test-ShouldSweepLogRetention -CurrentLogDate (Get-Date '2026-09-14') -Today (Get-Date '2026-09-15') | Should -Be $true
    }
}

Describe 'Test-LogFileRolloverNeeded' {
    It 'is false when the file is under the threshold' {
        Test-LogFileRolloverNeeded -SizeBytes 1000 -ThresholdBytes 5000 | Should -Be $false
    }

    It 'is true once the file reaches the threshold' {
        Test-LogFileRolloverNeeded -SizeBytes 5000 -ThresholdBytes 5000 | Should -Be $true
    }

    It 'is true once the file exceeds the threshold' {
        Test-LogFileRolloverNeeded -SizeBytes 9000 -ThresholdBytes 5000 | Should -Be $true
    }
}

Describe 'Get-LogFilesToPurge' {
    It 'selects only files older than the retention window' {
        $now = Get-Date '2026-09-15T00:00:00'
        $files = @(
            [pscustomobject]@{ FullName = 'old.csv'; LastWriteTime = $now.AddDays(-20) },
            [pscustomobject]@{ FullName = 'recent.csv'; LastWriteTime = $now.AddDays(-2) }
        )
        $result = Get-LogFilesToPurge -Files $files -RetentionDays 14 -Now $now
        $result.FullName | Should -Be @('old.csv')
    }

    It 'returns nothing when RetentionDays is 0 (keep forever)' {
        $now = Get-Date '2026-09-15T00:00:00'
        $files = @([pscustomobject]@{ FullName = 'ancient.csv'; LastWriteTime = $now.AddYears(-5) })
        $result = Get-LogFilesToPurge -Files $files -RetentionDays 0 -Now $now
        $result.Count | Should -Be 0
    }
}
