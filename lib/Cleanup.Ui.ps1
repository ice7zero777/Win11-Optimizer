#Requires -Version 5.1
<#
.SYNOPSIS
    Win11-Optimizer v1.0 清理功能的控制台交互 UI：渲染清理清单、收集勾选、二次确认。

.DESCRIPTION
    本文件只负责"问"，不负责"做"：它把清理目标渲染成普通人看得懂的清单，收集用户勾选，
    再把将要发生的事讲清楚，并要求用户输入 yes 确认。真正的文件移动在 Cleanup.Snapshot.ps1，
    本文件不含任何删除、移动或修改系统的命令。

    对外提供两个函数（签名固定，由主入口调用）：
      Show-CleanupList         -Items <object[]>                                  -> string[]
      Read-CleanupConfirmation -SelectedItems <object[]> -EstimatedBytes <int64>  -> [bool]

    清单项字段（hashtable 与 pscustomobject 都支持）：
      Id / Name / Bytes / FileCount / SmallFileBytes / SmallFileCount / Safety / Paths / MinBytes
      · Bytes          本次会真正隔离的体积（引擎只隔离不小于 1 MB 的文件）
      · FileCount      本次会隔离的文件数
      · SmallFileBytes 因小于 1 MB 而留在原处的体积
      · SmallFileCount 因小于 1 MB 而留在原处的文件数

    界面必须把"留在原处的小文件"如实告诉用户，否则用户会以为工具少清了东西。
    汇总里的"预计隔离"只累加 Bytes，绝不把小文件的体积算进去。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    错误处理：任何异常都要说明原因，不允许静默失败（铁律 L2）。
    安全：本文件只读界面，不做任何写操作（铁律 L1）。
    依赖：Common.ps1 的 Write-Headline / Write-Item / Write-Note / Write-ScanLog /
          ConvertTo-SizeText；调用本文件前必须先点源 Common.ps1。
    非交互环境（标准输入被重定向）下两个函数立即返回空数组 / $false，绝不等待输入。
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# 内部工具：字段读取
# ---------------------------------------------------------------------------
function Get-CleanupItemValue {
    <#
    .SYNOPSIS
        从清单项上安全地取一个字段（hashtable 与 pscustomobject 都支持）。

    .DESCRIPTION
        字段缺失或为 $null 时返回 $Default，不抛异常，避免把界面流程打断。

    .OUTPUTS
        字段值，或 $Default。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Item) { return $Default }

    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Key)) {
            $value = $Item[$Key]
            if ($null -eq $value) { return $Default }
            return $value
        }
        return $Default
    }

    $property = $Item.PSObject.Properties[$Key]
    if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    return $Default
}

function Get-CleanupItemInt64 {
    <#
    .SYNOPSIS
        取一个 int64 字段；缺失或不是数字时按 0 处理，并在日志里留下原因。

    .OUTPUTS
        [int64]
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][string]$Key
    )

    $raw = Get-CleanupItemValue -Item $Item -Key $Key -Default $null
    if ($null -eq $raw) { return [int64]0 }

    $parsed = [int64]0
    if ([int64]::TryParse([string]$raw, [ref]$parsed)) { return $parsed }

    Write-ScanLog -Level Warn -Message ("清单字段 {0} 的值「{1}」不是有效数字，界面按 0 处理。" -f $Key, $raw)
    return [int64]0
}

# ---------------------------------------------------------------------------
# 内部工具：交互接缝
# ---------------------------------------------------------------------------
function Test-CleanupInteractive {
    <#
    .SYNOPSIS
        判断当前会话能否和用户实时交互。

    .DESCRIPTION
        标准输入被重定向（CI、管道、自动化测试）时返回 $false。此时 Read-Host 要么读到
        空值、要么永久挂住，所以两个界面函数必须先问它，再决定是否进入询问循环。

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param()

    try {
        if ([Console]::IsInputRedirected) { return $false }
        return $true
    } catch {
        # 连标准输入状态都读不到（非常规宿主）时按非交互处理：宁可跳过，也不能挂死
        Write-ScanLog -Level Warn -Message ("无法判断标准输入状态，按非交互环境处理：{0}" -f $_.Exception.Message)
        return $false
    }
}

function Read-CleanupAnswer {
    <#
    .SYNOPSIS
        读取用户输入的一行文本（统一封装 Read-Host）。

    .DESCRIPTION
        所有交互输入都经过这里：既是"读用户输入必须用 Read-Host"的唯一落点，
        也让交互流程可以在自动化测试里被替换成脚本化输入，不必真的敲键盘。

    .OUTPUTS
        string
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt)

    return (Read-Host -Prompt $Prompt)
}

# ---------------------------------------------------------------------------
# 内部工具：输入解析
# ---------------------------------------------------------------------------
function ConvertTo-CleanupSelection {
    <#
    .SYNOPSIS
        把用户输入的编号文本解析成清单序号（从 1 开始）。

    .DESCRIPTION
        支持的写法：
          · 编号，用逗号或空格分隔：1,3,5 / 1 3 5
          · 区间：1-3，可以和编号混用：1-3,5
          · all：全选
          · 空回车：采用调用方给出的默认勾选
          · q：放弃
          · d 编号：查看某一项的详情（由调用方负责打印）
        看不懂的输入不抛异常，而是返回 Ok=$false 和一句中文提示，由调用方重新询问。

    .OUTPUTS
        @{ Ok = [bool]; Quit = [bool]; ViewDetail = [int]; Indexes = [int[]]; Message = [string] }
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory)][int]$ItemCount,
        [int[]]$DefaultIndexes = @()
    )

    $result = @{
        Ok         = $false
        Quit       = $false
        ViewDetail = 0
        Indexes    = [int[]]@()
        Message    = ''
    }

    $raw = ''
    if ($null -ne $Text) { $raw = $Text.Trim() }

    # 空回车：采用默认勾选
    if ($raw.Length -eq 0) {
        $result.Ok = $true
        $result.Indexes = [int[]]@($DefaultIndexes)
        return $result
    }

    # q：放弃
    if ($raw -match '^(?i)q$') {
        $result.Ok = $true
        $result.Quit = $true
        return $result
    }

    # all：全选
    if ($raw -match '^(?i)all$') {
        $all = New-Object System.Collections.ArrayList
        for ($i = 1; $i -le $ItemCount; $i++) { [void]$all.Add($i) }
        $result.Ok = $true
        $result.Indexes = [int[]]$all.ToArray()
        return $result
    }

    # d 编号：查看详情
    $detailMatch = [regex]::Match($raw, '^(?i)d\s*(\d+)$')
    if ($detailMatch.Success) {
        $detailNumber = [int]$detailMatch.Groups[1].Value
        if ($detailNumber -lt 1 -or $detailNumber -gt $ItemCount) {
            $result.Message = ("没有第 {0} 项，清单里只有 1-{1} 项。" -f $detailNumber, $ItemCount)
            return $result
        }
        $result.Ok = $true
        $result.ViewDetail = $detailNumber
        return $result
    }

    # 编号与区间：先把区间两侧的空格去掉，再把逗号和空格都当分隔符
    $cleaned = $raw -replace '\s*-\s*', '-'
    $tokens = @($cleaned -split '[,\s]+' | Where-Object { $_.Length -gt 0 })

    $indexes = New-Object System.Collections.ArrayList
    foreach ($token in $tokens) {
        if ($token -match '^(\d+)-(\d+)$') {
            $from = [int]$Matches[1]
            $to = [int]$Matches[2]
            if ($from -lt 1 -or $to -gt $ItemCount -or $from -gt $to) {
                $result.Message = ("看不懂「{0}」：编号要在 1-{1} 之间，区间要从小到大（例如 1-3）。" -f $token, $ItemCount)
                return $result
            }
            for ($i = $from; $i -le $to; $i++) {
                if (-not $indexes.Contains($i)) { [void]$indexes.Add($i) }
            }
            continue
        }

        if ($token -match '^\d+$') {
            $number = [int]$token
            if ($number -lt 1 -or $number -gt $ItemCount) {
                $result.Message = ("看不懂「{0}」：编号要在 1-{1} 之间。" -f $token, $ItemCount)
                return $result
            }
            if (-not $indexes.Contains($number)) { [void]$indexes.Add($number) }
            continue
        }

        $result.Message = ("看不懂「{0}」。可以输入编号（如 1,3）、区间（如 1-3）、all（全选）、d 编号（看详情）或 q（放弃）。" -f $token)
        return $result
    }

    $result.Ok = $true
    $result.Indexes = [int[]]@($indexes.ToArray() | Sort-Object)
    return $result
}

# ---------------------------------------------------------------------------
# 内部工具：条目详情
# ---------------------------------------------------------------------------
function Show-CleanupItemDetail {
    <#
    .SYNOPSIS
        打印某一项的白话说明、本次会隔离的体积与涉及的目录清单。

    .OUTPUTS
        无（只往控制台打印）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][int]$Number
    )

    $name = [string](Get-CleanupItemValue -Item $Item -Key 'Name' -Default '未命名目标')
    $safety = [string](Get-CleanupItemValue -Item $Item -Key 'Safety' -Default '（这一项没有提供说明）')
    $bytes = Get-CleanupItemInt64 -Item $Item -Key 'Bytes'
    $fileCount = Get-CleanupItemInt64 -Item $Item -Key 'FileCount'
    $smallBytes = Get-CleanupItemInt64 -Item $Item -Key 'SmallFileBytes'
    $smallCount = Get-CleanupItemInt64 -Item $Item -Key 'SmallFileCount'
    $paths = @(Get-CleanupItemValue -Item $Item -Key 'Paths' -Default @())

    Write-Host ''
    Write-Host ("   [{0}] {1}" -f $Number, $name) -ForegroundColor White
    Write-Note ("说明：{0}" -f $safety)
    Write-Note ("本次会隔离：{0}（{1} 个文件）" -f (ConvertTo-SizeText -Bytes $bytes), $fileCount)
    if ($smallCount -gt 0) {
        Write-Note ("留在原处：{0}（{1} 个小于 1 MB 的小文件）" -f (ConvertTo-SizeText -Bytes $smallBytes), $smallCount)
    }
    if ($paths.Count -gt 0) {
        Write-Note '涉及这些目录：'
        foreach ($path in $paths) { Write-Note ("  · {0}" -f $path) }
    } else {
        Write-Note '这一项没有列出具体目录。'
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# 对外函数 1：清理清单与勾选
# ---------------------------------------------------------------------------
function Show-CleanupList {
    <#
    .SYNOPSIS
        渲染可清理缓存清单，返回用户选中的目标 Id 数组。

    .DESCRIPTION
        每项都标出默认勾选状态（体积达到 MinBytes 且大于 0 的默认勾选）。条目下方会如实
        说明"有多少小文件会留在原处"，避免用户以为工具少清了东西。用户可以输入编号、
        区间、all、空回车（默认）、d 编号（详情）或 q（放弃）；输入看不懂时提示后重新询问。

    .PARAMETER Items
        清理目标数组，每项形如：
        @{
            Id             = 'temp.user'
            Name           = '当前用户临时文件'
            Bytes          = 3825123456   # 本次会真正隔离的体积
            FileCount      = 362          # 本次会隔离的文件数
            SmallFileBytes = 354123456    # 因小于 1 MB 留在原处的体积
            SmallFileCount = 3904         # 因小于 1 MB 留在原处的文件数
            Safety         = '程序运行过程中产生的临时文件…'
            Paths          = @('...')
            MinBytes       = 52428800
        }

    .OUTPUTS
        string[] —— 用户选中的目标 Id。用户输入 q 放弃、清单里没有可用项、或处于非交互
        环境时，返回空数组（不是 $null）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)

    # 非交互环境：直接返回，绝不进入询问循环（否则会挂死）
    if (-not (Test-CleanupInteractive)) {
        Write-Host '  检测到非交互环境，跳过交互选择' -ForegroundColor Yellow
        Write-Output -NoEnumerate ([string[]]@())
        return
    }

    # 只保留"有东西可隔离、或有小文件值得告知"的项
    $usable = New-Object System.Collections.ArrayList
    foreach ($item in $Items) {
        $itemBytes = Get-CleanupItemInt64 -Item $item -Key 'Bytes'
        $itemSmallCount = Get-CleanupItemInt64 -Item $item -Key 'SmallFileCount'
        if ($itemBytes -gt 0 -or $itemSmallCount -gt 0) { [void]$usable.Add($item) }
    }

    if ($usable.Count -eq 0) {
        Write-Host ''
        Write-Item '没有发现值得清理的缓存'
        Write-Host ''
        Write-Output -NoEnumerate ([string[]]@())
        return
    }

    $defaultIndexes = New-Object System.Collections.ArrayList
    $defaultBytes = [int64]0
    $defaultSmallBytes = [int64]0
    $defaultSmallCount = [int64]0

    Write-Headline '可清理的缓存'
    Write-Item ("共 {0} 项可以隔离，带 [✓] 的是默认勾选（体积达到门槛）。" -f $usable.Count)

    for ($i = 0; $i -lt $usable.Count; $i++) {
        $item = $usable[$i]
        $number = $i + 1
        $name = [string](Get-CleanupItemValue -Item $item -Key 'Name' -Default '未命名目标')
        $bytes = Get-CleanupItemInt64 -Item $item -Key 'Bytes'
        $fileCount = Get-CleanupItemInt64 -Item $item -Key 'FileCount'
        $smallBytes = Get-CleanupItemInt64 -Item $item -Key 'SmallFileBytes'
        $smallCount = Get-CleanupItemInt64 -Item $item -Key 'SmallFileCount'
        $minBytes = Get-CleanupItemInt64 -Item $item -Key 'MinBytes'

        $checked = ($bytes -gt 0) -and ($bytes -ge $minBytes)
        if ($checked) {
            [void]$defaultIndexes.Add($number)
            $defaultBytes += $bytes
            $defaultSmallBytes += $smallBytes
            $defaultSmallCount += $smallCount
        }

        $mark = if ($checked) { '[✓]' } else { '[ ]' }
        Write-Item ("{0} {1}. {2}    {3}（{4} 个文件）" -f $mark, $number, $name, (ConvertTo-SizeText -Bytes $bytes), $fileCount)

        # 只有小文件、本次不会隔离的项，明确说清楚，并且默认不勾选
        if ($bytes -eq 0 -and $smallCount -gt 0) {
            Write-Note '只有小文件，本次不会清理'
        }
        if ($smallCount -gt 0) {
            Write-Note ("另有 {0} 是 {1} 个小于 1 MB 的小文件，会留在原处不清。" -f (ConvertTo-SizeText -Bytes $smallBytes), $smallCount)
        }
    }

    # 汇总：预计隔离体积只累加 Bytes，不含留在原处的小文件
    Write-Host ''
    $summary = "默认勾选 {0} 项，预计隔离 {1}" -f $defaultIndexes.Count, (ConvertTo-SizeText -Bytes $defaultBytes)
    if ($defaultSmallBytes -gt 0) {
        $summary += "；另有 {0}（{1} 个小于 1 MB 的小文件）会留在原处，不计入预计隔离体积" -f (ConvertTo-SizeText -Bytes $defaultSmallBytes), $defaultSmallCount
    }
    Write-Item $summary

    Write-Host ''
    Write-Note '输入要清理的编号后回车，例如 1,3 5 或 1-3；直接回车＝采用默认勾选；all＝全选；q＝放弃。'
    Write-Note '输入 d 编号 查看某项的白话说明与目录清单（例如 d 1）。'
    Write-Host ''

    $defaults = [int[]]$defaultIndexes.ToArray()

    while ($true) {
        $answer = Read-CleanupAnswer -Prompt '  要清理哪几项？'
        $parsed = ConvertTo-CleanupSelection -Text ([string]$answer) -ItemCount $usable.Count -DefaultIndexes $defaults

        if ($parsed.Quit) {
            Write-Host ''
            Write-Note '已放弃本次清理，未做任何改动。'
            Write-Host ''
            Write-Output -NoEnumerate ([string[]]@())
            return
        }

        if ($parsed.ViewDetail -gt 0) {
            Show-CleanupItemDetail -Item $usable[$parsed.ViewDetail - 1] -Number $parsed.ViewDetail
            continue
        }

        if (-not $parsed.Ok) {
            Write-Host ("  ! {0}" -f $parsed.Message) -ForegroundColor Yellow
            continue
        }

        if ($parsed.Indexes.Count -eq 0) {
            Write-Host '  ! 默认没有任何一项被勾选，请输入要清理的编号，或输入 all 全选。' -ForegroundColor Yellow
            continue
        }

        $selectedIds = New-Object System.Collections.ArrayList
        foreach ($index in $parsed.Indexes) {
            $id = [string](Get-CleanupItemValue -Item $usable[$index - 1] -Key 'Id' -Default '')
            if ([string]::IsNullOrWhiteSpace($id)) {
                Write-ScanLog -Level Warn -Message ("清单第 {0} 项缺少 Id 字段，已跳过。" -f $index)
                continue
            }
            if (-not $selectedIds.Contains($id)) { [void]$selectedIds.Add($id) }
        }

        Write-Host ''
        Write-Item ("已选择 {0} 项：{1}" -f $selectedIds.Count, ($selectedIds.ToArray() -join ', '))
        Write-Output -NoEnumerate ([string[]]$selectedIds.ToArray())
        return
    }
}

# ---------------------------------------------------------------------------
# 对外函数 2：二次确认
# ---------------------------------------------------------------------------
function Read-CleanupConfirmation {
    <#
    .SYNOPSIS
        向用户确认是否执行隔离。返回 $true 表示继续。

    .DESCRIPTION
        打印将隔离的项数与总体积，并明确告知：文件是移动到 Snapshot 隔离区而不是直接
        删除、会生成 Restore-All.ps1 可一键还原、隔离区默认上限 2 GB、被占用的文件会被
        跳过。只有输入 yes（不区分大小写）才返回 $true，其它任何输入都取消。

    .PARAMETER SelectedItems
        用户已选中的项（结构同 Show-CleanupList 的 Items）。

    .PARAMETER EstimatedBytes
        预计隔离的总体积（int64），应当只累加各项的 Bytes。

    .OUTPUTS
        [bool] —— $true 表示用户确认执行。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SelectedItems,
        [Parameter(Mandatory)][int64]$EstimatedBytes
    )

    # 非交互环境：无法确认，一律按"不执行"处理
    if (-not (Test-CleanupInteractive)) {
        Write-Host '  检测到非交互环境，跳过交互确认' -ForegroundColor Yellow
        return $false
    }

    $items = @($SelectedItems)
    $smallBytesTotal = [int64]0

    Write-Headline '确认清理'
    Write-Item ("将隔离 {0} 项缓存，预计隔离体积 {1}" -f $items.Count, (ConvertTo-SizeText -Bytes $EstimatedBytes))
    foreach ($item in $items) {
        $name = [string](Get-CleanupItemValue -Item $item -Key 'Name' -Default '未命名目标')
        $bytes = Get-CleanupItemInt64 -Item $item -Key 'Bytes'
        $smallBytesTotal += Get-CleanupItemInt64 -Item $item -Key 'SmallFileBytes'
        Write-Item ("· {0}（{1}）" -f $name, (ConvertTo-SizeText -Bytes $bytes))
    }

    Write-Host ''
    Write-Note '这些文件会被移动到 Snapshot 隔离区，不是直接删除——后悔了还能拿回来。'
    Write-Note '同时会生成 Restore-All.ps1，可以一键把文件移回原位。'
    Write-Note '隔离区默认上限 2 GB，达到上限后会停止继续隔离。'
    Write-Note '正在被程序占用的文件会被自动跳过，不会强行处理。'
    if ($smallBytesTotal -gt 0) {
        Write-Note ("另有 {0} 的小文件会留在原处，不计入上面的预计隔离体积。" -f (ConvertTo-SizeText -Bytes $smallBytesTotal))
    }
    Write-Host ''

    $answer = Read-CleanupAnswer -Prompt '  确认开始请输入 yes（其它任何输入都会取消）'

    if ($null -ne $answer -and ([string]$answer).Trim().ToLowerInvariant() -eq 'yes') {
        return $true
    }

    Write-Host ''
    Write-Host '  已取消，未做任何改动。' -ForegroundColor Yellow
    return $false
}
