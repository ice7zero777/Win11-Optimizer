#Requires -Version 5.1
<#
.SYNOPSIS
    Win11-Optimizer —— 一键诊断，并在你确认后安全清理缓存（可一键还原）。

.DESCRIPTION
    默认行为是**只读诊断**：扫描本机问题、用大白话讲清原因、把报告写到文件。
    加 -Clean 才会进入清理流程，而且必须经过"你勾选 + 输入 yes 确认"两道关。

    安全边界（任何模式下都成立）：
      · 只清理白名单内的缓存目录，绝不触碰用户文档、图片、桌面等任何个人文件
      · 清理动作是**移动**到 Snapshot 隔离区，不是删除——随时可用 -Restore 放回
      · 不改注册表、不改服务启动类型、不卸载软件、不联网
      · 隔离区有体积上限，达到上限即停止，不会把磁盘占满

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

.PARAMETER Clean
    扫描完成后进入清理流程：测量可清理的缓存、让你勾选、确认后把文件**移动**到隔离区。
    默认不开启；只有显式加 -Clean 才会动文件。

.PARAMETER SelectTargets
    直接指定要清理的目标 Id（跳过交互勾选），例如 -SelectTargets temp.user,cache.shader，
    或 -SelectTargets all 表示全部。给熟悉命令行的人和自动化使用，必须与 -Clean 一起用。

.PARAMETER AssumeYes
    跳过"输入 yes"的二次确认。**必须同时用 -SelectTargets 显式列出目标**，
    否则拒绝执行——这样就不存在任何形式的一键无人值守清理。

.PARAMETER Restore
    一键还原：把隔离区里的文件移回原来的位置。原位置已有同名文件时会跳过，不覆盖。

.PARAMETER QuarantineBudgetMB
    隔离区体积上限（MB），默认 2048（2 GB）。达到上限就停止清理，避免把磁盘占满。

.EXAMPLE
    .\Win11Optimizer.ps1
    只扫描并生成报告，不修改任何东西。

.EXAMPLE
    .\Win11Optimizer.ps1 -NoElevate -SkipSlowScan
    以当前权限快速扫描（适合只想先看一眼的情况）。

.EXAMPLE
    .\Win11Optimizer.ps1 -Clean
    扫描后进入清理流程（会先让你勾选并输入 yes 确认）。

.EXAMPLE
    .\Win11Optimizer.ps1 -Clean -SelectTargets temp.user -AssumeYes
    只清理用户临时文件，全程不进入交互（适合熟悉命令行的人）。

.EXAMPLE
    .\Win11Optimizer.ps1 -Restore
    把之前隔离的文件放回原位。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    错误处理：不允许静默失败（铁律 L2）；所有外部调用带超时或 -PassThru 校验（铁律 L3）。
    安全边界：清理只允许 Cleanup.Targets.ps1 白名单内的缓存路径，且一律"移动"而非删除。
#>
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$SkipSlowScan,
    [string]$OutputDirectory,
    [switch]$Clean,
    [switch]$Restore,
    [string[]]$SelectTargets,
    [switch]$AssumeYes,
    [ValidateRange(128, 20480)][int]$QuarantineBudgetMB = 2048
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

# 必需模块：扫描与还原都依赖它们，缺任何一个都不能继续
foreach ($moduleName in @('Common.ps1', 'Scan.Disk.ps1', 'Scan.System.ps1', 'Scan.Power.ps1',
        'Cleanup.Targets.ps1', 'Cleanup.Snapshot.ps1', 'Cleanup.Engine.ps1')) {
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

# 交互界面模块：只有 -Clean 才需要。缺了它，扫描与还原仍然可用——
# 下载工具拦掉单个文件、或用户只复制了部分文件时，不至于整个工具都打不开。
$script:CleanupUiReady = $false
$uiModulePath = Join-Path $libDirectory 'Cleanup.Ui.ps1'
if (Test-Path -LiteralPath $uiModulePath -PathType Leaf) {
    try {
        . $uiModulePath
        $script:CleanupUiReady = $true
    } catch {
        Write-Host ''
        Write-Host "提示：交互界面模块加载失败，-Clean 将不可用 —— $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host '提示：未找到交互界面模块 lib\Cleanup.Ui.ps1，扫描与还原仍可正常使用，但 -Clean 不可用。' -ForegroundColor Yellow
}

if ($Clean -and -not $script:CleanupUiReady) {
    Write-Host ''
    Write-Host '启动失败：指定了 -Clean，但交互界面模块不可用，无法让你勾选要清理的项目。' -ForegroundColor Red
    Write-Host '请重新完整解压发布包后重试；或者去掉 -Clean，只做只读扫描。' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

# 加载后立刻确认关键函数都在，避免带着半截环境往下跑
foreach ($required in @('Initialize-ScanEnvironment', 'Get-SystemProfile', 'New-Finding',
        'Invoke-DiskScan', 'Invoke-SystemScan', 'Invoke-PowerScan',
        'Get-CleanupItem', 'Invoke-CleanupRun', 'Test-CleanupPathAllowed')) {
    if (-not (Get-Command -Name $required -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host "启动失败：模块加载后仍找不到函数 $required，安装包可能不完整。" -ForegroundColor Red
        Write-Host ''
        exit 1
    }
}

if ($Clean -and $script:CleanupUiReady) {
    foreach ($required in @('Show-CleanupList', 'Read-CleanupConfirmation')) {
        if (-not (Get-Command -Name $required -ErrorAction SilentlyContinue)) {
            Write-Host ''
            Write-Host "启动失败：界面模块里找不到函数 $required，无法进行 -Clean 流程。" -ForegroundColor Red
            Write-Host ''
            exit 1
        }
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
Write-Host '  Win11-Optimizer —— 诊断与可选清理' -ForegroundColor White
Write-Host '  ─────────────────────────────────────────────' -ForegroundColor DarkGray
if ($Clean) {
    Write-Host '  这次会扫描，并在你勾选确认后把缓存文件移进隔离区（可一键还原）。' -ForegroundColor Yellow
    Write-Host '  它不会删除任何用户文件，也不会改注册表、服务或系统设置。' -ForegroundColor Green
} else {
    Write-Host '  默认只扫描、只报告：不删你的文件、不改系统设置。' -ForegroundColor Green
    Write-Host '  想清理缓存请显式加 -Clean（会先让你勾选并确认）。' -ForegroundColor DarkGray
}
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
# 3. 还原模式（-Restore）：先把文件放回去，不做扫描
# ---------------------------------------------------------------------------
if ($Restore) {
    Write-Headline '一键还原'
    Write-Host '   把隔离区里的文件移回它们原来的位置。原位置已有同名文件时会跳过，不会覆盖。' -ForegroundColor DarkGray
    Write-Host ''

    $snapshotRoot = Join-Path $baseDirectory 'Snapshot'
    $runDirectories = @()
    if (Test-Path -LiteralPath $snapshotRoot -PathType Container) {
        $runDirectories = @(Get-ChildItem -LiteralPath $snapshotRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
            Sort-Object Name -Descending)
    }

    if ($runDirectories.Count -eq 0) {
        Write-Host '   没有找到任何隔离记录，说明还没有清理过。' -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    # 先列出要还原什么，让用户看清楚
    $planned = New-Object System.Collections.ArrayList
    foreach ($dir in $runDirectories) {
        $manifestPath = Join-Path $dir.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-ScanLog -Level Warn -Message "跳过无法解析的台账 $manifestPath：$($_.Exception.Message)"
            continue
        }
        foreach ($change in @($manifest.changes)) {
            if ($null -eq $change) { continue }
            $quarantinePath = Join-Path $dir.FullName ([string]$change.QuarantineAs)
            if (-not (Test-Path -LiteralPath $quarantinePath -PathType Leaf)) {
                $quarantinePath = [string]$change.QuarantineAs
            }
            [void]$planned.Add([pscustomobject]@{
                    RunId        = [string]$manifest.runId
                    OriginalPath = [string]$change.OriginalPath
                    QuarantineAs = $quarantinePath
                    Bytes        = [int64]$change.Bytes
                })
        }
    }

    if ($planned.Count -eq 0) {
        Write-Host '   隔离记录里没有文件（可能已经还原过了）。' -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    Write-Host ('   共有 {0} 个文件在隔离区，合计 {1}' -f $planned.Count, (ConvertTo-SizeText -Bytes ([int64](($planned | Measure-Object -Property Bytes -Sum).Sum))))
    Write-Host ''
    Write-Host '   确认无误的话，输入 yes 开始还原（其它任何输入都会取消）：' -ForegroundColor Yellow
    $answer = Read-Host '   请输入'
    if ($answer -notmatch '^\s*yes\s*$') {
        Write-Host '   已取消，未做任何改动。' -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    $restored = 0; $already = 0; $skipped = 0; $failed = 0
    $restoredBytes = [int64]0
    foreach ($entry in $planned) {
        $atOriginal = Test-Path -LiteralPath $entry.OriginalPath
        $inQuarantine = Test-Path -LiteralPath $entry.QuarantineAs -PathType Leaf
        if (-not $inQuarantine -and $atOriginal) { $already++; continue }
        if (-not $inQuarantine) {
            Write-ScanLog -Level Warn -Message "隔离文件已不存在：$($entry.QuarantineAs)"
            $skipped++
            continue
        }
        if ($atOriginal) {
            Write-Host ('   ! 原位置已有同名文件，跳过：{0}' -f $entry.OriginalPath) -ForegroundColor Yellow
            $skipped++
            continue
        }
        try {
            $parent = Split-Path -Parent $entry.OriginalPath
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Move-Item -LiteralPath $entry.QuarantineAs -Destination $entry.OriginalPath -Force -ErrorAction Stop
            $restored++
            $restoredBytes += $entry.Bytes
        } catch {
            Write-Host ('   x 还原失败：{0} —— {1}' -f $entry.OriginalPath, $_.Exception.Message) -ForegroundColor Red
            Write-ScanLog -Level Error -Message ('还原失败 {0}：{1}' -f $entry.OriginalPath, $_.Exception.Message)
            $failed++
        }
    }

    Write-Host ''
    Write-Host ('   已还原 {0} 个文件（{1}）；此前已还原 {2} 个；跳过 {3} 个；失败 {4} 个' -f `
            $restored, (ConvertTo-SizeText -Bytes $restoredBytes), $already, $skipped, $failed) -ForegroundColor Green
    if ($restored -eq 0 -and $already -gt 0) {
        Write-Host '   这些文件此前已经还原过了，无需重复操作。' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-ScanLog -Level Info -Message ('还原结束：还原 {0}，此前已还原 {1}，跳过 {2}，失败 {3}' -f $restored, $already, $skipped, $failed)
    if ($failed -gt 0) { exit 1 }
    exit 0
}

# ---------------------------------------------------------------------------
# 4. 执行扫描
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

# ---------------------------------------------------------------------------
# 6. 可选清理（-Clean）：测量 → 勾选 → 确认 → 隔离 → 生成还原脚本
# ---------------------------------------------------------------------------
$cleanupResult = $null
$quarantineTotal = Get-QuarantineTotalSize -BaseDirectory $baseDirectory

if ($Clean) {
    Write-Headline '可清理的缓存'

    # 归一化 -SelectTargets：用 powershell -File 传参时 "a,b" 会作为**一个**字符串进来，
    # 而在 PowerShell 里调用时已经是拆好的数组。这里统一按逗号再拆一次，去掉空格与空项。
    $requestedTargets = @()
    if ($null -ne $SelectTargets -and $SelectTargets.Count -gt 0) {
        $requestedTargets = @($SelectTargets |
            ForEach-Object { ([string]$_).Split(',') } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' })
    }

    $cleanupItems = @()
    try {
        $cleanupItems = @(Get-CleanupItem -BaseDirectory $baseDirectory)
    } catch {
        Write-ScanLog -Level Error -Message ('测量缓存失败：{0}' -f $_.Exception.Message)
        Write-Host ('   x 测量缓存时出错：{0}' -f $_.Exception.Message) -ForegroundColor Red
    }

    $selectable = @($cleanupItems | Where-Object { ($_.Bytes -gt 0) -or ($_.SmallFileCount -gt 0) })
    $selectedIds = @()

    if ($AssumeYes -and $requestedTargets.Count -eq 0) {
        Write-Host '   拒绝执行：-AssumeYes 必须同时用 -SelectTargets 显式列出要清理的目标。' -ForegroundColor Red
        Write-Host '   这是刻意的限制——本工具不提供任何"一键无人值守清理"。' -ForegroundColor Yellow
    } elseif ($requestedTargets.Count -gt 0) {
        # 命令行显式指定目标：跳过交互
        $knownIds = @($selectable | ForEach-Object { [string]$_.Id })
        if ($requestedTargets -contains 'all') {
            $selectedIds = $knownIds
        } else {
            $chosen = New-Object System.Collections.ArrayList
            foreach ($wanted in $requestedTargets) {
                $match = @($knownIds | Where-Object { $_ -eq $wanted })
                if ($match.Count -gt 0) {
                    [void]$chosen.Add($match[0])
                } else {
                    Write-Host ('   忽略未知目标：{0}（本机没有该目标的可用内容，或 Id 拼写错误）' -f $wanted) -ForegroundColor Yellow
                    Write-ScanLog -Level Warn -Message "忽略未知清理目标：$wanted"
                }
            }
            $selectedIds = $chosen.ToArray()
        }
        Write-Host ('   已按命令行指定选中 {0} 项：{1}' -f $selectedIds.Count, ($selectedIds -join '、'))
    } elseif ($selectable.Count -gt 0) {
        $selectedIds = @(Show-CleanupList -Items $selectable)
    } else {
        Write-Host '   没有发现值得清理的缓存。' -ForegroundColor DarkGray
    }

    # 命令行指定了目标但一个都没匹配上时，必须说清楚，不能默默什么都不做
    if ($requestedTargets.Count -gt 0 -and $selectedIds.Count -eq 0 -and -not $AssumeYes) {
        Write-Host '   指定的目标在本机都没有可清理的内容。' -ForegroundColor Yellow
    }

    if ($selectedIds.Count -eq 0) {
        Write-Host '   没有选择任何项目，未做清理。' -ForegroundColor Yellow
    } else {
        $selectedItems = @($selectable | Where-Object { $selectedIds -contains $_.Id })
        $estimated = [int64]0
        foreach ($item in $selectedItems) { $estimated += [int64]$item.Bytes }

        $confirmed = $false
        if ($AssumeYes) {
            Write-Host '   已使用 -AssumeYes 跳过二次确认。' -ForegroundColor Yellow
            $confirmed = $true
        } else {
            $confirmed = [bool](Read-CleanupConfirmation -SelectedItems $selectedItems -EstimatedBytes $estimated)
        }

        if (-not $confirmed) {
            Write-Host '   已取消，未做任何改动。' -ForegroundColor Yellow
        } else {
            Write-Headline '开始隔离'
            $budgetBytes = [int64]$QuarantineBudgetMB * 1MB
            try {
                $cleanupResult = Invoke-CleanupRun -TargetId $selectedIds -BaseDirectory $baseDirectory `
                    -Profile $profile -BudgetBytes $budgetBytes
            } catch {
                Write-ScanLog -Level Error -Message ('清理执行失败：{0}' -f $_.Exception.Message)
                Write-Host ('   x 清理执行失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
            }

            if ($null -ne $cleanupResult) {
                Write-Host ''
                Write-Item ('已隔离 {0} 个文件，共 {1}' -f $cleanupResult.MovedCount, (ConvertTo-SizeText -Bytes $cleanupResult.MovedBytes))
                if ($cleanupResult.SkippedCount -gt 0) {
                    Write-Note ('{0} 个文件被跳过（正被程序占用或不允许处理），已记入日志。' -f $cleanupResult.SkippedCount)
                }
                if ($cleanupResult.OverBudget) {
                    Write-Note ('隔离区达到 {0} MB 上限后停止，剩余文件未处理。可用 -QuarantineBudgetMB 调大上限后重跑。' -f $QuarantineBudgetMB)
                }
                Write-Item ('隔离区：{0}' -f $cleanupResult.SnapshotRoot)
                Write-Item ('还原脚本：{0}' -f $cleanupResult.RestoreScript)
                Write-Host ''
                Write-Host '   注意：隔离区仍然占着磁盘空间。确认电脑一切正常后，可以手动删除 Snapshot 目录来真正腾出空间；' -ForegroundColor DarkGray
                Write-Host '         如果发现异常，运行 .\Win11Optimizer.ps1 -Restore 就能把文件放回来。' -ForegroundColor DarkGray
            }
        }
    }

    $quarantineTotal = Get-QuarantineTotalSize -BaseDirectory $baseDirectory
}

# ---------------------------------------------------------------------------
# 7. 收尾
# ---------------------------------------------------------------------------
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
if ($quarantineTotal -gt 0) {
    Write-Item ('隔离区当前占用：{0}' -f (ConvertTo-SizeText -Bytes $quarantineTotal))
    Write-Note '隔离区里的文件可以还原（-Restore）或确认无误后删除 Snapshot 目录。'
}
Write-Host ''

if ($null -ne $cleanupResult -and $cleanupResult.MovedCount -gt 0) {
    Write-Host '  本次有文件被移入隔离区，可用 .\Win11Optimizer.ps1 -Restore 一键放回。' -ForegroundColor Green
} else {
    Write-Host '  本次没有修改你的任何文件。' -ForegroundColor Green
}
Write-Host ''

Write-ScanLog -Level Info -Message ('运行结束，用时 {0:N1} 秒，发现 {1} 项需要关注' -f $stopwatch.Elapsed.TotalSeconds, $problems)
exit 0
