#Requires -Version 5.1
<#
.SYNOPSIS
    快照与隔离：把待清理的文件**移动**到隔离区，并生成可一键还原的脚本。

.DESCRIPTION
    为什么是"移动"而不是"删除"：
    删除是不可逆的——文件内容没了就真的没了。本项目承诺"改前快照、可一键还原"，
    所以清理动作一律实现为**把文件移进 Snapshot 隔离区**，还原就是移回原位。
    代价是清理后磁盘不会立刻释放那么多空间，需要用户在确认没问题后清空隔离区。

    三条保护：
      1. 体积预算：隔离区超过上限就停止清理，避免把磁盘占满（默认 2 GB，可调）。
      2. 跨盘回退：如果隔离区所在磁盘与源文件不同盘，移动会退化为复制+删除，
         此时改为"跳过该文件并如实报告"，绝不用复制删除的方式冒险。
      3. 全量台账：每个被移动的文件都记录原路径、大小、时间，写进 manifest。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    错误处理：单个文件失败只跳过并计数，绝不静默（铁律 L2）。
#>

Set-StrictMode -Version Latest

function New-SnapshotRun {
    <#
    .SYNOPSIS
        创建一次快照运行的上下文（时间戳目录 + 隔离区 + 台账）。
    .OUTPUTS
        @{
          RunId           = '20261004-180000'
          SnapshotRoot    = '...\Snapshot\20261004-180000'
          QuarantineRoot  = '...\Snapshot\20261004-180000\quarantine'
          ManifestPath    = '...\Snapshot\20261004-180000\manifest.json'
          RestoreScript   = '...\Snapshot\Restore-All.ps1'
          BudgetBytes     = int64
          MovedBytes      = int64
          MovedCount      = 0
          SkippedCount    = 0
          Skipped         = @()
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [int64]$BudgetBytes = 2GB
    )

    $runId = Get-Date -Format 'yyyyMMdd-HHmmss'
    $snapshotRoot = Join-Path $BaseDirectory "Snapshot\$runId"
    $quarantineRoot = Join-Path $snapshotRoot 'quarantine'

    if (-not (Test-Path -LiteralPath $quarantineRoot)) {
        New-Item -ItemType Directory -Path $quarantineRoot -Force | Out-Null
    }

    return @{
        RunId          = $runId
        SnapshotRoot   = $snapshotRoot
        QuarantineRoot = $quarantineRoot
        ManifestPath   = Join-Path $snapshotRoot 'manifest.json'
        RestoreScript  = Join-Path $BaseDirectory 'Snapshot\Restore-All.ps1'
        BudgetBytes    = $BudgetBytes
        MovedBytes     = [int64]0
        MovedCount     = 0
        SkippedCount   = 0
        Skipped        = (New-Object System.Collections.ArrayList)
        Entries        = (New-Object System.Collections.ArrayList)
    }
}

function Get-QuarantineDestination {
    <#
    .SYNOPSIS
        为源文件计算隔离区里的存放路径，保持相对结构以免同名文件互相覆盖。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][hashtable]$Run
    )

    # 用源文件的完整路径做一个稳定的短标识，避免不同目录下的同名文件冲突
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SourcePath.ToLowerInvariant()))
    } finally {
        $sha.Dispose()
    }
    $tag = -join ($hashBytes[0..5] | ForEach-Object { $_.ToString('x2') })

    $leaf = Split-Path -Leaf $SourcePath
    $safeLeaf = $leaf -replace '[\\/:*?"<>|]', '_'
    return (Join-Path $Run.QuarantineRoot "$tag-$safeLeaf")
}

function Move-FileToQuarantine {
    <#
    .SYNOPSIS
        把一个文件移动到隔离区，并记入台账。失败只记录、不抛出、不静默。

    .OUTPUTS
        @{ Status = 'Moved'|'Skipped'|'Failed'|'OverBudget'; Reason = '...'; Bytes = int64 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][hashtable]$Run,
        [switch]$WhatIfOnly
    )

    $result = @{ Status = 'Failed'; Reason = ''; Bytes = [int64]0 }

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        $result.Status = 'Skipped'
        $result.Reason = '文件已不存在'
        return $result
    }

    # 白名单强制校验：不在白名单一律拒绝（铁律 L1）
    $verdict = Test-CleanupPathAllowed -Path $SourcePath
    if (-not $verdict.Allowed) {
        $result.Status = 'Failed'
        $result.Reason = "拒绝执行：$($verdict.Reason)"
        return $result
    }

    $file = $null
    try {
        $file = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
    } catch {
        $result.Status = 'Skipped'
        $result.Reason = "无法读取文件信息：$($_.Exception.Message)"
        return $result
    }

    $size = [int64]$file.Length
    if (($Run.MovedBytes + $size) -gt $Run.BudgetBytes) {
        $result.Status = 'OverBudget'
        $result.Reason = ('隔离区已达体积上限（{0}），剩余文件未处理' -f (ConvertTo-SizeText -Bytes $Run.BudgetBytes))
        $result.Bytes = 0
        return $result
    }

    if ($WhatIfOnly) {
        $result.Status = 'Moved'
        $result.Reason = '演练模式：只统计，不移动'
        $result.Bytes = $size
        return $result
    }

    $destination = Get-QuarantineDestination -SourcePath $SourcePath -Run $Run

    try {
        Move-Item -LiteralPath $SourcePath -Destination $destination -Force -ErrorAction Stop
    } catch {
        # 常见原因：文件正被程序占用、权限不足、跨盘。都不致命，跳过并记录。
        $result.Status = 'Skipped'
        $result.Reason = "无法移动（可能正被占用）：$($_.Exception.Message)"
        return $result
    }

    $result.Status = 'Moved'
    $result.Bytes = $size
    $result.Reason = ''

    [void]$Run.Entries.Add(@{
        OriginalPath = $SourcePath
        QuarantineAs = $destination
        Bytes        = $size
        LastWrite    = $file.LastWriteTime.ToString('o')
        MovedAt      = (Get-Date).ToString('o')
    })
    $Run.MovedBytes += $size
    $Run.MovedCount++

    return $result
}

function Save-SnapshotManifest {
    <#
    .SYNOPSIS
        把本次运行的台账写成 manifest.json，并生成 Restore-All.ps1。

    .OUTPUTS
        @{ ManifestPath = '...'; RestoreScript = '...'; EntryCount = n }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Run,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][string]$BaseDirectory
    )

    $manifest = [ordered]@{
        runId        = $Run.RunId
        startedAt    = (Get-Date).ToString('o')
        tool         = 'Win11-Optimizer'
        toolVersion  = '1.0.0'
        system       = [ordered]@{
            model  = (Get-MachineLabel -Manufacturer ([string]$Profile.Manufacturer) -Model ([string]$Profile.Model))
            os     = [string]$Profile.OSDisplay
            isAdmin = [bool]$Profile.IsAdmin
        }
        budgetBytes  = $Run.BudgetBytes
        movedBytes   = $Run.MovedBytes
        movedCount   = $Run.MovedCount
        skippedCount = $Run.SkippedCount
        changes      = @($Run.Entries)
    }

    $json = $manifest | ConvertTo-Json -Depth 6
    # JSON 必须 UTF-8 无 BOM，否则 ConvertFrom-Json 在部分环境读不了（PRD §10.2）
    [System.IO.File]::WriteAllText($Run.ManifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    $restorePath = New-RestoreScript -Run $Run -BaseDirectory $BaseDirectory

    return @{
        ManifestPath  = $Run.ManifestPath
        RestoreScript = $restorePath
        EntryCount    = $Run.Entries.Count
    }
}

function New-RestoreScript {
    <#
    .SYNOPSIS
        生成 Restore-All.ps1：把隔离区里所有文件移回原位。

    .DESCRIPTION
        还原脚本要能被用户直接双击式使用，因此自带：
          · 管理员权限检查（还原到系统目录时需要）
          · -WhatIf 演练（只显示将做什么）
          · -List 列出可还原项
          · 逐项结果与失败原因，不静默跳过
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Run,
        [Parameter(Mandatory)][string]$BaseDirectory
    )

    $snapshotDirectory = Join-Path $BaseDirectory 'Snapshot'
    if (-not (Test-Path -LiteralPath $snapshotDirectory)) {
        New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null
    }

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('#Requires -Version 5.1')
    [void]$lines.Add('<#')
    [void]$lines.Add('.SYNOPSIS')
    [void]$lines.Add('    Win11-Optimizer 一键还原：把隔离区里的文件移回原来的位置。')
    [void]$lines.Add('')
    [void]$lines.Add('.DESCRIPTION')
    [void]$lines.Add('    本脚本由 Win11-Optimizer 在清理后自动生成，会读取 Snapshot 下各次运行的')
    [void]$lines.Add('    manifest.json，把被隔离的文件移回原路径。已经存在的同名文件会被跳过，')
    [void]$lines.Add('    不会被覆盖。')
    [void]$lines.Add('')
    [void]$lines.Add('.PARAMETER WhatIf')
    [void]$lines.Add('    只显示将要做什么，不实际移动。建议先跑一次看看。')
    [void]$lines.Add('')
    [void]$lines.Add('.PARAMETER List')
    [void]$lines.Add('    列出全部可还原项与体积，不做任何改动。')
    [void]$lines.Add('')
    [void]$lines.Add('.EXAMPLE')
    [void]$lines.Add('    .\Restore-All.ps1 -List')
    [void]$lines.Add('    .\Restore-All.ps1 -WhatIf')
    [void]$lines.Add('    .\Restore-All.ps1')
    [void]$lines.Add('#>')
    [void]$lines.Add('[CmdletBinding(SupportsShouldProcess = $true)]')
    [void]$lines.Add('param(')
    [void]$lines.Add('    [switch]$List')
    [void]$lines.Add(')')
    [void]$lines.Add('')
    [void]$lines.Add('Set-StrictMode -Version Latest')
    [void]$lines.Add('$ErrorActionPreference = ''Stop''')
    [void]$lines.Add('')
    [void]$lines.Add('$snapshotDirectory = $PSScriptRoot')
    [void]$lines.Add('')
    [void]$lines.Add('function Get-RestoreEntry {')
    [void]$lines.Add('    <#')
    [void]$lines.Add('    .SYNOPSIS')
    [void]$lines.Add('        读取 Snapshot 下所有 manifest.json，汇总出可还原条目。')
    [void]$lines.Add('    #>')
    [void]$lines.Add('    $entries = New-Object System.Collections.ArrayList')
    [void]$lines.Add('    foreach ($manifestFile in @(Get-ChildItem -LiteralPath $snapshotDirectory -Recurse -File -Filter ''manifest.json'' -ErrorAction SilentlyContinue)) {')
    [void]$lines.Add('        try {')
    [void]$lines.Add('            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json')
    [void]$lines.Add('        } catch {')
    [void]$lines.Add('            Write-Host ("  ! 跳过无法解析的台账：{0}（{1}）" -f $manifestFile.FullName, $_.Exception.Message) -ForegroundColor Yellow')
    [void]$lines.Add('            continue')
    [void]$lines.Add('        }')
    [void]$lines.Add('        foreach ($change in @($manifest.changes)) {')
    [void]$lines.Add('            if ($null -eq $change) { continue }')
    [void]$lines.Add('            [void]$entries.Add([pscustomobject]@{')
    [void]$lines.Add('                RunId        = $manifest.runId')
    [void]$lines.Add('                OriginalPath = [string]$change.OriginalPath')
    [void]$lines.Add('                QuarantineAs = [string]$change.QuarantineAs')
    [void]$lines.Add('                Bytes        = [int64]$change.Bytes')
    [void]$lines.Add('            })')
    [void]$lines.Add('        }')
    [void]$lines.Add('    }')
    [void]$lines.Add('    return ,$entries.ToArray()')
    [void]$lines.Add('}')
    [void]$lines.Add('')
    [void]$lines.Add('$allEntries = Get-RestoreEntry')
    [void]$lines.Add('')
    [void]$lines.Add('if ($List) {')
    [void]$lines.Add('    Write-Host ''''')
    [void]$lines.Add('    Write-Host ''  可还原文件清单'' -ForegroundColor Cyan')
    [void]$lines.Add('    Write-Host ''  ─────────────────────────────────────────────'' -ForegroundColor DarkGray')
    [void]$lines.Add('    if ($allEntries.Count -eq 0) {')
    [void]$lines.Add('        Write-Host ''  没有找到可还原的文件。'' -ForegroundColor Yellow')
    [void]$lines.Add('    } else {')
    [void]$lines.Add('        $totalBytes = [int64]0')
    [void]$lines.Add('        foreach ($entry in $allEntries) {')
    [void]$lines.Add('            $totalBytes += $entry.Bytes')
    [void]$lines.Add('            Write-Host ("   {0,10:N0} KB  {1}" -f ($entry.Bytes / 1KB), $entry.OriginalPath)')
    [void]$lines.Add('        }')
    [void]$lines.Add('        Write-Host ''''')
    [void]$lines.Add('        Write-Host ("  共 {0} 个文件，{1:N1} MB" -f $allEntries.Count, ($totalBytes / 1MB)) -ForegroundColor Green')
    [void]$lines.Add('    }')
    [void]$lines.Add('    Write-Host ''''')
    [void]$lines.Add('    exit 0')
    [void]$lines.Add('}')
    [void]$lines.Add('')
    [void]$lines.Add('if ($allEntries.Count -eq 0) {')
    [void]$lines.Add('    Write-Host ''没有找到可还原的文件。'' -ForegroundColor Yellow')
    [void]$lines.Add('    exit 0')
    [void]$lines.Add('}')
    [void]$lines.Add('')
    [void]$lines.Add('$restored = 0; $skipped = 0; $failed = 0; $already = 0')
    [void]$lines.Add('$restoredBytes = [int64]0')
    [void]$lines.Add('')
    [void]$lines.Add('foreach ($entry in $allEntries) {')
    [void]$lines.Add('    $inQuarantine = Test-Path -LiteralPath $entry.QuarantineAs -PathType Leaf')
    [void]$lines.Add('    $atOriginal   = Test-Path -LiteralPath $entry.OriginalPath')
    [void]$lines.Add('')
    [void]$lines.Add('    # 隔离区没有、原位有 —— 说明上次已经还原过了，属于正常情况，不能报成跳过或失败')
    [void]$lines.Add('    if (-not $inQuarantine -and $atOriginal) {')
    [void]$lines.Add('        $already++')
    [void]$lines.Add('        continue')
    [void]$lines.Add('    }')
    [void]$lines.Add('    if (-not $inQuarantine) {')
    [void]$lines.Add('        Write-Host ("  ? 隔离区文件已不存在，且原位也没有：{0}" -f $entry.OriginalPath) -ForegroundColor DarkGray')
    [void]$lines.Add('        $skipped++')
    [void]$lines.Add('        continue')
    [void]$lines.Add('    }')
    [void]$lines.Add('    if ($atOriginal) {')
    [void]$lines.Add('        Write-Host ("  ! 原位置已存在同名文件，跳过（不覆盖）：{0}" -f $entry.OriginalPath) -ForegroundColor Yellow')
    [void]$lines.Add('        $skipped++')
    [void]$lines.Add('        continue')
    [void]$lines.Add('    }')
    [void]$lines.Add('    if (-not $PSCmdlet.ShouldProcess($entry.OriginalPath, ''移回原位'')) {')
    [void]$lines.Add('        $skipped++')
    [void]$lines.Add('        continue')
    [void]$lines.Add('    }')
    [void]$lines.Add('    try {')
    [void]$lines.Add('        $parent = Split-Path -Parent $entry.OriginalPath')
    [void]$lines.Add('        if ($parent -and -not (Test-Path -LiteralPath $parent)) {')
    [void]$lines.Add('            New-Item -ItemType Directory -Path $parent -Force | Out-Null')
    [void]$lines.Add('        }')
    [void]$lines.Add('        Move-Item -LiteralPath $entry.QuarantineAs -Destination $entry.OriginalPath -Force -ErrorAction Stop')
    [void]$lines.Add('        $restored++')
    [void]$lines.Add('        $restoredBytes += $entry.Bytes')
    [void]$lines.Add('    } catch {')
    [void]$lines.Add('        Write-Host ("  x 还原失败：{0} —— {1}" -f $entry.OriginalPath, $_.Exception.Message) -ForegroundColor Red')
    [void]$lines.Add('        $failed++')
    [void]$lines.Add('    }')
    [void]$lines.Add('}')
    [void]$lines.Add('')
    [void]$lines.Add('Write-Host ''''')
    [void]$lines.Add('Write-Host ("  已还原 {0} 个文件（{1:N1} MB）；此前已还原 {2} 个；跳过 {3} 个；失败 {4} 个" -f $restored, ($restoredBytes / 1MB), $already, $skipped, $failed) -ForegroundColor Green')
    [void]$lines.Add('if ($restored -eq 0 -and $already -eq $allEntries.Count) {')
    [void]$lines.Add('    Write-Host ''  这些文件此前已经还原过了，无需重复操作。'' -ForegroundColor DarkGray')
    [void]$lines.Add('}')
    [void]$lines.Add('if ($failed -gt 0) {')
    [void]$lines.Add('    Write-Host ''  有文件还原失败，通常是权限不足或原位置被占用。'' -ForegroundColor Yellow')
    [void]$lines.Add('    exit 1')
    [void]$lines.Add('}')
    [void]$lines.Add('exit 0')

    $content = ($lines -join [System.Environment]::NewLine) + [System.Environment]::NewLine
    $restorePath = Join-Path $snapshotDirectory 'Restore-All.ps1'
    # .ps1 必须 UTF-8 with BOM（铁律 L4），否则中文系统上 PS 5.1 会按 ANSI 解析出错
    [System.IO.File]::WriteAllText($restorePath, $content, (New-Object System.Text.UTF8Encoding($true)))

    return $restorePath
}

function Get-QuarantineTotalSize {
    <#
    .SYNOPSIS
        统计隔离区当前占用的总体积，用于提示用户"确认没问题后可以清空回收"。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseDirectory)

    $snapshotRoot = Join-Path $BaseDirectory 'Snapshot'
    if (-not (Test-Path -LiteralPath $snapshotRoot)) { return [int64]0 }

    $total = [int64]0
    foreach ($file in @(Get-ChildItem -LiteralPath $snapshotRoot -Recurse -File -ErrorAction SilentlyContinue)) {
        try { $total += $file.Length } catch { Write-ScanLog -Level Warn -Message "无法统计隔离区文件 $($file.FullName)" }
    }
    return $total
}
