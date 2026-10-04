#Requires -Version 5.1
<#
.SYNOPSIS
    MVP 扫描器的公共基础设施：输出、日志、文件体积测量、系统探测。

.DESCRIPTION
    本文件只提供"读"能力，不含任何修改系统的代码。所有扫描模块都依赖这里定义的
    两个契约：

    1. 日志与输出
       Write-ScanLog -Level Info|Warn|Error -Message <string>
       Write-Headline <string>          # 章节标题
       Write-Item <string>              # 列表项
       Write-Note <string>              # 补充说明（灰色）

    2. Finding 对象（所有扫描模块的返回单元）
       [pscustomobject]@{
           Id       = 'disk.low-space'      # 全局唯一，格式 <module>.<slug>
           Module   = 'disk'
           Severity = 'Critical'|'High'|'Medium'|'Low'|'Info'
           Title    = 'C 盘只剩 13.5%'       # 一句话结论
           Detail   = '...'                 # 白话解释，必须带本机实测数据
           Evidence = [ordered]@{}          # 键值对，报告里原样展示
           Advice   = '...'                 # 建议做什么（本工具不会代做）
       }

     约束：无问题时**返回空数组**，不要返回 $null（铁律：空集合解包）。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    错误处理：任何失败都要记录并计数，不允许静默吞掉（铁律 L2）。
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# 会话级状态
# ---------------------------------------------------------------------------
$script:ScanLogPath = $null
$script:ScanSkippedCount = 0
$script:ScanWarningCount = 0

function Initialize-ScanEnvironment {
    <#
    .SYNOPSIS
        准备控制台编码、日志目录与日志文件。返回日志文件路径。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseDirectory)

    try {
        $null = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    } catch {
        # 输出编码设置失败不致命，但必须让用户知道中文可能显示异常
        Write-Warning "无法设置控制台输出编码，中文可能显示为乱码。"
    }

    $logDir = Join-Path $BaseDirectory 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:ScanLogPath = Join-Path $logDir "scan-$stamp.log"
    Write-ScanLog -Level Info -Message "扫描开始，日志写入 $script:ScanLogPath"
    return $script:ScanLogPath
}

function Write-ScanLog {
    <#
    .SYNOPSIS
        写一行日志。同时输出到控制台（可关）与日志文件。
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
        [Parameter(Mandatory)][string]$Message,
        [switch]$Silent
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = '{0} | {1,-5} | {2}' -f $stamp, $Level.ToUpperInvariant(), $Message

    if ($Level -eq 'Warn') { $script:ScanWarningCount++ }

    if ($script:ScanLogPath) {
        try {
            Add-Content -LiteralPath $script:ScanLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # 日志写不进去必须让用户看见，但不能因此中断扫描
            if (-not $Silent) { Write-Host "  ! 日志写入失败：$($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }

    if (-not $Silent) {
        # 有接收器（图形界面）时走接收器，否则按原来的控制台输出
        $sinkText = switch ($Level) {
            'Warn' { "! $Message" }
            'Error' { "x $Message" }
            default { "· $Message" }
        }
        if (-not (Write-SinkMessage -Kind 'Log' -Text $sinkText)) {
            switch ($Level) {
                'Warn' { Write-Host "  ! $Message" -ForegroundColor Yellow }
                'Error' { Write-Host "  x $Message" -ForegroundColor Red }
                default { Write-Host "  · $Message" -ForegroundColor DarkGray }
            }
        }
    }
}

function Get-ScanWarningCount { return $script:ScanWarningCount }
function Get-ScanSkippedCount { return $script:ScanSkippedCount }

# ---------------------------------------------------------------------------
# 输出改道（供图形界面使用）
# ---------------------------------------------------------------------------
# 命令行模式下这些函数直接 Write-Host；图形界面模式下没有控制台可看，
# 所以提供一个"输出接收器"：GUI 注册一个脚本块，输出就会被送到窗口里。
# 不注册接收器时行为与原来完全一致（CLI 不受影响）。
$script:OutputSink = $null

function Set-OutputSink {
    <#
    .SYNOPSIS
        注册输出接收器。传 $null 可恢复默认的控制台输出。
    .PARAMETER Sink
        形如 { param($Kind, $Text) ... } 的脚本块，Kind 为 Headline/Item/Note/Log。
    #>
    [CmdletBinding()]
    param([scriptblock]$Sink)
    $script:OutputSink = $Sink
}

function Get-OutputSink { return $script:OutputSink }

function Write-SinkMessage {
    <#
    .SYNOPSIS
        把一条消息送给接收器（若已注册）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Text
    )

    if ($null -eq $script:OutputSink) { return $false }
    try {
        & $script:OutputSink $Kind $Text
        return $true
    } catch {
        # 接收器坏了不能让扫描崩掉；退回控制台并留痕
        Write-Host "   (界面输出失败，已退回控制台：$($_.Exception.Message))" -ForegroundColor Yellow
        return $false
    }
}

function Write-Headline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    if (Write-SinkMessage -Kind 'Headline' -Text $Text) { return }
    Write-Host ''
    Write-Host "── $Text" -ForegroundColor Cyan
}

function Write-Item {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    if (Write-SinkMessage -Kind 'Item' -Text $Text) { return }
    Write-Host "   $Text"
}

function Write-Note {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    if (Write-SinkMessage -Kind 'Note' -Text $Text) { return }
    Write-Host "     $Text" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 只读测量
# ---------------------------------------------------------------------------
function Get-FolderSize {
    <#
    .SYNOPSIS
        测量目录体积。只读，不删除任何东西。

    .OUTPUTS
        @{ Bytes = int64; FileCount = int; Skipped = int }

    .NOTES
        读不到的文件计入 Skipped 并在日志里留痕，而不是当成 0（铁律 L2）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxSeconds = 20
    )

    $result = @{ Bytes = [int64]0; FileCount = 0; Skipped = 0 }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $result }

    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    try {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Stop)
    } catch {
        $result.Skipped++
        Write-ScanLog -Level Warn -Message "无法枚举目录 $Path：$($_.Exception.Message)"
        return $result
    }

    foreach ($file in $files) {
        if ((Get-Date) -gt $deadline) {
            Write-ScanLog -Level Warn -Message "$Path 体积统计超时（>$MaxSeconds 秒），结果偏低。"
            break
        }
        try {
            $result.Bytes += $file.Length
            $result.FileCount++
        } catch {
            $result.Skipped++
            Write-ScanLog -Level Warn -Message "无法读取文件大小 $($file.FullName)：$($_.Exception.Message)"
            $script:ScanSkippedCount++
        }
    }
    return $result
}

function ConvertTo-SizeText {
    <#
    .SYNOPSIS
        把字节数转成普通人看得懂的大小。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int64]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

# ---------------------------------------------------------------------------
# 环境探测（全部只读）
# ---------------------------------------------------------------------------
function Test-IsAdministrator {
    <#
    .SYNOPSIS
        当前会话是否管理员。
    #>
    [CmdletBinding()]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-ScanLog -Level Warn -Message "无法判断管理员权限：$($_.Exception.Message)"
        return $false
    }
}

function Get-SystemProfile {
    <#
    .SYNOPSIS
        探测本机基本情况：机型、系统版本、内存、CPU、是否管理员、PowerShell 版本。
    #>
    [CmdletBinding()]
    param()

    $profile = [ordered]@{
        IsAdmin         = Test-IsAdministrator
        PowerShell      = $PSVersionTable.PSVersion.ToString()
        OSName          = '未知'
        OSBuild         = '未知'
        OSDisplay       = '未知'
        Model           = '未知'
        Manufacturer    = '未知'
        CpuName         = '未知'
        CpuCores        = 0
        MemoryTotalGB   = 0
        MemoryFreeGB    = 0
        MemoryUsedPct   = 0
        ProbeFailures   = @()
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $profile.OSName = $os.Caption
        $profile.OSBuild = $os.BuildNumber
        $profile.OSDisplay = "$($os.Caption) (build $($os.BuildNumber))"
        $totalKB = [double]$os.TotalVisibleMemorySize
        $freeKB = [double]$os.FreePhysicalMemory
        if ($totalKB -gt 0) {
            $profile.MemoryTotalGB = [math]::Round($totalKB / 1MB, 2)
            $profile.MemoryFreeGB = [math]::Round($freeKB / 1MB, 2)
            $profile.MemoryUsedPct = [math]::Round(100 - ($freeKB / $totalKB * 100), 1)
        }
    } catch {
        $profile.ProbeFailures += "操作系统信息：$($_.Exception.Message)"
    }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $profile.Model = $cs.Model
        $profile.Manufacturer = $cs.Manufacturer
    } catch {
        $profile.ProbeFailures += "机型信息：$($_.Exception.Message)"
    }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $profile.CpuName = $cpu.Name
        $profile.CpuCores = $cpu.NumberOfCores
    } catch {
        $profile.ProbeFailures += "CPU 信息：$($_.Exception.Message)"
    }

    foreach ($failure in $profile.ProbeFailures) {
        Write-ScanLog -Level Warn -Message "探测失败 · $failure"
    }
    return $profile
}

function New-Finding {
    <#
    .SYNOPSIS
        构造一个 Finding 对象（见文件头部契约）。

    .NOTES
        Evidence 用有序字典，保证报告里字段顺序稳定。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Detail,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Evidence,
        [string]$Advice = ''
    )

    return [pscustomobject]@{
        Id       = $Id
        Module   = $Module
        Severity = $Severity
        Title    = $Title
        Detail   = $Detail
        Evidence = $Evidence
        Advice   = $Advice
    }
}

function Get-MachineLabel {
    <#
    .SYNOPSIS
        组合机型显示名，避免出现"Alienware Alienware m15 R3"这种厂商名重复。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Manufacturer,
        [AllowEmptyString()][string]$Model
    )

    $vendor = if ($Manufacturer) { $Manufacturer.Trim() } else { '' }
    $name = if ($Model) { $Model.Trim() } else { '' }

    if ([string]::IsNullOrWhiteSpace($name)) { return $vendor }
    if ([string]::IsNullOrWhiteSpace($vendor)) { return $name }
    if ($name.IndexOf($vendor, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $name }
    return ('{0} {1}' -f $vendor, $name)
}

function Get-SeverityRank {
    <#
    .SYNOPSIS
        严重度排序权重，用于报告排序（越严重越靠前）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Severity)

    switch ($Severity) {
        'Critical' { return 0 }
        'High' { return 1 }
        'Medium' { return 2 }
        'Low' { return 3 }
        default { return 4 }
    }
}

function Get-SeverityLabel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Severity)

    switch ($Severity) {
        'Critical' { return '严重' }
        'High' { return '偏高' }
        'Medium' { return '中等' }
        'Low' { return '轻微' }
        default { return '提示' }
    }
}
