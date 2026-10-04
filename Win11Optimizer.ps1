#Requires -Version 5.1
<#
.SYNOPSIS
    Win11-Optimizer MVP —— 一键只读诊断，扫描本机问题并生成中文报告。

.DESCRIPTION
    本工具当前版本只做三件事：只读扫描、用大白话讲清问题、把报告写到文件。
    它不会删除任何文件、不会修改注册表、不会改服务启动类型、不会联网。

    扫描内容：
      · 磁盘：分区剩余空间（含 Windows 的 15% 降速线）、可清理的缓存体积
      · 系统：内存占用、吃内存的进程、厂商常驻服务、开机启动项、安全软件共存、系统还原
      · 电源：当前电源方案、CPU 是否被限频、可持续性任务是否在改回方案

.PARAMETER NoElevate
    不请求管理员权限。默认在需要时会弹出 UAC 提示重新以管理员运行（只有管理员
    才能读到完整的服务与安全软件信息）。

.PARAMETER SkipSlowScan
    跳过较慢的目录体积统计，扫描更快但报告里不会有缓存体积数据。

.PARAMETER OutputDirectory
    报告与日志的输出目录。默认写在脚本所在的 Reports 目录下。

.EXAMPLE
    .\Win11Optimizer.ps1
    以普通权限扫描，需要时提示提权。

.EXAMPLE
    .\Win11Optimizer.ps1 -NoElevate -SkipSlowScan
    以当前权限快速扫描（适合只想先看一眼的情况）。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    错误处理：不允许静默失败（铁律 L2）；所有外部调用带超时或 -PassThru 校验（铁律 L3）。
#>
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$SkipSlowScan,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 0. 自提权：只有管理员才能读到完整的服务与安全软件信息
# ---------------------------------------------------------------------------
function Test-Administrator {
    try {
        $principal = New-Object System.Security.Principal.WindowsPrincipal(
            [System.Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Restart-Elevated {
    <#
    .SYNOPSIS
        以管理员身份重新运行自己。UAC 被拒绝时返回 $false。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath)

    Write-Host '需要管理员权限才能读到完整的服务与安全软件信息，正在请求提权…' -ForegroundColor Yellow
    Write-Host '（弹出的 UAC 窗口请点"是"；如果你不想提权，可加 -NoElevate 参数跳过）' -ForegroundColor DarkGray

    $hostExe = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    if ($SkipSlowScan) { $arguments += '-SkipSlowScan' }

    try {
        $process = Start-Process -FilePath $hostExe -ArgumentList $arguments -Verb RunAs -PassThru -ErrorAction Stop
        if ($null -eq $process) {
            Write-Host '提权进程未能启动。' -ForegroundColor Red
            return $false
        }
        $finished = $process.WaitForExit(600000)
        if (-not $finished) {
            try { $null = $process.Kill() } catch { Write-Host "无法结束超时的提权进程：$($_.Exception.Message)" -ForegroundColor Red }
            Write-Host '提权后的扫描超过 10 分钟仍未结束，已强制终止。' -ForegroundColor Red
            return $false
        }
        return $true
    } catch {
        Write-Host "提权被取消或失败：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '将以普通权限继续，部分信息（服务、安全软件）可能读不全。' -ForegroundColor Yellow
        return $false
    }
}

# ---------------------------------------------------------------------------
# 1. 加载模块
# ---------------------------------------------------------------------------
$script:RootDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:RootDirectory)) {
    $script:RootDirectory = (Get-Location).Path
}

# 注意：必须在**脚本顶层**点源。函数内点源只会把函数定义到该函数的局部作用域，
# 函数一返回就全丢了——这个坑真的踩到过，端到端会以 CommandNotFoundException 终止。
$libDirectory = Join-Path $script:RootDirectory 'lib'
foreach ($moduleName in @('Common.ps1', 'Scan.Disk.ps1', 'Scan.System.ps1', 'Scan.Power.ps1')) {
    $modulePath = Join-Path $libDirectory $moduleName
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        Write-Host ''
        Write-Host "启动失败：缺少模块文件 $modulePath" -ForegroundColor Red
        Write-Host '请确认压缩包已完整解压（不要只复制单个文件出来运行）。' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }
    try {
        . $modulePath
    } catch {
        Write-Host ''
        Write-Host "启动失败：加载 $moduleName 时出错 —— $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        exit 1
    }
}

# 加载后立刻确认关键函数都在，避免带着半截环境往下跑
foreach ($required in @('Initialize-ScanEnvironment', 'Get-SystemProfile', 'New-Finding',
        'Invoke-DiskScan', 'Invoke-SystemScan', 'Invoke-PowerScan')) {
    if (-not (Get-Command -Name $required -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host "启动失败：模块加载后仍找不到函数 $required，安装包可能不完整。" -ForegroundColor Red
        Write-Host ''
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 2. 环境检查
# ---------------------------------------------------------------------------
if (-not (Test-Administrator) -and -not $NoElevate) {
    $relaunched = Restart-Elevated -ScriptPath $PSCommandPath
    if ($relaunched) { exit 0 }
}

$baseDirectory = if ($PSBoundParameters.ContainsKey('OutputDirectory') -and $OutputDirectory) {
    $OutputDirectory
} else {
    Join-Path $script:RootDirectory 'Reports'
}
if (-not (Test-Path -LiteralPath $baseDirectory)) {
    New-Item -ItemType Directory -Path $baseDirectory -Force | Out-Null
}

$logPath = Initialize-ScanEnvironment -BaseDirectory $baseDirectory

$startedAt = Get-Date
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host ''
Write-Host '  Win11-Optimizer —— 一键只读诊断' -ForegroundColor White
Write-Host '  ─────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host '  这个版本只扫描、只报告，不会删你的文件、不改系统设置。' -ForegroundColor Green
Write-Host ''

$profile = Get-SystemProfile

if ([string]::IsNullOrWhiteSpace($profile.OSBuild) -or $profile.OSBuild -eq '未知') {
    Write-ScanLog -Level Warn -Message '无法确认系统版本，报告中的版本信息将留空。'
} elseif ([int]$profile.OSBuild -lt 22000) {
    Write-Host ''
    Write-Host "  本工具只支持 Windows 11（build 22000+），当前是 build $($profile.OSBuild)。" -ForegroundColor Yellow
    Write-Host '  扫描仍会继续，但部分结果可能不适用于你的系统。' -ForegroundColor Yellow
    Write-Host ''
}

Write-Headline '本机情况'
Write-Item ('机型：{0}' -f (Get-MachineLabel -Manufacturer $profile.Manufacturer -Model $profile.Model))
Write-Item ('系统：{0}' -f $profile.OSDisplay)
Write-Item ('CPU：{0}（{1} 核）' -f $profile.CpuName, $profile.CpuCores)
Write-Item ('内存：共 {0} GB，空闲 {1} GB（已用 {2}%）' -f $profile.MemoryTotalGB, $profile.MemoryFreeGB, $profile.MemoryUsedPct)
Write-Item ('权限：{0}' -f $(if ($profile.IsAdmin) { '管理员' } else { '普通用户（部分信息读不全）' }))
Write-Item ('PowerShell：{0}' -f $profile.PowerShell)

$context = @{
    Profile        = $profile
    LogPath        = $logPath
    BaseDirectory  = $baseDirectory
    SkipSlowScan   = [bool]$SkipSlowScan
    StartedAt      = $startedAt
}

# ---------------------------------------------------------------------------
# 3. 执行扫描
# ---------------------------------------------------------------------------
$allFindings = New-Object System.Collections.ArrayList

$scanPlan = @(
    @{ Name = '磁盘空间';    Action = { Invoke-DiskScan  -Context $context } }
    @{ Name = '系统状态';    Action = { Invoke-SystemScan -Context $context } }
    @{ Name = '电源方案';    Action = { Invoke-PowerScan  -Context $context } }
)

Write-Headline '开始扫描'
foreach ($step in $scanPlan) {
    Write-Host ('   → {0}…' -f $step.Name) -ForegroundColor Gray
    $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $step.Action
        if ($null -ne $result) {
            foreach ($finding in $result) { [void]$allFindings.Add($finding) }
        }
        $stepWatch.Stop()
        Write-Host ('     完成，用时 {0:N1} 秒' -f $stepWatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    } catch {
        $stepWatch.Stop()
        Write-ScanLog -Level Error -Message ('{0} 扫描失败：{1}' -f $step.Name, $_.Exception.Message)
        Write-Host ('     x 这一步出错了：{0}' -f $_.Exception.Message) -ForegroundColor Red
    }
}

$stopwatch.Stop()

# ---------------------------------------------------------------------------
# 4. 汇总与输出
# ---------------------------------------------------------------------------
$sorted = @($allFindings | Sort-Object -Property @{ Expression = { Get-SeverityRank -Severity $_.Severity } })

$severityCounts = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 }
foreach ($finding in $sorted) {
    if ($severityCounts.Contains($finding.Severity)) { $severityCounts[$finding.Severity]++ }
}

Write-Headline '发现问题汇总'
$problems = $severityCounts.Critical + $severityCounts.High + $severityCounts.Medium + $severityCounts.Low
Write-Item ('需要关注的项：{0} 个（严重 {1} · 偏高 {2} · 中等 {3} · 轻微 {4}）' -f `
    $problems, $severityCounts.Critical, $severityCounts.High, $severityCounts.Medium, $severityCounts.Low)
if ($severityCounts.Info -gt 0) {
    Write-Item ('参考信息：{0} 条' -f $severityCounts.Info)
}

if ($problems -eq 0) {
    Write-Item '恭喜，没有发现明显问题。'
}

foreach ($finding in $sorted) {
    if ($finding.Severity -eq 'Info') { continue }
    Write-Host ''
    Write-Host ('   [{0}] {1}' -f (Get-SeverityLabel -Severity $finding.Severity), $finding.Title) -ForegroundColor Yellow
    Write-Note $finding.Detail
    if ($finding.Advice) { Write-Note ('建议：{0}' -f $finding.Advice) }
}

if ($severityCounts.Info -gt 0) {
    Write-Headline '参考信息（不需要处理）'
    foreach ($finding in $sorted) {
        if ($finding.Severity -ne 'Info') { continue }
        Write-Item $finding.Title
        Write-Note $finding.Detail
    }
}

# ---------------------------------------------------------------------------
# 5. 写报告
# ---------------------------------------------------------------------------
function New-MarkdownReport {
    <#
    .SYNOPSIS
        生成 Markdown 报告文件，返回文件路径。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProfileData,
        [Parameter(Mandatory)][object[]]$Findings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Counts,
        [Parameter(Mandatory)][datetime]$Started,
        [Parameter(Mandatory)][double]$DurationSeconds,
        [Parameter(Mandatory)][string]$TargetDirectory
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('# Win11-Optimizer 诊断报告')
    [void]$lines.Add('')
    [void]$lines.Add(('生成时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$lines.Add(('扫描用时：{0:N1} 秒' -f $DurationSeconds))
    [void]$lines.Add('')
    [void]$lines.Add('> 本报告由只读扫描生成。工具没有删除任何文件，也没有修改任何系统设置。')
    [void]$lines.Add('')
    [void]$lines.Add('## 本机情况')
    [void]$lines.Add('')
    [void]$lines.Add('| 项目 | 值 |')
    [void]$lines.Add('|---|---|')
    [void]$lines.Add(('| 机型 | {0} |' -f (Get-MachineLabel -Manufacturer $ProfileData.Manufacturer -Model $ProfileData.Model)))
    [void]$lines.Add(('| 系统 | {0} |' -f $ProfileData.OSDisplay))
    [void]$lines.Add(('| CPU | {0}（{1} 核） |' -f $ProfileData.CpuName, $ProfileData.CpuCores))
    [void]$lines.Add(('| 内存 | 共 {0} GB / 空闲 {1} GB（已用 {2}%） |' -f $ProfileData.MemoryTotalGB, $ProfileData.MemoryFreeGB, $ProfileData.MemoryUsedPct))
    [void]$lines.Add(('| 权限 | {0} |' -f $(if ($ProfileData.IsAdmin) { '管理员' } else { '普通用户' })))
    [void]$lines.Add(('| PowerShell | {0} |' -f $ProfileData.PowerShell))
    [void]$lines.Add('')

    $problems = $Counts.Critical + $Counts.High + $Counts.Medium + $Counts.Low
    [void]$lines.Add('## 问题汇总')
    [void]$lines.Add('')
    [void]$lines.Add(('需要关注的项：**{0}** 个（严重 {1} · 偏高 {2} · 中等 {3} · 轻微 {4}）' -f `
        $problems, $Counts.Critical, $Counts.High, $Counts.Medium, $Counts.Low))
    [void]$lines.Add('')

    foreach ($finding in $Findings) {
        if ($finding.Severity -eq 'Info') { continue }
        [void]$lines.Add(('### [{0}] {1}' -f (Get-SeverityLabel -Severity $finding.Severity), $finding.Title))
        [void]$lines.Add('')
        [void]$lines.Add($finding.Detail)
        [void]$lines.Add('')
        if ($finding.Evidence -and $finding.Evidence.Count -gt 0) {
            [void]$lines.Add('实测数据：')
            [void]$lines.Add('')
            foreach ($key in $finding.Evidence.Keys) {
                [void]$lines.Add(('- **{0}**：{1}' -f $key, $finding.Evidence[$key]))
            }
            [void]$lines.Add('')
        }
        if ($finding.Advice) {
            [void]$lines.Add(('建议：{0}' -f $finding.Advice))
            [void]$lines.Add('')
        }
    }

    $infoFindings = @($Findings | Where-Object { $_.Severity -eq 'Info' })
    if ($infoFindings.Count -gt 0) {
        [void]$lines.Add('## 参考信息（不需要处理）')
        [void]$lines.Add('')
        foreach ($finding in $infoFindings) {
            [void]$lines.Add(('### {0}' -f $finding.Title))
            [void]$lines.Add('')
            [void]$lines.Add($finding.Detail)
            [void]$lines.Add('')
            foreach ($key in $finding.Evidence.Keys) {
                [void]$lines.Add(('- **{0}**：{1}' -f $key, $finding.Evidence[$key]))
            }
            [void]$lines.Add('')
        }
    }

    [void]$lines.Add('## 关于这个工具')
    [void]$lines.Add('')
    [void]$lines.Add('- 当前版本只做诊断，**不会执行任何清理或修改**。')
    [void]$lines.Add('- 报告里的每条结论都来自本机实测数据，可以自行到任务管理器或"设置"里核对。')
    [void]$lines.Add('- 日志文件与报告在同一目录，反馈问题时请一并附上。')
    [void]$lines.Add('')

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportPath = Join-Path $TargetDirectory "report-$stamp.md"
    $content = ($lines -join [System.Environment]::NewLine) + [System.Environment]::NewLine
    [System.IO.File]::WriteAllText($reportPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $reportPath
}

$reportPath = $null
try {
    $reportPath = New-MarkdownReport -ProfileData $profile -Findings $sorted -Counts $severityCounts `
        -Started $startedAt -DurationSeconds $stopwatch.Elapsed.TotalSeconds -TargetDirectory $baseDirectory
} catch {
    Write-ScanLog -Level Error -Message ('生成报告失败：{0}' -f $_.Exception.Message)
}

Write-Headline '完成'
Write-Item ('扫描用时：{0:N1} 秒' -f $stopwatch.Elapsed.TotalSeconds)
if ($reportPath) {
    Write-Item ('报告文件：{0}' -f $reportPath)
} else {
    Write-Item '报告文件生成失败，请把上面的错误信息反馈给开发者。'
}
Write-Item ('日志文件：{0}' -f $logPath)
if ((Get-ScanWarningCount) -gt 0) {
    Write-Note ('扫描过程中有 {0} 条警告，已写入日志（通常表示某些信息没读到，不影响其余结论）。' -f (Get-ScanWarningCount))
}
Write-Host ''
Write-Host '  报告已生成，本工具到此结束——它没有修改你的任何设置。' -ForegroundColor Green
Write-Host ''

Write-ScanLog -Level Info -Message ('扫描结束，用时 {0:N1} 秒，发现 {1} 项需要关注' -f $stopwatch.Elapsed.TotalSeconds, $problems)
exit 0
