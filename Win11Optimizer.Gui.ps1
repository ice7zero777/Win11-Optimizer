#Requires -Version 5.1
<#
.SYNOPSIS
    Win11-Optimizer 图形界面入口：创建窗口、绑定按钮、渲染结果。

.DESCRIPTION
    本文件只做"界面接线"：
      · 建窗口（lib\Gui.Window.ps1）
      · 绑定「开始扫描 / 清理选中项 / 一键还原」三个按钮
      · 把 lib\Gui.Core.ps1 取回的数据填进表格
      · 扫描与清理在后台 runspace 执行，主线程泵 WPF 消息，窗口全程不假死

    业务逻辑一行都不在这里：扫描用 lib\Scan.*.ps1，清理用 lib\Cleanup.*.ps1。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    安全性：清理必须由用户在勾选后、再经弹窗确认才会执行；不改系统设置。
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$TestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework

# ---------------------------------------------------------------------------
# 是否进入事件循环
# ---------------------------------------------------------------------------
# 默认进入（Start-Gui.cmd 直接运行本文件即可弹窗）。
# 加 -TestMode 时只定义函数、绑定事件，不 ShowDialog——
# 因为 ShowDialog() 是阻塞的，自动化测试点源本文件后会永久卡在它上面，测不到任何东西。
# 注意不要用 $MyInvocation.InvocationName 判断：powershell -File 运行时它同样是 '.'。
$script:ShouldRunWindow = -not $TestMode

$rootDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($rootDirectory)) { $rootDirectory = (Get-Location).Path }

# ---------------------------------------------------------------------------
# 加载模块（必须在脚本顶层点源；函数内点源会把函数丢在局部作用域）
# ---------------------------------------------------------------------------
foreach ($moduleName in @('Common.ps1', 'Cleanup.Targets.ps1', 'Cleanup.Snapshot.ps1', 'Cleanup.Engine.ps1',
        'Scan.Disk.ps1', 'Scan.System.ps1', 'Scan.Power.ps1', 'Gui.Core.ps1', 'Gui.Window.ps1')) {
    $modulePath = Join-Path (Join-Path $rootDirectory 'lib') $moduleName
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        [System.Windows.MessageBox]::Show("缺少模块文件：$modulePath`n请确认压缩包已完整解压。", 'Win11 一键优化', 'OK', 'Error') | Out-Null
        exit 1
    }
    . $modulePath
}

$baseDirectory = if ($PSBoundParameters.ContainsKey('OutputDirectory') -and $OutputDirectory) {
    $OutputDirectory
} else {
    Join-Path $rootDirectory 'Reports'
}
if (-not (Test-Path -LiteralPath $baseDirectory)) {
    New-Item -ItemType Directory -Path $baseDirectory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# 界面状态
# ---------------------------------------------------------------------------
$script:LogLineCount = 0
$script:LastScan = $null
$script:CleanupRows = @()
$script:IsBusy = $false

$window = New-MainWindow

$statusText = $window.FindName('StatusText')
$progressBar = $window.FindName('ProgressBar')
$scanButton = $window.FindName('ScanButton')
$cleanButton = $window.FindName('CleanButton')
$restoreButton = $window.FindName('RestoreButton')
$quarantineText = $window.FindName('QuarantineText')
$findingsGrid = $window.FindName('FindingsGrid')
$cleanupGrid = $window.FindName('CleanupGrid')
$cleanupSummary = $window.FindName('CleanupSummary')
$logBox = $window.FindName('LogBox')
$pathText = $window.FindName('PathText')

function Write-GuiLog {
    <#
    .SYNOPSIS
        往"运行日志"里追加一行（有上限，避免长时间运行吃内存）。
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Lines)

    if ($null -eq $Lines -or $Lines.Count -eq 0) { return }
    foreach ($line in $Lines) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $logBox.AppendText($line + [System.Environment]::NewLine) | Out-Null
        $script:LogLineCount++
    }
    if ($script:LogLineCount -gt $script:MaxLogLines) {
        # 超限时截掉前半段，保留最近的内容
        $text = $logBox.Text
        $keepFrom = $text.Length - [int]($text.Length * 0.6)
        $logBox.Text = '[日志过长，已省略较早内容]' + [System.Environment]::NewLine + $text.Substring($keepFrom)
        $script:LogLineCount = 2400
    }
    $logBox.ScrollToEnd()
}

function Ask-GuiConfirmation {
    <#
    .SYNOPSIS
        弹出"是 / 否"确认框，返回用户是否点了"是"。

    .NOTES
        单独抽成一个函数是为了留出测试接缝：WPF 的 MessageBox 是模态的，会阻塞消息泵，
        自动化测试既关不掉它、也点不了它。测试时可以用同名函数覆盖实现来自动作答，
        从而在不碰真实弹窗的前提下验证"勾选 → 确认 → 执行"这条链路。
        正式运行时这里永远是真实弹窗——**确认这一道闸不会被跳过**。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Title
    )

    $answer = [System.Windows.MessageBox]::Show($Message, $Title, 'YesNo', 'Question')
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Set-GuiBusy {
    <#
    .SYNOPSIS
        切换"忙碌"外观：按钮禁用、进度条滚动。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Busy)

    $script:IsBusy = $Busy
    $scanButton.IsEnabled = -not $Busy
    $restoreButton.IsEnabled = -not $Busy
    $cleanButton.IsEnabled = ((-not $Busy) -and ($script:CleanupRows.Count -gt 0))
    $progressBar.IsIndeterminate = $Busy
    if (-not $Busy) { $progressBar.Value = 0 }
}

function Update-QuarantineText {
    <#
    .SYNOPSIS
        刷新右上角隔离区占用显示。
    #>
    [CmdletBinding()]
    param([int64]$Bytes = -1)

    try {
        if ($Bytes -lt 0) {
            $summary = Get-GuiQuarantineSummary -BaseDirectory $baseDirectory
            $quarantineText.Text = $summary.Text
        } elseif ($Bytes -le 0) {
            $quarantineText.Text = '隔离区：无'
        } else {
            $quarantineText.Text = ('隔离区：{0}（可还原）' -f (ConvertTo-SizeText -Bytes $Bytes))
        }
    } catch {
        Write-GuiLog -Lines @("刷新隔离区信息失败：$($_.Exception.Message)")
    }
}

function Show-Profile {
    <#
    .SYNOPSIS
        把本机信息填进窗口。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Profile)

    $window.FindName('ProfileMachine').Text = '机型：' + (Get-MachineLabel -Manufacturer ([string]$Profile.Manufacturer) -Model ([string]$Profile.Model))
    $window.FindName('ProfileOS').Text = '系统：' + [string]$Profile.OSDisplay
    $window.FindName('ProfileCpu').Text = ('CPU：{0}（{1} 核）' -f $Profile.CpuName, $Profile.CpuCores)
    $window.FindName('ProfileMemory').Text = ('内存：共 {0} GB / 空闲 {1} GB（已用 {2}%）' -f $Profile.MemoryTotalGB, $Profile.MemoryFreeGB, $Profile.MemoryUsedPct)
    $window.FindName('ProfileAdmin').Text = '权限：' + $(if ($Profile.IsAdmin) { '管理员' } else { '普通用户（部分信息读不全）' })
    $window.FindName('ProfilePowerShell').Text = 'PowerShell：' + [string]$Profile.PowerShell
}

# ---------------------------------------------------------------------------
# 开始扫描
# ---------------------------------------------------------------------------
function Start-Scan {
    [CmdletBinding()]
    param()

    if ($script:IsBusy) { return }

    Set-GuiBusy -Busy $true
    $statusText.Text = '正在扫描…（磁盘、内存、服务、启动项、电源）'
    $findingsGrid.ItemsSource = $null
    $cleanupGrid.ItemsSource = $null
    $script:CleanupRows = @()
    $cleanButton.IsEnabled = $false
    Write-GuiLog -Lines @('', ('==== 开始扫描 {0} ====' -f (Get-Date -Format 'HH:mm:ss')))

    try {
        $task = Start-GuiScan -Root $rootDirectory -BaseDirectory $baseDirectory
        $script:ActiveTask = $task
        Wait-GuiHandle -Handle $task.Handle -Queue $task.Queue `
            -OnOutput { param($batch) Write-GuiLog -Lines $batch } `
            -OnTick { $progressBar.Value = ($progressBar.Value + 7) % 100 }
        $data = Complete-GuiAsync -Task $task
        $script:ActiveTask = $null

        if ($null -eq $data) {
            throw '扫描没有返回结果（后台任务可能异常退出）。'
        }

        $script:LastScan = $data
        Show-Profile -Profile $data.Profile

        $findings = Format-GuiFindings -Findings @($data.Findings)
        $findingsGrid.ItemsSource = $findings

        $rows = Format-GuiCleanupItems -Items @($data.CleanupItems)
        $script:CleanupRows = @($rows | Where-Object { $_.Enabled -or ($_.FileCount -gt 0) })
        $cleanupGrid.ItemsSource = $script:CleanupRows

        $problems = @($findings | Where-Object { $_.Severity -ne '提示' }).Count
        $selectedBytes = [int64]0
        foreach ($row in $script:CleanupRows) {
            if ($row.Selected) { $selectedBytes += [int64]$row.Bytes }
        }
        $cleanupSummary.Text = ('共 {0} 项可清理；默认勾选合计 {1}，确认后才会移入隔离区。' -f `
                $script:CleanupRows.Count, (ConvertTo-SizeText -Bytes $selectedBytes))
        $statusText.Text = ('扫描完成：发现 {0} 项需要关注，{1} 类可清理缓存。' -f $problems, $script:CleanupRows.Count)
        Write-GuiLog -Lines @(('==== 扫描完成，用时见日志 ===='))
        $pathText.Text = ('报告目录：{0}    日志：{1}' -f $data.BaseDirectory, $data.LogPath)
        Update-QuarantineText
    } catch {
        $statusText.Text = '扫描失败。'
        Write-GuiLog -Lines @(('扫描失败：{0}' -f $_.Exception.Message))
        [System.Windows.MessageBox]::Show("扫描失败：$($_.Exception.Message)", 'Win11 一键优化', 'OK', 'Error') | Out-Null
    } finally {
        Set-GuiBusy -Busy $false
    }
}

# ---------------------------------------------------------------------------
# 清理选中项
# ---------------------------------------------------------------------------
function Start-Cleanup {
    [CmdletBinding()]
    param()

    if ($script:IsBusy) { return }

    $selected = @($script:CleanupRows | Where-Object { $_.Selected -and $_.Enabled })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show('你没有勾选任何要清理的项目（或者勾选的项只有小于 1 MB 的小文件）。', 'Win11 一键优化', 'OK', 'Information') | Out-Null
        return
    }

    $estimate = [int64]0
    foreach ($row in $selected) { $estimate += [int64]$row.Bytes }

    $names = ($selected | ForEach-Object { '· ' + $_.Name }) -join "`n"
    $question = @"
将要清理以下 $($selected.Count) 项，共约 $(ConvertTo-SizeText -Bytes $estimate)：

$names

这些文件会被【移动到隔离区】，不是直接删除：
· 发现异常可以随时点「一键还原」全部放回原位
· 隔离区默认上限 2 GB，达到上限就停止
· 正在被程序占用的文件会自动跳过

确认开始吗？
"@
    $confirmed = Ask-GuiConfirmation -Message $question -Title '确认清理'
    if (-not $confirmed) {
        $statusText.Text = '已取消清理，未做任何改动。'
        Write-GuiLog -Lines @('用户取消了清理。')
        return
    }
    Set-GuiBusy -Busy $true
    $statusText.Text = '正在隔离文件…'
    Write-GuiLog -Lines @('', ('==== 开始清理 {0} ====' -f (Get-Date -Format 'HH:mm:ss')))

    try {
        $targets = @($selected | ForEach-Object { [string]$_.Id })
        $task = Start-GuiCleanup -Root $rootDirectory -BaseDirectory $baseDirectory -TargetId $targets
        $script:ActiveTask = $task
        Wait-GuiHandle -Handle $task.Handle -Queue $task.Queue `
            -OnOutput { param($batch) Write-GuiLog -Lines $batch } `
            -OnTick { $progressBar.Value = ($progressBar.Value + 4) % 100 }
        $result = Complete-GuiAsync -Task $task
        $script:ActiveTask = $null

        if ($null -eq $result) { throw '清理没有返回结果（后台任务可能异常退出）。' }

        Write-GuiLog -Lines @(
            ('已隔离 {0} 个文件，共 {1}' -f $result.MovedCount, (ConvertTo-SizeText -Bytes $result.MovedBytes)),
            ('跳过的文件：{0}' -f $result.SkippedCount),
            ('隔离区：{0}' -f $result.SnapshotRoot),
            ('还原脚本：{0}' -f $result.RestoreScript)
        )
        if ($result.OverBudget) {
            Write-GuiLog -Lines @('隔离区达到体积上限后停止，剩余文件未处理。')
        }

        $statusText.Text = ('清理完成：已隔离 {0} 个文件，{1}。' -f $result.MovedCount, (ConvertTo-SizeText -Bytes $result.MovedBytes))
        $pathText.Text = '还原脚本：' + $result.RestoreScript
        Update-QuarantineText -Bytes ([int64]$result.QuarantineBytes)

        $notice = @"
已隔离 $($result.MovedCount) 个文件，共 $(ConvertTo-SizeText -Bytes $result.MovedBytes)。

注意：隔离区仍然占着磁盘空间。
· 确认电脑一切正常后，删除 Reports\Snapshot 目录即可真正释放空间
· 如果发现异常，点「一键还原」把文件放回原位
"@
        [System.Windows.MessageBox]::Show($notice, '清理完成', 'OK', 'Information') | Out-Null
    } catch {
        $statusText.Text = '清理失败。'
        Write-GuiLog -Lines @(('清理失败：{0}' -f $_.Exception.Message))
        [System.Windows.MessageBox]::Show("清理失败：$($_.Exception.Message)", 'Win11 一键优化', 'OK', 'Error') | Out-Null
    } finally {
        Set-GuiBusy -Busy $false
    }
}

# ---------------------------------------------------------------------------
# 一键还原
# ---------------------------------------------------------------------------
function Start-Restore {
    [CmdletBinding()]
    param()

    if ($script:IsBusy) { return }

    $summary = Get-GuiQuarantineSummary -BaseDirectory $baseDirectory
    if ($summary.Count -eq 0) {
        [System.Windows.MessageBox]::Show('隔离区里没有文件，无需还原。', 'Win11 一键优化', 'OK', 'Information') | Out-Null
        return
    }

    $question = @"
隔离区里有 $($summary.Count) 个文件（$(ConvertTo-SizeText -Bytes $summary.Bytes)）。

将把它们移回原来的位置：
· 原位置已有同名文件时会跳过，不会覆盖
· 还原不改动任何系统设置

确认还原吗？
"@
    $confirmed = Ask-GuiConfirmation -Message $question -Title '确认还原'
    if (-not $confirmed) {
        $statusText.Text = '已取消还原。'
        return
    }

    Set-GuiBusy -Busy $true
    $statusText.Text = '正在还原…'
    Write-GuiLog -Lines @('', ('==== 开始还原 {0} ====' -f (Get-Date -Format 'HH:mm:ss')))

    try {
        $result = Restore-GuiQuarantine -BaseDirectory $baseDirectory
        Write-GuiLog -Lines @(
            ('已还原 {0} 个文件，共 {1}' -f $result.Restored, (ConvertTo-SizeText -Bytes $result.Bytes)),
            ('此前已还原：{0}；跳过：{1}；失败：{2}' -f $result.Already, $result.Skipped, $result.Failed)
        )
        $statusText.Text = ('还原完成：已放回 {0} 个文件（跳过 {1}，失败 {2}）。' -f $result.Restored, $result.Skipped, $result.Failed)
        Update-QuarantineText

        [System.Windows.MessageBox]::Show("已还原 $($result.Restored) 个文件，共 $(ConvertTo-SizeText -Bytes $result.Bytes)。`n跳过 $($result.Skipped) 个，失败 $($result.Failed) 个。", '还原完成', 'OK', 'Information') | Out-Null
    } catch {
        $statusText.Text = '还原失败。'
        Write-GuiLog -Lines @(('还原失败：{0}' -f $_.Exception.Message))
        [System.Windows.MessageBox]::Show("还原失败：$($_.Exception.Message)", 'Win11 一键优化', 'OK', 'Error') | Out-Null
    } finally {
        Set-GuiBusy -Busy $false
    }
}

# ---------------------------------------------------------------------------
# 绑定事件并显示
# ---------------------------------------------------------------------------
$scanButton.Add_Click({ Start-Scan })
$cleanButton.Add_Click({ Start-Cleanup })
$restoreButton.Add_Click({ Start-Restore })

$window.Add_ContentRendered({
        Write-GuiLog -Lines @(
            'Win11 一键优化 · 诊断与安全清理',
            '清理 = 把文件移动到隔离区，可随时一键还原。',
            '点「开始扫描」查看本机情况。',
            ''
        )
        Update-QuarantineText
        $statusText.Text = '就绪。点击「开始扫描」检查本机情况。'
    })

Update-QuarantineText

if ($script:ShouldRunWindow) {
    [void]$window.ShowDialog()
}
