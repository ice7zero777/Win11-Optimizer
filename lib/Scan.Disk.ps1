#Requires -Version 5.1
<#
.SYNOPSIS
    磁盘扫描：分区剩余空间、可直接清理的缓存体积、下载目录里的大文件。

.DESCRIPTION
    绝对只读。本文件不会删除任何文件、不会清空任何缓存、不会修改分区或系统设置，
    只做测量与解释，所有清理动作都留给用户自己决定。

    检测项：
      1. 有盘符的固定磁盘剩余比例。低于 15% 提示，低于 8% 严重。
      2. 常见的可清理缓存目录体积（临时目录、显卡着色器缓存、Windows 更新缓存）。
         只测量，读不到的目录如实标注为"未读取"。
      3. 下载目录里超过 1 GB 的单个文件（只列名字与大小，最多 5 个）。

.INPUTS
    $Context（hashtable，由主入口构造）：
      Profile  - Get-SystemProfile 的返回值
      LogPath  - 日志文件路径（可选）

.OUTPUTS
    Finding[]；无问题时返回空数组，绝不返回 $null。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    错误处理：所有可能失败的读取都在函数内部记日志，绝不静默吞错（铁律 L2）。
    路径：受保护的用户/系统目录一律用变量拼接，不写字面量路径（铁律 L1）。
#>

Set-StrictMode -Version Latest

# 可清理缓存目录：显示名 + 路径 + 来源变量。
# 注意：这里只收集路径，不做任何删除；是否存在由调用处逐个探测。
$script:CacheCandidates = @(
    @{ Name = '当前用户临时目录';        Path = { $env:TEMP } }
    @{ Name = 'NVIDIA 着色器缓存';       Path = { Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache' } }
    @{ Name = 'NVIDIA OpenGL 着色器缓存'; Path = { Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache' } }
    @{ Name = 'AMD 着色器缓存';           Path = { Join-Path $env:LOCALAPPDATA 'AMD\DxCache' } }
    @{ Name = 'DirectX 着色器缓存';       Path = { Join-Path $env:LOCALAPPDATA 'D3DSCache' } }
    @{ Name = 'Windows 更新缓存';         Path = { Join-Path $env:WINDIR 'SoftwareDistribution\Download' } }
)

function Get-DiskVolumeInfo {
    <#
    .SYNOPSIS
        列出本机固定磁盘（有盘符）的容量与剩余空间；Get-Volume 不可用时回退到 DriveInfo。
    #>
    [CmdletBinding()]
    param()

    $volumes = New-Object System.Collections.ArrayList
    $volumeError = $null

    try {
        $rawVolumes = @(Get-Volume -ErrorAction Stop | Where-Object { $null -ne $_.DriveLetter })
        foreach ($volume in $rawVolumes) {
            if ($volume.DriveType -ne 'Fixed') { continue }
            $size = [int64]$volume.Size
            if ($size -le 0) { continue }

            $label = [string]$volume.FileSystemLabel
            if ([string]::IsNullOrWhiteSpace($label)) { $label = '本地磁盘' }

            [void]$volumes.Add([pscustomobject]@{
                Letter        = ([string]$volume.DriveLetter).ToUpperInvariant()
                Label         = $label
                FileSystem    = [string]$volume.FileSystem
                Size          = $size
                SizeRemaining = [int64]$volume.SizeRemaining
            })
        }
    } catch {
        $volumeError = $_.Exception.Message
    }

    if ($volumes.Count -eq 0) {
        if ($volumeError) {
            Write-ScanLog -Level Warn -Message "Get-Volume 不可用（$volumeError），改用 DriveInfo 读取磁盘容量。"
        } else {
            Write-ScanLog -Level Warn -Message 'Get-Volume 未返回任何固定磁盘，改用 DriveInfo 读取磁盘容量。'
        }

        $index = 0
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            $index++
            try {
                if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
                if (-not $drive.IsReady) { continue }
                [void]$volumes.Add([pscustomobject]@{
                    Letter        = $drive.Name.TrimEnd('\').TrimEnd(':').ToUpperInvariant()
                    Label         = '本地磁盘'
                    FileSystem    = [string]$drive.DriveFormat
                    Size          = [int64]$drive.TotalSize
                    SizeRemaining = [int64]$drive.AvailableFreeSpace
                })
            } catch {
                Write-ScanLog -Level Warn -Message "读取第 $index 个磁盘容量失败：$($_.Exception.Message)"
            }
        }
    }

    return ,$volumes.ToArray()
}

function New-DiskSpaceFinding {
    <#
    .SYNOPSIS
        根据剩余比例给单个分区生成空间告警；空间充足时返回 $null。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Volume)

    if ($Volume.Size -le 0) { return $null }

    $freePct = [math]::Round($Volume.SizeRemaining / $Volume.Size * 100, 1)
    if ($freePct -ge 15) { return $null }

    $freeText = ConvertTo-SizeText -Bytes $Volume.SizeRemaining
    $sizeText = ConvertTo-SizeText -Bytes $Volume.Size
    $letter = $Volume.Letter

    $severity = 'High'
    if ($freePct -lt 8) { $severity = 'Critical' }

    $detail = ('{0} 盘只剩 {1}（{2}%），总容量 {3}。Windows 在系统盘剩余低于 15% 时会明显变慢：更新、虚拟内存文件和临时文件都要用到这块空间。' -f $letter, $freeText, $freePct, $sizeText)

    $title = ('{0} 盘只剩 {1}（{2}%）' -f $letter, $freeText, $freePct)

    return New-Finding `
        -Id ('disk.low-space-{0}' -f $letter.ToLowerInvariant()) `
        -Module 'disk' `
        -Severity $severity `
        -Title $title `
        -Detail $detail `
        -Evidence ([ordered]@{
            '盘符'       = ('{0}:' -f $letter)
            '卷标'       = $Volume.Label
            '文件系统'   = $Volume.FileSystem
            '总容量'     = $sizeText
            '剩余空间'   = $freeText
            '剩余比例'   = ('{0}%' -f $freePct)
            '判断阈值'   = '低于 15% 提示，低于 8% 严重'
        }) `
        -Advice '先清理下面列出的缓存，再看下载文件夹里有没有能删掉的大文件。清理前请自己确认文件确实不需要保留，本工具不会代你删除任何东西。'
}

function New-CacheBloatFinding {
    <#
    .SYNOPSIS
        测量可清理缓存目录体积；超过 1 GB 时生成一条提示。只测量，不删除。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $entries = New-Object System.Collections.ArrayList
    $totalBytes = [int64]0
    $largest = $null

    foreach ($candidate in $script:CacheCandidates) {
        $path = $null
        try {
            $path = & $candidate.Path
        } catch {
            Write-ScanLog -Level Warn -Message "无法解析缓存目录 $($candidate.Name) 的路径：$($_.Exception.Message)"
        }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            [void]$entries.Add([pscustomobject]@{
                Name    = $candidate.Name
                Bytes   = [int64]0
                Text    = '目录不存在'
                Skipped = 0
            })
            continue
        }

        $size = Get-FolderSize -Path $path -MaxSeconds 15
        $bytes = [int64]$size.Bytes
        $totalBytes += $bytes

        $text = ConvertTo-SizeText -Bytes $bytes
        if ($size.Skipped -gt 0) { $text = '{0}（{1} 个文件未读取）' -f $text, $size.Skipped }
        if ($size.FileCount -eq 0 -and $size.Skipped -eq 0) { $text = '空目录' }

        $entry = [pscustomobject]@{
            Name    = $candidate.Name
            Bytes   = $bytes
            Text    = $text
            Skipped = $size.Skipped
        }
        [void]$entries.Add($entry)

        if ($null -eq $largest -or $entry.Bytes -gt $largest.Bytes) { $largest = $entry }
    }

    if ($null -eq $largest -or $largest.Bytes -le 1GB) { return $null }

    $severity = 'Low'
    if ($totalBytes -gt 5GB) { $severity = 'Medium' }

    $evidence = [ordered]@{}
    foreach ($entry in ($entries | Sort-Object Bytes -Descending)) {
        $evidence[$entry.Name] = $entry.Text
    }
    $evidence['合计'] = ConvertTo-SizeText -Bytes $totalBytes

    $totalText = ConvertTo-SizeText -Bytes $totalBytes
    $largestText = ConvertTo-SizeText -Bytes $largest.Bytes

    return New-Finding `
        -Id 'disk.purgeable-cache' `
        -Module 'disk' `
        -Severity $severity `
        -Title ('缓存文件占用 {0}，其中最大的一项 {1}' -f $totalText, $largestText) `
        -Detail ('这些目录里放的都是可以重新生成的缓存，合计 {0}。其中最大的是"{1}"（{2}）。它们不会影响系统正常运行，但会长期占用磁盘空间。' -f $totalText, $largest.Name, $largestText) `
        -Evidence $evidence `
        -Advice '可以在"存储设置 → 临时文件"里手动清理，或按上面的目录清单自己核对后删除。本工具只负责测量，不会替你删文件。'
}

function New-DownloadsLargeFileFinding {
    <#
    .SYNOPSIS
        列出下载目录里超过 1 GB 的单个文件（最多 5 个）。只列出，绝不删除。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path -LiteralPath $downloads -PathType Container)) {
        Write-ScanLog -Level Info -Message '未找到下载目录，跳过大文件检查。'
        return $null
    }

    $threshold = 1GB
    try {
        $largeFiles = @(Get-ChildItem -LiteralPath $downloads -File -Force -ErrorAction Stop |
            Where-Object { $_.Length -gt $threshold } |
            Sort-Object Length -Descending |
            Select-Object -First 5)
    } catch {
        Write-ScanLog -Level Warn -Message "读取下载目录失败：$($_.Exception.Message)"
        return $null
    }

    if ($largeFiles.Count -eq 0) { return $null }

    $lines = New-Object System.Collections.ArrayList
    $totalBytes = [int64]0
    foreach ($file in $largeFiles) {
        $totalBytes += $file.Length
        [void]$lines.Add(('{0}（{1}）' -f $file.Name, (ConvertTo-SizeText -Bytes $file.Length)))
    }

    return New-Finding `
        -Id 'disk.downloads-large-files' `
        -Module 'disk' `
        -Severity 'Info' `
        -Title ('下载文件夹里有 {0} 个超过 1 GB 的文件' -f $largeFiles.Count) `
        -Detail ('下载目录里有 {0} 个大于 1 GB 的文件，合计约 {1}。装过的安装包、看过的视频通常不再需要，但删除前请自己确认。' -f $largeFiles.Count, (ConvertTo-SizeText -Bytes $totalBytes)) `
        -Evidence ([ordered]@{ '大文件清单' = ($lines -join '；') }) `
        -Advice '在文件资源管理器里逐个确认后自行处理。本工具只列出名字和大小，不会移动或删除它们。'
}

function Invoke-DiskScan {
    <#
    .SYNOPSIS
        磁盘扫描总入口：分区剩余空间、可清理缓存体积、下载目录大文件。

    .OUTPUTS
        Finding[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [string]$LogPath = $null
    )

    if (-not $LogPath -and $Context.ContainsKey('LogPath')) { $LogPath = $Context.LogPath }
    if ($LogPath) { $script:ScanLogPath = $LogPath }

    $findings = New-Object System.Collections.ArrayList

    Write-ScanLog -Level Info -Message '开始检查磁盘剩余空间…'
    $volumes = Get-DiskVolumeInfo
    foreach ($volume in $volumes) {
        $finding = New-DiskSpaceFinding -Volume $volume
        if ($null -ne $finding) { [void]$findings.Add($finding) }
    }
    Write-ScanLog -Level Info -Message ('磁盘空间检查完成：共检查 {0} 个固定磁盘，生成 {1} 条提示' -f $volumes.Count, $findings.Count)

    Write-ScanLog -Level Info -Message '开始测量可清理缓存体积（只测量，不删除）…'
    $cacheFinding = New-CacheBloatFinding -Context $Context
    if ($null -ne $cacheFinding) { [void]$findings.Add($cacheFinding) }

    Write-ScanLog -Level Info -Message '开始检查下载目录里的大文件…'
    $downloadFinding = New-DownloadsLargeFileFinding -Context $Context
    if ($null -ne $downloadFinding) { [void]$findings.Add($downloadFinding) }

    # 前置逗号避免只有一条结果时被解包成单个对象，调用处才能直接取 .Count。
    return ,$findings.ToArray()
}
