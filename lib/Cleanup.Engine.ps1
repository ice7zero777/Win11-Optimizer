#Requires -Version 5.1
<#
.SYNOPSIS
    清理引擎：测量缓存体积、按白名单枚举文件、执行隔离、汇总结果。

.DESCRIPTION
    分工：
      · Cleanup.Targets.ps1  —— 定义白名单与路径校验（铁律 L1）
      · Cleanup.Snapshot.ps1 —— 隔离区、台账、还原脚本
      · 本文件               —— 把上面两者串起来：测量 → 枚举 → 逐个隔离 → 汇总
      · Cleanup.Ui.ps1       —— 纯界面，负责让用户勾选与确认

    文件名为什么是 .psm1：lib 下的 .ps1 会被点源加载；为了让铁律检查器仍然扫描它，
    这里仍然用 .ps1 命名，由主入口点源引入。

.PARAMETER 约定
    所有执行类函数都接受 -WhatIfOnly，只统计不移动，用于演练。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    单个文件失败只记录并计数，绝不静默吞掉（铁律 L2）。
#>

Set-StrictMode -Version Latest

# 单文件小于这个体积就不值得移动：省不了多少空间，却要多做一次文件操作
$script:MinMoveFileBytes = 1MB

function Test-CleanupPathInsideBase {
    <#
    .SYNOPSIS
        判断路径是否位于工具自己的工作目录内（Reports / Snapshot / Logs）。
        这种路径永远不允许被清理，否则工具会吃掉自己的报告或隔离区。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BaseDirectory
    )

    # 两边都用规范化路径（含 8.3 短名还原），否则短名路径会绕过这个判断
    $full = Get-NormalizedPath -Path $Path
    $baseFull = Get-NormalizedPath -Path $BaseDirectory

    if ([string]::IsNullOrWhiteSpace($full) -or [string]::IsNullOrWhiteSpace($baseFull)) {
        Write-ScanLog -Level Warn -Message "路径规范化失败，按不允许清理处理：$Path"
        return $true
    }

    return $full.StartsWith($baseFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CleanupItem {
    <#
    .SYNOPSIS
        测量每个清理目标的体积与文件数，返回可交给 UI 渲染的清单项。

    .DESCRIPTION
        会排除两类文件，保证"测量的体积"和"能真正隔离的体积"对得上：
          · 单文件小于 1 MB 的（不值得移动，会被跳过并单独报告）
          · 位于工具自身工作目录内的（防止吃到自己的报告与隔离区）

    .OUTPUTS
        @(
          @{
            Id            = 'temp.user'
            Name          = '当前用户临时文件'
            Bytes         = int64    # 可以隔离的体积
            FileCount     = int
            SmallFileBytes = int64   # 因太小而会跳过的体积
            SmallFileCount = int
            Safety        = '...'
            Paths         = @('...')
            MinBytes      = int64    # 低于此值就不在界面上显示
            MeasuredAt    = datetime
          }
        )
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [switch]$SkipSlowScan
    )

    $items = New-Object System.Collections.ArrayList

    foreach ($target in (Get-CleanupTarget)) {
        $totalBytes = [int64]0
        $fileCount = 0
        $smallBytes = [int64]0
        $smallCount = 0
        $existingPaths = New-Object System.Collections.ArrayList

        foreach ($path in $target.Paths) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($path)
            if (-not (Test-Path -LiteralPath $expanded -PathType Container)) { continue }
            [void]$existingPaths.Add($expanded)

            $verdict = Test-CleanupPathAllowed -Path $expanded
            if (-not $verdict.Allowed) {
                Write-ScanLog -Level Error -Message "白名单校验异常，跳过 $expanded：$($verdict.Reason)"
                continue
            }
            if (Test-CleanupPathInsideBase -Path $expanded -BaseDirectory $BaseDirectory) {
                Write-ScanLog -Level Warn -Message "跳过工具自身目录：$expanded"
                continue
            }

            try {
                $files = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Force -ErrorAction Stop)
            } catch {
                Write-ScanLog -Level Warn -Message "无法枚举 $expanded：$($_.Exception.Message)"
                continue
            }

            foreach ($file in $files) {
                if (Test-CleanupPathInsideBase -Path $file.FullName -BaseDirectory $BaseDirectory) { continue }
                # 隔离区就在工作目录里，这里再挡一次，避免把上一次的隔离内容当成缓存清掉
                if ($file.FullName.IndexOf('\Snapshot\', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }

                try {
                    $size = [int64]$file.Length
                } catch {
                    Write-ScanLog -Level Warn -Message "无法读取大小：$($file.FullName)"
                    continue
                }

                if ($size -lt $script:MinMoveFileBytes) {
                    $smallBytes += $size
                    $smallCount++
                    continue
                }
                $totalBytes += $size
                $fileCount++
            }
        }

        if ($existingPaths.Count -eq 0) {
            Write-ScanLog -Level Info -Message "目标 $($target.Id) 在本机不存在，跳过"
            continue
        }

        $item = @{
            Id             = $target.Id
            Name           = $target.Name
            Bytes          = $totalBytes
            FileCount      = $fileCount
            SmallFileBytes = $smallBytes
            SmallFileCount = $smallCount
            Safety         = $target.Safety
            Paths          = $existingPaths.ToArray()
            MinBytes       = [int64]$target.MinBytes
            MeasuredAt     = (Get-Date)
        }
        [void]$items.Add($item)

        Write-ScanLog -Level Info -Message ('测量 {0}：可隔离 {1}（{2} 个文件），小于 1 MB 的 {3} 个' -f `
                $target.Id, (ConvertTo-SizeText -Bytes $totalBytes), $fileCount, $smallCount)
    }

    return $items.ToArray()
}

function Select-CleanupFile {
    <#
    .SYNOPSIS
        枚举某个清理目标下所有"够大且允许隔离"的文件。

    .OUTPUTS
        FileInfo 数组（用逗号返回，避免单条结果被解包）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$BaseDirectory
    )

    $selected = New-Object System.Collections.ArrayList
    $target = @(Get-CleanupTarget) | Where-Object { $_.Id -eq $TargetId } | Select-Object -First 1
    if ($null -eq $target) {
        Write-ScanLog -Level Error -Message "未知的清理目标：$TargetId"
        return @()
    }

    foreach ($path in $target.Paths) {
        $expanded = [System.Environment]::ExpandEnvironmentVariables($path)
        if (-not (Test-Path -LiteralPath $expanded -PathType Container)) { continue }

        try {
            $files = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Force -ErrorAction Stop)
        } catch {
            Write-ScanLog -Level Warn -Message "无法枚举 $expanded：$($_.Exception.Message)"
            continue
        }

        foreach ($file in $files) {
            if ($file.Length -lt $script:MinMoveFileBytes) { continue }
            if (Test-CleanupPathInsideBase -Path $file.FullName -BaseDirectory $BaseDirectory) { continue }
            if ($file.FullName.IndexOf('\Snapshot\', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }

            $verdict = Test-CleanupPathAllowed -Path $file.FullName
            if (-not $verdict.Allowed) {
                # 白名单没过的文件直接跳过，并记日志——这是最不该发生但又必须兜住的情况
                Write-ScanLog -Level Error -Message "拒绝隔离（$($verdict.Reason)）：$($file.FullName)"
                continue
            }
            [void]$selected.Add($file)
        }
    }

    return $selected.ToArray()
}

function Invoke-CleanupRun {
    <#
    .SYNOPSIS
        对选中的清理目标执行隔离，返回执行结果汇总。

    .OUTPUTS
        @{
          MovedCount   = int
          MovedBytes   = int64
          SkippedCount = int
          FailedCount  = int
          OverBudget   = [bool]
          Entries      = @()          # 台账条目
          ManifestPath = '...'
          RestoreScript= '...'
          PerTarget    = @( @{ Id=...; MovedBytes=...; MovedCount=... } )
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$TargetId,
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [int64]$BudgetBytes = 2GB,
        [switch]$WhatIfOnly
    )

    $run = New-SnapshotRun -BaseDirectory $BaseDirectory -BudgetBytes $BudgetBytes
    $perTarget = New-Object System.Collections.ArrayList
    $overBudget = $false

    foreach ($id in $TargetId) {
        $targetMoved = 0
        $targetBytes = [int64]0

        $files = Select-CleanupFile -TargetId $id -BaseDirectory $BaseDirectory
        Write-ScanLog -Level Info -Message ('开始隔离 {0}：{1} 个候选文件' -f $id, $files.Count)

        $index = 0
        foreach ($file in $files) {
            $index++
            $previousMoved = $run.MovedCount
            $result = Move-FileToQuarantine -SourcePath $file.FullName -Run $run -WhatIfOnly:$WhatIfOnly

            switch ($result.Status) {
                'Moved' {
                    $targetMoved++
                    $targetBytes += $result.Bytes
                }
                'OverBudget' {
                    $overBudget = $true
                    Write-ScanLog -Level Warn -Message $result.Reason
                    break
                }
                'Skipped' {
                    $run.SkippedCount++
                    [void]$run.Skipped.Add(@{ Path = $file.FullName; Reason = $result.Reason })
                }
                default {
                    $run.SkippedCount++
                    [void]$run.Skipped.Add(@{ Path = $file.FullName; Reason = $result.Reason })
                    Write-ScanLog -Level Error -Message ('隔离失败：{0} —— {1}' -f $file.FullName, $result.Reason)
                }
            }

            if ($overBudget) { break }

            if (($index % 500) -eq 0) {
                Write-Host ('     已处理 {0}/{1} 个文件…' -f $index, $files.Count) -ForegroundColor DarkGray
            }
        }

        [void]$perTarget.Add(@{
                Id         = $id
                MovedCount = $targetMoved
                MovedBytes = $targetBytes
            })

        Write-ScanLog -Level Info -Message ('隔离完成 {0}：{1} 个文件，{2}' -f $id, $targetMoved, (ConvertTo-SizeText -Bytes $targetBytes))

        if ($overBudget) { break }
    }

    $saved = Save-SnapshotManifest -Run $run -Profile $Profile -BaseDirectory $BaseDirectory

    return @{
        MovedCount    = $run.MovedCount
        MovedBytes    = $run.MovedBytes
        SkippedCount  = $run.SkippedCount
        FailedCount   = @($run.Skipped | Where-Object { $_.Reason -like '拒绝执行*' }).Count
        OverBudget    = $overBudget
        Entries       = @($run.Entries)
        ManifestPath  = $saved.ManifestPath
        RestoreScript = $saved.RestoreScript
        SnapshotRoot  = $run.SnapshotRoot
        PerTarget     = $perTarget.ToArray()
        IsDryRun      = [bool]$WhatIfOnly
    }
}

function Remove-ExpiredSnapshot {
    <#
    .SYNOPSIS
        清理过期的隔离区目录（默认保留最近 5 次）。

    .DESCRIPTION
        隔离区会一直占盘，所以提供一个明确的清理入口。只删除 Snapshot 下超过保留次数
        的时间戳目录，绝不触碰其它位置。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [int]$KeepCount = 5,
        [switch]$WhatIfOnly
    )

    $snapshotRoot = Join-Path $BaseDirectory 'Snapshot'
    if (-not (Test-Path -LiteralPath $snapshotRoot -PathType Container)) { return @() }

    $runs = @(Get-ChildItem -LiteralPath $snapshotRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name -Descending)

    $removed = New-Object System.Collections.ArrayList
    if ($runs.Count -le $KeepCount) { return $removed.ToArray() }

    foreach ($old in ($runs | Select-Object -Skip $KeepCount)) {
        if ($WhatIfOnly) {
            [void]$removed.Add($old.FullName)
            continue
        }
        try {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop
            [void]$removed.Add($old.FullName)
            Write-ScanLog -Level Info -Message "已清理过期隔离区：$($old.Name)"
        } catch {
            Write-ScanLog -Level Warn -Message "无法清理过期隔离区 $($old.Name)：$($_.Exception.Message)"
        }
    }
    return $removed.ToArray()
}
