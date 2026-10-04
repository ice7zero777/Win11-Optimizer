#Requires -Version 5.1
<#
.SYNOPSIS
    图形界面编排层：把现有扫描/清理/还原逻辑接到窗口上。

.DESCRIPTION
    分工：
      · Gui.Window.ps1 —— 只画窗口、返回 Window 对象
      · 本文件         —— 取数据、异步执行、把结果整理成界面能直接绑定的形状
      · Win11Optimizer.Gui.ps1 —— 创建窗口、绑定事件、渲染

    **不重复实现任何业务逻辑**：扫描用 Invoke-DiskScan / Invoke-SystemScan /
    Invoke-PowerScan，清理用 Get-CleanupItem / Invoke-CleanupRun / Move-FileToQuarantine，
    还原直接读隔离台账把文件移回去。

    线程模型：扫描与清理都放在独立 runspace 里跑，主线程用 DispatcherFrame 泵消息，
    所以窗口全程可拖动、不假死。扫描过程的文字通过并发队列传回界面。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    错误处理：不允许静默失败（铁律 L2）——每一步失败都要带原因返回或抛出。
#>

Set-StrictMode -Version Latest

# DispatcherFrame / DispatcherTimer 在 WindowsBase 里。Gui 入口通常已经加载了
# PresentationFramework，但本模块要能独立使用（测试、单独调用），所以显式加载一次。
try {
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
} catch {
    throw ("无法加载 WindowsBase，图形界面所需的消息泵不可用：{0}" -f $_.Exception.Message)
}

# 运行日志最多保留多少行，避免长时间运行把内存吃满
$script:MaxLogLines = 3000

function Get-GuiOutputQueue {
    <#
    .SYNOPSIS
        建一个线程安全的输出队列，供后台 runspace 向界面回传文字。

    .NOTES
        这里刻意用 System.Collections.Queue 的 Synchronized 包装，而不是
        ConcurrentQueue[string]：后者是 .NET 泛型类型，PowerShell 5.1 不支持
        [Type[string]] 这种写法，New-Object 会静默返回 $null（实测踩到过）。
    #>
    [CmdletBinding()]
    param()
    return , [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
}

function Receive-GuiOutput {
    <#
    .SYNOPSIS
        把队列里的文字取空，返回字符串数组（不会阻塞）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Queue)

    $lines = New-Object System.Collections.ArrayList
    while ($Queue.Count -gt 0) {
        $item = $Queue.Dequeue()
        if ($null -ne $item) { [void]$lines.Add([string]$item) }
    }
    return , $lines.ToArray()
}

function Test-GuiBusy {
    <#
    .SYNOPSIS
        判断异步句柄是否还在运行。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Handle)
    return (-not $Handle.IsCompleted)
}

function Wait-GuiHandle {
    <#
    .SYNOPSIS
        一边泵 WPF 消息（界面不假死）一边等异步任务完成；期间把队列里的文字交给回调。

    .PARAMETER Handle
        BeginInvoke 返回的 IAsyncResult。
    .PARAMETER Queue
        后台回传文字的并发队列。
    .PARAMETER OnOutput
        收到一批文字时调用的脚本块（参数为 string[]）。
    .PARAMETER OnTick
        每轮泵消息后调用的脚本块，用于驱动进度条等。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Handle,
        [Parameter(Mandatory)][object]$Queue,
        [scriptblock]$OnOutput,
        [scriptblock]$OnTick
    )

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
            try {
                if ($null -ne $OnOutput) {
                    $batch = Receive-GuiOutput -Queue $Queue
                    if ($batch.Count -gt 0) { & $OnOutput $batch }
                }
                if ($null -ne $OnTick) { & $OnTick }
            } catch {
                Write-ScanLog -Level Error -Message ("界面刷新出错：{0}" -f $_.Exception.Message)
            }
            if ($Handle.IsCompleted) {
                $timer.Stop()
                $frame.Continue = $false
            }
        })
    $timer.Start()

    try {
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } finally {
        $timer.Stop()
    }
}

function Start-GuiScan {
    <#
    .SYNOPSIS
        在后台启动一次完整扫描，返回 @{ Handle; Queue }。

    .NOTES
        后台 runspace 里重新点源 lib，保证与命令行版走完全相同的代码路径。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$BaseDirectory
    )

    $queue = Get-GuiOutputQueue
    $worker = {
        param([string]$RootPath, [object]$OutputQueue, [string]$BaseDirectory)

        $ErrorActionPreference = 'Stop'
        . (Join-Path $RootPath 'lib\Common.ps1')
        . (Join-Path $RootPath 'lib\Cleanup.Targets.ps1')
        . (Join-Path $RootPath 'lib\Cleanup.Snapshot.ps1')
        . (Join-Path $RootPath 'lib\Cleanup.Engine.ps1')
        . (Join-Path $RootPath 'lib\Scan.Disk.ps1')
        . (Join-Path $RootPath 'lib\Scan.System.ps1')
        . (Join-Path $RootPath 'lib\Scan.Power.ps1')

        # 扫描过程的文字改道到界面
        Set-OutputSink { param($Kind, $Text) $null = $OutputQueue.Enqueue([string]$Text) }

        # 报告/隔离区目录：优先用调用方指定的，没指定才退回仓库下的 Reports
        $baseDirectory = if ([string]::IsNullOrWhiteSpace($BaseDirectory)) { Join-Path $RootPath 'Reports' } else { $BaseDirectory }
        if (-not (Test-Path -LiteralPath $baseDirectory)) {
            New-Item -ItemType Directory -Path $baseDirectory -Force | Out-Null
        }
        $logPath = Initialize-ScanEnvironment -BaseDirectory $baseDirectory

        $profile = Get-SystemProfile
        $context = @{ Profile = $profile; LogPath = $logPath; BaseDirectory = $baseDirectory }

        $all = New-Object System.Collections.ArrayList
        foreach ($step in @(
                @{ Name = '磁盘空间'; Action = { Invoke-DiskScan -Context $context } }
                @{ Name = '系统状态'; Action = { Invoke-SystemScan -Context $context } }
                @{ Name = '电源方案'; Action = { Invoke-PowerScan -Context $context } }
            )) {
            $null = $OutputQueue.Enqueue(('正在检查 {0}…' -f $step.Name))
            try {
                foreach ($finding in (& $step.Action)) { [void]$all.Add($finding) }
            } catch {
                [void]$all.Add(@{
                        Id       = ('scan.' + $step.Name)
                        Severity = 'Info'
                        Title    = ('{0} 扫描失败' -f $step.Name)
                        Detail   = $_.Exception.Message
                        Advice   = '请把运行日志附在 Issue 里反馈。'
                        Evidence = @{}
                    })
            }
        }

        # 可清理项（复用命令行版的测量逻辑）
        $cleanupItems = @()
        try {
            $cleanupItems = @(Get-CleanupItem -BaseDirectory $baseDirectory)
        } catch {
            $null = $OutputQueue.Enqueue(('测量缓存时出错：{0}' -f $_.Exception.Message))
        }

        # 隔离区当前占用
        $quarantineBytes = [int64]0
        try { $quarantineBytes = Get-QuarantineTotalSize -BaseDirectory $baseDirectory } catch {
            $null = $OutputQueue.Enqueue(('统计隔离区失败：{0}' -f $_.Exception.Message))
        }

        Set-OutputSink $null
        return @{
            Profile         = $profile
            Findings        = @($all)
            CleanupItems    = @($cleanupItems)
            QuarantineBytes = $quarantineBytes
            LogPath         = $logPath
            BaseDirectory   = $baseDirectory
            WarningCount    = (Get-ScanWarningCount)
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $powerShell = [powershell]::Create()
    $powerShell.Runspace = $runspace
    $null = $powerShell.AddScript($worker.ToString()).AddArgument($Root).AddArgument($queue).AddArgument($BaseDirectory)
    $handle = $powerShell.BeginInvoke()

    return @{ Handle = $handle; Queue = $queue; PowerShell = $powerShell; Runspace = $runspace }
}

function Complete-GuiAsync {
    <#
    .SYNOPSIS
        收尾：取出结果、结束异步任务、释放 runspace。返回后台任务的返回值。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Task)

    $result = $null
    try {
        $output = $Task.PowerShell.EndInvoke($Task.Handle)
        foreach ($item in $output) { $result = $item }
        if ($Task.PowerShell.HadErrors) {
            $messages = @($Task.PowerShell.Streams.Error | ForEach-Object { $_.ToString() })
            if ($messages.Count -gt 0) {
                throw ('后台任务报错：' + ($messages -join '；'))
            }
        }
    } finally {
        $Task.PowerShell.Dispose()
        $Task.Runspace.Close()
        $Task.Runspace.Dispose()
    }
    return $result
}

function Start-GuiCleanup {
    <#
    .SYNOPSIS
        在后台启动一次清理（隔离），返回 @{ Handle; Queue }。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$TargetId,
        [string]$BaseDirectory
    )

    $queue = Get-GuiOutputQueue
    $budgetBytes = [int64]2GB

    $worker = {
        param([string]$RootPath, [object]$OutputQueue, [string[]]$Targets, [int64]$Budget, [string]$BaseDirectory)

        $ErrorActionPreference = 'Stop'
        . (Join-Path $RootPath 'lib\Common.ps1')
        . (Join-Path $RootPath 'lib\Cleanup.Targets.ps1')
        . (Join-Path $RootPath 'lib\Cleanup.Snapshot.ps1')
        . (Join-Path $RootPath 'lib\Cleanup.Engine.ps1')

        Set-OutputSink { param($Kind, $Text) $null = $OutputQueue.Enqueue([string]$Text) }

        $baseDirectory = if ([string]::IsNullOrWhiteSpace($BaseDirectory)) { Join-Path $RootPath 'Reports' } else { $BaseDirectory }
        $logPath = Initialize-ScanEnvironment -BaseDirectory $baseDirectory
        $profile = Get-SystemProfile

        $result = Invoke-CleanupRun -TargetId $Targets -BaseDirectory $baseDirectory `
            -Profile $profile -BudgetBytes $Budget

        $quarantineBytes = [int64]0
        try { $quarantineBytes = Get-QuarantineTotalSize -BaseDirectory $baseDirectory } catch {
            $null = $OutputQueue.Enqueue(('统计隔离区失败：{0}' -f $_.Exception.Message))
        }

        Set-OutputSink $null
        $result.QuarantineBytes = $quarantineBytes
        $result.LogPath = $logPath
        return $result
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $powerShell = [powershell]::Create()
    $powerShell.Runspace = $runspace
    $null = $powerShell.AddScript($worker.ToString()).AddArgument($Root).AddArgument($queue).AddArgument($TargetId).AddArgument($budgetBytes).AddArgument($BaseDirectory)
    $handle = $powerShell.BeginInvoke()

    return @{ Handle = $handle; Queue = $queue; PowerShell = $powerShell; Runspace = $runspace }
}

function Get-GuiQuarantineSummary {
    <#
    .SYNOPSIS
        隔离区摘要：文件数与体积，用于窗口右上角显示。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseDirectory)

    $snapshotRoot = Join-Path $BaseDirectory 'Snapshot'
    $result = @{ Count = 0; Bytes = [int64]0; Text = '隔离区：无' }
    if (-not (Test-Path -LiteralPath $snapshotRoot -PathType Container)) { return $result }

    $count = 0
    $bytes = [int64]0
    foreach ($manifest in @(Get-ChildItem -LiteralPath $snapshotRoot -Recurse -File -Filter 'manifest.json' -ErrorAction SilentlyContinue)) {
        try {
            $data = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            foreach ($change in @($data.changes)) {
                if ($null -eq $change) { continue }

                # 必须确认文件**此刻真的还在隔离区**。只数台账条目会把"已经还原过"的
                # 记录也算进来，界面上就会一直显示"还有 N 个文件可还原"（实际早就空的了）。
                $quarantine = [string]$change.QuarantineAs
                $candidate = Join-Path $manifest.Directory.FullName $quarantine
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $candidate = $quarantine
                }
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }

                $count++
                $bytes += [int64]$change.Bytes
            }
        } catch {
            Write-ScanLog -Level Warn -Message ("跳过无法解析的台账 {0}：{1}" -f $manifest.Name, $_.Exception.Message)
        }
    }

    $result.Count = $count
    $result.Bytes = $bytes
    if ($count -gt 0) {
        $result.Text = ('隔离区：{0} 个文件 / {1}（可还原）' -f $count, (ConvertTo-SizeText -Bytes $bytes))
    }
    return $result
}

function Restore-GuiQuarantine {
    <#
    .SYNOPSIS
        把隔离区里的文件全部移回原位。返回 @{ Restored; Already; Skipped; Failed; Bytes }。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseDirectory)

    $snapshotRoot = Join-Path $BaseDirectory 'Snapshot'
    $summary = @{ Restored = 0; Already = 0; Skipped = 0; Failed = 0; Bytes = [int64]0 }
    if (-not (Test-Path -LiteralPath $snapshotRoot -PathType Container)) { return $summary }

    $runDirectories = @(Get-ChildItem -LiteralPath $snapshotRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name -Descending)

    foreach ($dir in $runDirectories) {
        $manifestPath = Join-Path $dir.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-ScanLog -Level Warn -Message ("跳过无法解析的台账 {0}：{1}" -f $manifestPath, $_.Exception.Message)
            continue
        }

        foreach ($change in @($manifest.changes)) {
            if ($null -eq $change) { continue }
            $original = [string]$change.OriginalPath
            $quarantine = Join-Path $dir.FullName ([string]$change.QuarantineAs)
            if (-not (Test-Path -LiteralPath $quarantine -PathType Leaf)) {
                $quarantine = [string]$change.QuarantineAs
            }

            $inQuarantine = Test-Path -LiteralPath $quarantine -PathType Leaf
            $atOriginal = Test-Path -LiteralPath $original
            if (-not $inQuarantine -and $atOriginal) { $summary.Already++; continue }
            if (-not $inQuarantine) { $summary.Skipped++; continue }
            if ($atOriginal) { $summary.Skipped++; continue }

            try {
                $parent = Split-Path -Parent $original
                if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                Move-Item -LiteralPath $quarantine -Destination $original -Force -ErrorAction Stop
                $summary.Restored++
                $summary.Bytes += [int64]$change.Bytes
            } catch {
                Write-ScanLog -Level Error -Message ('还原失败 {0}：{1}' -f $original, $_.Exception.Message)
                $summary.Failed++
            }
        }
    }
    return $summary
}

function Get-GuiField {
    <#
    .SYNOPSIS
        从"可能是 Hashtable、也可能是 PSObject"的对象里安全取字段，统一返回字符串。

    .DESCRIPTION
        扫描结果在后台 runspace 里构造，回传后可能被 PSObject 包一层；
        这时 $item['Name'] 这种索引写法会抛 "Unable to index into an object of type PSObject"。
        本函数先试 Hashtable，再试 PSObject 属性，都没有就返回空字符串——不抛异常，
        因为界面渲染不值得为了一个缺字段而整体失败。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Item,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Item) { return '' }

    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name) -and $null -ne $Item[$Name]) { return [string]$Item[$Name] }
        return ''
    }

    $property = $Item.PSObject.Properties[$Name]
    if ($null -ne $property -and $null -ne $property.Value) { return [string]$property.Value }
    return ''
}

function Format-GuiFindings {
    <#
    .SYNOPSIS
        把 Finding 整理成界面表格能直接绑定的行（Severity 转成中文）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    $rows = New-Object System.Collections.ArrayList
    # 注意两点（都踩过）：
    #   1) Sort-Object 的表达式里只能用 $_，不能用外层 for 循环的变量名；
    #   2) 跨 runspace 回传后数组元素可能被 PSObject 包住，$_['Severity'] 这种索引会抛
    #      "Unable to index into an object of type PSObject"，所以统一用 Get-GuiField 取值。
    $ordered = @($Findings | Sort-Object -Property @{ Expression = { Get-SeverityRank -Severity (Get-GuiField -Item $_ -Name 'Severity') } })
    foreach ($finding in $ordered) {
        [void]$rows.Add([pscustomobject]@{
                Severity = (Get-SeverityLabel -Severity (Get-GuiField -Item $finding -Name 'Severity'))
                Title    = (Get-GuiField -Item $finding -Name 'Title')
                Detail   = (Get-GuiField -Item $finding -Name 'Detail')
                Advice   = (Get-GuiField -Item $finding -Name 'Advice')
            })
    }
    return , $rows.ToArray()
}

function Format-GuiCleanupItems {
    <#
    .SYNOPSIS
        把清理项整理成界面表格行；默认勾选体积达标的那些。

    .NOTES
        体积口径与命令行版一致：Bytes 是"会真正隔离"的部分；小于 1 MB 的小文件
        留在原处，单独用 Note 说明，避免用户以为工具少清了。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)

    $rows = New-Object System.Collections.ArrayList
    foreach ($item in $Items) {
        $bytes = [int64]$item['Bytes']
        $smallCount = [int]$item['SmallFileCount']
        $smallBytes = [int64]$item['SmallFileBytes']
        $enabled = ($bytes -gt 0)

        $note = ''
        if ($bytes -le 0 -and $smallCount -gt 0) {
            $note = ('只有 {0} 个小文件（小于 1 MB），本次不会清理' -f $smallCount)
        } elseif ($smallCount -gt 0) {
            $note = ('另有 {0}（{1} 个小于 1 MB 的小文件）会留在原处不清' -f (ConvertTo-SizeText -Bytes $smallBytes), $smallCount)
        }

        [void]$rows.Add([pscustomobject]@{
                Id        = [string]$item['Id']
                Selected  = [bool]($enabled -and ($bytes -ge [int64]$item['MinBytes']))
                Name      = [string]$item['Name']
                Bytes     = $bytes
                SizeText  = $(if ($bytes -gt 0) { ConvertTo-SizeText -Bytes $bytes } else { '0 B' })
                FileCount = [int]$item['FileCount']
                Note      = $note
                Safety    = [string]$item['Safety']
                Paths     = @($item['Paths'])
                Enabled   = $enabled
            })
    }
    return , $rows.ToArray()
}
