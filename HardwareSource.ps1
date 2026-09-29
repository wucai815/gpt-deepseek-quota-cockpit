$script:hardwareStaticInfo = $null

function New-HardwareMonitor {
    $library = Join-Path $PSScriptRoot 'vendor\LibreHardwareMonitor\lib\LibreHardwareMonitorLib.dll'
    if (-not (Test-Path -LiteralPath $library -PathType Leaf)) { return $null }
    try {
        [void][Reflection.Assembly]::LoadFrom($library)
        $computer = [LibreHardwareMonitor.Hardware.Computer]::new()
        $computer.IsCpuEnabled = $true
        $computer.IsGpuEnabled = $true
        $computer.IsMemoryEnabled = $true
        $computer.IsMotherboardEnabled = $false
        $computer.IsStorageEnabled = $false
        $computer.IsControllerEnabled = $false
        $computer.IsNetworkEnabled = $false
        $computer.Open()
        return $computer
    } catch {
        return $null
    }
}

function Close-HardwareMonitor($Computer) {
    if ($null -eq $Computer) { return }
    try { $Computer.Close() } catch { }
}

function Add-HardwareTreeSensors($Hardware, $Records) {
    try { $Hardware.Update() } catch { }
    foreach ($sensor in @($Hardware.Sensors)) {
        if ($null -ne $sensor.Value) {
            [void]$Records.Add([pscustomobject]@{
                deviceType = $Hardware.HardwareType.ToString()
                deviceName = [string]$Hardware.Name
                sensorType = $sensor.SensorType.ToString()
                name = [string]$sensor.Name
                value = [double]$sensor.Value
            })
        }
    }
    foreach ($child in @($Hardware.SubHardware)) { Add-HardwareTreeSensors $child $Records }
}

function Find-HardwareValue {
    param(
        [object[]]$Records,
        [string]$DeviceTypePattern,
        [string]$SensorType,
        [string[]]$Names,
        [switch]$Maximum
    )
    $candidates = @($Records | Where-Object { $_.deviceType -match $DeviceTypePattern -and $_.sensorType -eq $SensorType })
    foreach ($name in $Names) {
        $match = $candidates | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($null -ne $match) { return [double]$match.value }
    }
    if ($Maximum -and $candidates.Count -gt 0) {
        return [double](($candidates | Measure-Object value -Maximum).Maximum)
    }
    return $null
}

function Get-HardwareStaticInfo {
    if ($script:hardwareStaticInfo) { return $script:hardwareStaticInfo }
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Oray|Remote|Virtual|Basic Display' } |
        Sort-Object AdapterRAM -Descending | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpuLabel = if ($cpu.Name) { [string]$cpu.Name } else { 'CPU' }
    $cpuLabel = ($cpuLabel -replace '\(R\)|\(TM\)', '' -replace '^\s*\d+(th|rd|nd|st) Gen\s*', '' -replace '^Intel\s+Core\s+', '' -replace '\s+', ' ').Trim()
    $script:hardwareStaticInfo = [pscustomobject]@{
        cpuName = $cpuLabel
        cpuCores = [int]$cpu.NumberOfCores
        cpuThreads = [int]$cpu.NumberOfLogicalProcessors
        cpuMaxClockGHz = if ($cpu.MaxClockSpeed) { [math]::Round(([double]$cpu.MaxClockSpeed / 1000), 1) } else { $null }
        gpuName = if ($gpu.Name) { ([string]$gpu.Name -replace '^NVIDIA GeForce\s*', 'RTX ').Trim() -replace '^RTX RTX ', 'RTX ' } else { 'GPU' }
        memoryTotalGb = if ($os.TotalVisibleMemorySize) { [math]::Round(([double]$os.TotalVisibleMemorySize / 1MB), 1) } else { $null }
    }
    return $script:hardwareStaticInfo
}

function Get-NvidiaFallback {
    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    try {
        $line = & $command.Source '--query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,fan.speed' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
        if (-not $line) { return $null }
        $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
        if ($parts.Count -lt 7) { return $null }
        return [pscustomobject]@{
            name = $parts[0]
            usage = [double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
            temperature = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
            memoryUsedGb = [math]::Round(([double]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture) / 1024), 1)
            memoryTotalGb = [math]::Round(([double]::Parse($parts[4], [Globalization.CultureInfo]::InvariantCulture) / 1024), 1)
            powerWatts = [math]::Round([double]::Parse($parts[5], [Globalization.CultureInfo]::InvariantCulture), 0)
            fanPercent = [math]::Round([double]::Parse($parts[6], [Globalization.CultureInfo]::InvariantCulture), 0)
        }
    } catch { return $null }
}

function Get-HardwareSnapshot($Computer) {
    $static = Get-HardwareStaticInfo
    $records = [Collections.Generic.List[object]]::new()
    if ($Computer) {
        foreach ($hardware in @($Computer.Hardware)) { Add-HardwareTreeSensors $hardware $records }
    }
    $all = @($records)

    $cpuUsage = Find-HardwareValue $all '^Cpu$' 'Load' @('CPU Total')
    $cpuTemperature = Find-HardwareValue $all '^Cpu$' 'Temperature' @('CPU Package','Core Max')
    if ($null -eq $cpuTemperature) {
        $cpuTemps = @($all | Where-Object { $_.deviceType -eq 'Cpu' -and $_.sensorType -eq 'Temperature' -and $_.name -notmatch 'Distance' })
        if ($cpuTemps.Count -gt 0) { $cpuTemperature = [double](($cpuTemps | Measure-Object value -Maximum).Maximum) }
    }
    $cpuClocks = @($all | Where-Object { $_.deviceType -eq 'Cpu' -and $_.sensorType -eq 'Clock' -and $_.name -match '^CPU Core' })
    $cpuClockGHz = if ($cpuClocks.Count -gt 0) { [math]::Round((($cpuClocks | Measure-Object value -Average).Average / 1000), 1) } else { $static.cpuMaxClockGHz }
    if ($null -eq $cpuUsage) {
        $perf = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        if ($perf) { $cpuUsage = if ($null -ne $perf.PercentProcessorUtility) { [double]$perf.PercentProcessorUtility } else { [double]$perf.PercentProcessorTime } }
    }

    $ramUsage = Find-HardwareValue $all '^Memory$' 'Load' @('Memory')
    $ramUsed = Find-HardwareValue ($all | Where-Object { $_.deviceName -eq 'Total Memory' }) '^Memory$' 'Data' @('Memory Used')
    $ramAvailable = Find-HardwareValue ($all | Where-Object { $_.deviceName -eq 'Total Memory' }) '^Memory$' 'Data' @('Memory Available')
    $ramTotal = if ($null -ne $ramUsed -and $null -ne $ramAvailable) { $ramUsed + $ramAvailable } else { $static.memoryTotalGb }
    if ($null -eq $ramUsage -or $null -eq $ramUsed) {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os.TotalVisibleMemorySize) {
            $ramTotal = [double]$os.TotalVisibleMemorySize / 1MB
            $ramAvailable = [double]$os.FreePhysicalMemory / 1MB
            $ramUsed = $ramTotal - $ramAvailable
            $ramUsage = 100 * $ramUsed / $ramTotal
        }
    }

    $gpuRecords = @($all | Where-Object { $_.deviceType -match '^Gpu' })
    $gpuName = ($gpuRecords | Select-Object -First 1).deviceName
    $gpuUsage = Find-HardwareValue $gpuRecords '^Gpu' 'Load' @('GPU Core')
    $gpuTemperature = Find-HardwareValue $gpuRecords '^Gpu' 'Temperature' @('GPU Core')
    $gpuMemoryUsed = Find-HardwareValue $gpuRecords '^Gpu' 'SmallData' @('GPU Memory Used')
    $gpuMemoryTotal = Find-HardwareValue $gpuRecords '^Gpu' 'SmallData' @('GPU Memory Total')
    $gpuPower = Find-HardwareValue $gpuRecords '^Gpu' 'Power' @('GPU Package')
    $gpuFanRpm = Find-HardwareValue $gpuRecords '^Gpu' 'Fan' @('GPU Fan')
    $nvidia = $null
    if (-not $gpuName -or $null -eq $gpuUsage -or $null -eq $gpuTemperature -or $null -eq $gpuMemoryUsed -or $null -eq $gpuMemoryTotal -or $null -eq $gpuPower) {
        $nvidia = Get-NvidiaFallback
    }
    if ($nvidia) {
        if (-not $gpuName) { $gpuName = $nvidia.name }
        if ($null -eq $gpuUsage) { $gpuUsage = $nvidia.usage }
        if ($null -eq $gpuTemperature) { $gpuTemperature = $nvidia.temperature }
        if ($null -eq $gpuMemoryUsed) { $gpuMemoryUsed = $nvidia.memoryUsedGb * 1024 }
        if ($null -eq $gpuMemoryTotal) { $gpuMemoryTotal = $nvidia.memoryTotalGb * 1024 }
        if ($null -eq $gpuPower) { $gpuPower = $nvidia.powerWatts }
    }

    [pscustomobject]@{
        fetchedAt = [DateTimeOffset]::UtcNow
        cpu = [pscustomobject]@{
            name = $static.cpuName; cores = $static.cpuCores; threads = $static.cpuThreads
            usage = if ($null -eq $cpuUsage) { $null } else { [math]::Round([math]::Max(0,[math]::Min(100,$cpuUsage)),0) }
            temperature = if ($null -eq $cpuTemperature) { $null } else { [math]::Round($cpuTemperature,0) }
            clockGHz = $cpuClockGHz
        }
        gpu = [pscustomobject]@{
            name = if ($gpuName) { ([string]$gpuName -replace '^NVIDIA GeForce\s*','').Trim() } else { $static.gpuName }
            usage = if ($null -eq $gpuUsage) { $null } else { [math]::Round([math]::Max(0,[math]::Min(100,$gpuUsage)),0) }
            temperature = if ($null -eq $gpuTemperature) { $null } else { [math]::Round($gpuTemperature,0) }
            memoryUsedGb = if ($null -eq $gpuMemoryUsed) { $null } else { [math]::Round(($gpuMemoryUsed / 1024),1) }
            memoryTotalGb = if ($null -eq $gpuMemoryTotal) { $null } else { [math]::Round(($gpuMemoryTotal / 1024),1) }
            powerWatts = if ($null -eq $gpuPower) { $null } else { [math]::Round($gpuPower,0) }
            fanRpm = if ($null -eq $gpuFanRpm) { $null } else { [math]::Round($gpuFanRpm,0) }
        }
        memory = [pscustomobject]@{
            usage = if ($null -eq $ramUsage) { $null } else { [math]::Round([math]::Max(0,[math]::Min(100,$ramUsage)),0) }
            usedGb = if ($null -eq $ramUsed) { $null } else { [math]::Round($ramUsed,1) }
            totalGb = if ($null -eq $ramTotal) { $null } else { [math]::Round($ramTotal,1) }
            availableGb = if ($null -eq $ramAvailable) { $null } else { [math]::Round($ramAvailable,1) }
        }
    }
}
