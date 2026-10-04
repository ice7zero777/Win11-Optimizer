#Requires -Version 5.1
<#
.SYNOPSIS
    系统状态扫描：内存占用、吃内存的进程、厂商常驻服务、开机启动项、安全软件共存、系统还原状态。

.DESCRIPTION
    只读扫描。不修改任何服务启动类型、不改注册表、不结束任何进程。
    所有结论都带本机实测数据（进程名 + 实际内存占用），不输出"可能存在问题"这类空话。

    对应用户实际遇到的典型问题：
      · 厂商预装服务常驻并内存泄漏（例如 Dell 的 ServiceShell）
      · 三套杀毒软件同时实时扫描，导致磁盘长期 100%
      · 开机启动项过多，拖慢开机
      · 系统还原被关闭，出问题无法回退

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    所有外部信息获取都用 try/catch 包裹，失败记日志，绝不静默吞错（铁律 L2）。
#>

Set-StrictMode -Version Latest

# 已知厂商关键词。用于判断"服务是否属于某厂商"，以及"厂商与整机品牌是否匹配"。
$script:VendorKeywords = @{
    'Dell'    = @('Dell', 'Alienware', 'SupportAssist')
    'Lenovo'  = @('Lenovo', 'ThinkPad', 'ThinkVantage')
    'HP'      = @('HP', 'Hewlett', 'HPSupport')
    'ASUS'    = @('ASUS', 'Armoury', 'ASUSOptimization')
    'Acer'    = @('Acer', 'Predator')
    'MSI'     = @('MSI', 'Micro-Star')
    'Samsung' = @('Samsung')
    'Huawei'  = @('Huawei', 'Honor')
    'Xiaomi'  = @('Xiaomi', 'MiService')
}

function Get-VendorKeyFromText {
    <#
    .SYNOPSIS
        从一段文本里识别厂商关键词，返回厂商名或 $null。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    foreach ($vendor in $script:VendorKeywords.Keys) {
        foreach ($keyword in $script:VendorKeywords[$vendor]) {
            if ($Text.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $vendor
            }
        }
    }
    return $null
}

function Get-VendorKeyFromBrand {
    <#
    .SYNOPSIS
        根据整机品牌判断"本机该有的厂商"，用于发现厂商不匹配的残留服务。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Manufacturer)

    return Get-VendorKeyFromText -Text $Manufacturer
}

function Invoke-MemoryScan {
    <#
    .SYNOPSIS
        检查内存占用情况与吃内存最多的进程。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = New-Object System.Collections.ArrayList
    $profile = $Context.Profile

    if ($profile.MemoryTotalGB -le 0) {
        Write-ScanLog -Level Warn -Message '内存信息不可用，跳过内存检查。'
        return $findings.ToArray()
    }

    if ($profile.MemoryUsedPct -ge 85) {
        [void]$findings.Add((New-Finding `
            -Id 'system.memory-pressure' `
            -Module 'system' `
            -Severity 'High' `
            -Title ('内存已用 {0}%（空闲 {1} GB / 共 {2} GB）' -f $profile.MemoryUsedPct, $profile.MemoryFreeGB, $profile.MemoryTotalGB) `
            -Detail ('你的内存已经用掉 {0}%，只剩 {1} GB 可用。Windows 在内存紧张时会频繁读写硬盘充当内存（分页），这是老电脑越来越卡最常见的原因。' -f $profile.MemoryUsedPct, $profile.MemoryFreeGB) `
            -Evidence ([ordered]@{
                '内存总量'   = ('{0} GB' -f $profile.MemoryTotalGB)
                '当前空闲'   = ('{0} GB' -f $profile.MemoryFreeGB)
                '已用比例'   = ('{0}%' -f $profile.MemoryUsedPct)
            }) `
            -Advice '先在下面的进程清单里找出占内存最多的几个，看是不是能关掉或卸载的软件。'))
    }

    try {
        $processes = @(Get-Process -ErrorAction Stop |
            Where-Object { $_.WorkingSet64 -gt 0 } |
            Sort-Object WorkingSet64 -Descending |
            Select-Object -First 10)
    } catch {
        Write-ScanLog -Level Warn -Message "读取进程列表失败：$($_.Exception.Message)"
        return $findings.ToArray()
    }

    # 同名进程（例如浏览器会开很多个子进程）合并统计，避免报告里出现一串重复名字
    $perName = @{}
    $maxSingleMB = 0
    $maxSingleName = ''
    foreach ($process in $processes) {
        $memoryMB = [math]::Round($process.WorkingSet64 / 1MB, 0)
        if ($memoryMB -gt $maxSingleMB) {
            $maxSingleMB = $memoryMB
            $maxSingleName = $process.ProcessName
        }
        if ($perName.ContainsKey($process.ProcessName)) {
            $perName[$process.ProcessName].MemoryMB += $memoryMB
            $perName[$process.ProcessName].Count++
        } else {
            $perName[$process.ProcessName] = [pscustomobject]@{ Name = $process.ProcessName; MemoryMB = $memoryMB; Count = 1 }
        }
    }

    $memoryProcesses = New-Object System.Collections.ArrayList
    foreach ($entry in ($perName.Values | Sort-Object -Property MemoryMB -Descending)) {
        if ($entry.Count -gt 1) {
            [void]$memoryProcesses.Add(('{0}（{1} MB，共 {2} 个进程）' -f $entry.Name, $entry.MemoryMB, $entry.Count))
        } else {
            [void]$memoryProcesses.Add(('{0}（{1} MB）' -f $entry.Name, $entry.MemoryMB))
        }
    }

    if ($memoryProcesses.Count -gt 0) {
        # 单个普通进程占用超过 800 MB 属于明显异常，值得单独提示
        $severity = 'Info'
        $title = '占内存最多的进程'
        $detail = ('当前占用内存最多的单个进程是 {0}，约 {1} MB。' -f $maxSingleName, $maxSingleMB)
        if ($maxSingleMB -ge 800) {
            $severity = 'Medium'
            $title = ('单个进程占用 {0} MB 内存：{1}' -f $maxSingleMB, $maxSingleName)
            $detail = ('{0} 一个进程就占了 {1} MB 内存（约占总量的 {2}%）。正常的后台程序通常在几十到几百 MB，占用到这个量级常见于厂商预装的服务出现内存泄漏。' -f $maxSingleName, $maxSingleMB, [math]::Round($maxSingleMB / ($profile.MemoryTotalGB * 1024) * 100, 1))
        }

        [void]$findings.Add((New-Finding `
            -Id 'system.memory-top-processes' `
            -Module 'system' `
            -Severity $severity `
            -Title $title `
            -Detail $detail `
            -Evidence ([ordered]@{ '内存占用前 10 名（同名进程已合并）' = ($memoryProcesses -join '、') }) `
            -Advice '这些进程多数是随系统启动的。如果不认识某个进程名，可以在任务管理器里右键查看它的文件位置，再决定是否保留。'))
    }

    return $findings.ToArray()
}

function Invoke-ServiceScan {
    <#
    .SYNOPSIS
        列出第三方常驻服务，识别厂商预装与厂商不匹配的服务。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = New-Object System.Collections.ArrayList

    try {
        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            Where-Object { $_.State -eq 'Running' })
    } catch {
        Write-ScanLog -Level Warn -Message "读取服务列表失败：$($_.Exception.Message)"
        return $findings.ToArray()
    }

    $vendorServices = New-Object System.Collections.ArrayList
    $mismatched = New-Object System.Collections.ArrayList
    $brandVendor = Get-VendorKeyFromBrand -Manufacturer $Context.Profile.Manufacturer

    foreach ($service in $services) {
        $text = '{0} {1} {2}' -f $service.Name, $service.DisplayName, $service.PathName
        $vendor = Get-VendorKeyFromText -Text $text
        if (-not $vendor) { continue }

        [void]$vendorServices.Add(('{0}（{1}）' -f $service.DisplayName, $vendor))

        if ($brandVendor -and ($vendor -ne $brandVendor)) {
            [void]$mismatched.Add(('{0} 属于 {1}，但本机是 {2}' -f $service.DisplayName, $vendor, $brandVendor))
        }
    }

    if ($vendorServices.Count -ge 5) {
        [void]$findings.Add((New-Finding `
            -Id 'system.vendor-services' `
            -Module 'system' `
            -Severity 'Medium' `
            -Title ('{0} 个厂商服务正在常驻运行' -f $vendorServices.Count) `
            -Detail ('检测到 {0} 个来自厂商预装的常驻服务，它们会一直占用内存和后台资源。多数人并不需要它们全部常驻。' -f $vendorServices.Count) `
            -Evidence ([ordered]@{ '厂商服务' = ($vendorServices -join '；') }) `
            -Advice '本工具不会替你改服务。若某个厂商功能你平时不用，可在"服务"里把它改成手动启动（改前建议先记下原状态）。'))
    }

    if ($mismatched.Count -gt 0) {
        [void]$findings.Add((New-Finding `
            -Id 'system.vendor-mismatch' `
            -Module 'system' `
            -Severity 'Low' `
            -Title ('{0} 个服务的厂商与本机品牌不一致' -f $mismatched.Count) `
            -Detail '这些服务来自与本机品牌不同的厂商，通常是换机、重装或以前装过厂商工具留下的残留。它们常年运行却帮不上任何忙。' `
            -Evidence ([ordered]@{ '不匹配项' = ($mismatched -join '；') }) `
            -Advice '确认这些厂商工具已经卸载后，对应服务可以停用并改为手动。'))
    }

    Write-ScanLog -Level Info -Message ('服务检查完成：厂商服务 {0} 个，不匹配 {1} 个' -f $vendorServices.Count, $mismatched.Count)
    return $findings.ToArray()
}

function Invoke-StartupScan {
    <#
    .SYNOPSIS
        统计开机启动项（注册表 Run 键 + 启动文件夹）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = New-Object System.Collections.ArrayList
    $entries = New-Object System.Collections.ArrayList

    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )

    foreach ($key in $runKeys) {
        try {
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $properties = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($property in $properties.PSObject.Properties) {
                # PS* 是 PowerShell 附加属性，不是真实启动项
                if ($property.Name -like 'PS*') { continue }
                [void]$entries.Add(('{0}　→　{1}' -f $property.Name, $property.Value))
            }
        } catch {
            Write-ScanLog -Level Warn -Message "读取启动项 $key 失败：$($_.Exception.Message)"
        }
    }

    # 启动文件夹：用变量拼接，不写字面量路径
    $startupFolders = New-Object System.Collections.ArrayList
    $candidateRoots = @(
        [System.Environment]::GetFolderPath('Startup')
        [System.Environment]::GetFolderPath('CommonStartup')
    )
    foreach ($folder in $candidateRoots) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        [void]$startupFolders.Add($folder)
        try {
            $shortcuts = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop)
            foreach ($shortcut in $shortcuts) {
                [void]$entries.Add(('{0}　→　启动文件夹' -f $shortcut.Name))
            }
        } catch {
            Write-ScanLog -Level Warn -Message "读取启动文件夹失败：$($_.Exception.Message)"
        }
    }

    if ($entries.Count -ge 8) {
        [void]$findings.Add((New-Finding `
            -Id 'system.startup-items' `
            -Module 'system' `
            -Severity 'Medium' `
            -Title ('{0} 个程序会随开机自动启动' -f $entries.Count) `
            -Detail ('有 {0} 个程序设置为开机自启。它们会在你还没开始用电脑时就一起运行，直接拖慢开机速度并长期占用内存。' -f $entries.Count) `
            -Evidence ([ordered]@{ '启动项清单' = ($entries -join '；') }) `
            -Advice '在"任务管理器 → 启动应用"里关掉不常用的（关闭启动项是可逆的，随时能再打开）。'))
    } elseif ($entries.Count -gt 0) {
        [void]$findings.Add((New-Finding `
            -Id 'system.startup-items' `
            -Module 'system' `
            -Severity 'Info' `
            -Title ('{0} 个程序会随开机自动启动' -f $entries.Count) `
            -Detail '启动项数量不多，暂时不构成明显负担。' `
            -Evidence ([ordered]@{ '启动项清单' = ($entries -join '；') }) `
            -Advice '如果发现不认识的条目，可以在任务管理器的"启动应用"里核对。'))
    }

    Write-ScanLog -Level Info -Message ('启动项检查完成：共 {0} 项' -f $entries.Count)
    return $findings.ToArray()
}

function Invoke-SecurityScan {
    <#
    .SYNOPSIS
        检查是否有多个杀毒软件同时注册为实时防护。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = New-Object System.Collections.ArrayList

    try {
        $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    } catch {
        Write-ScanLog -Level Warn -Message "读取安全软件列表失败（部分系统不支持该接口）：$($_.Exception.Message)"
        return $findings.ToArray()
    }

    $active = New-Object System.Collections.ArrayList
    foreach ($product in $products) {
        $state = 0
        try { $state = [int]$product.productState } catch { $state = 0 }
        # 产品状态位：0x1000 表示实时防护开启
        $realtime = (($state -band 0x1000) -eq 0x1000)
        [void]$active.Add(('{0}（实时防护：{1}）' -f $product.displayName, $(if ($realtime) { '开启' } else { '关闭' })))
    }

    $realtimeCount = 0
    foreach ($product in $products) {
        $state = 0
        try { $state = [int]$product.productState } catch { $state = 0 }
        if (($state -band 0x1000) -eq 0x1000) { $realtimeCount++ }
    }

    if ($realtimeCount -ge 2) {
        [void]$findings.Add((New-Finding `
            -Id 'system.antivirus-conflict' `
            -Module 'system' `
            -Severity 'High' `
            -Title ('{0} 套安全软件同时开启实时防护' -f $realtimeCount) `
            -Detail ('有 {0} 套安全软件同时在实时扫描。它们会互相扫描对方的动作，这是磁盘长期 100%、风扇狂转的常见原因，而且并不会让你更安全。' -f $realtimeCount) `
            -Evidence ([ordered]@{ '已注册的安全软件' = ($active -join '；') }) `
            -Advice '只保留一套即可（Windows 自带的 Defender 对多数人已经够用）。卸载请从"设置 → 应用"里走官方卸载入口，本工具不会代你卸载。'))
    } elseif ($active.Count -gt 0) {
        [void]$findings.Add((New-Finding `
            -Id 'system.antivirus-status' `
            -Module 'system' `
            -Severity 'Info' `
            -Title ('检测到 {0} 套安全软件' -f $active.Count) `
            -Detail '只有一套安全软件在工作，不存在互相扫描的问题。' `
            -Evidence ([ordered]@{ '已注册的安全软件' = ($active -join '；') }) `
            -Advice ''))
    }

    Write-ScanLog -Level Info -Message ('安全软件检查完成：注册 {0} 套，实时防护开启 {1} 套' -f $active.Count, $realtimeCount)
    return $findings.ToArray()
}

function Invoke-RestorePointScan {
    <#
    .SYNOPSIS
        检查系统还原是否可用。系统还原被关闭时，出问题就没有退路。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = New-Object System.Collections.ArrayList

    # Win32_ShadowCopy 需要管理员权限，普通用户下会直接抛异常。
    # 这种情况必须报"读不到"，不能当成"没有还原点"——那会凭空制造一个不存在的问题。
    $readOk = $false
    $points = @()
    try {
        $points = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop)
        $readOk = $true
    } catch {
        Write-ScanLog -Level Warn -Message "读取还原点信息失败（通常是非管理员权限导致）：$($_.Exception.Message)"
        $readOk = $false
    }

    if (-not $readOk) {
        [void]$findings.Add((New-Finding `
            -Id 'system.restore-point-unknown' `
            -Module 'system' `
            -Severity 'Low' `
            -Title '无法确认系统还原状态' `
            -Detail '当前权限读不到系统还原信息（这个接口需要管理员权限）。这不代表你没有还原点，只是本次没读到。' `
            -Evidence ([ordered]@{ '原因' = '读取系统还原信息需要管理员权限' }) `
            -Advice '以管理员身份重新运行本工具，或在"控制面板 → 恢复"里手动确认系统还原是否已开启。'))
        return $findings.ToArray()
    }

    if ($null -eq $points) { $points = @() }

    $evidence = [ordered]@{
        '现有还原点数量' = $points.Count
    }

    if ($points.Count -eq 0) {
        [void]$findings.Add((New-Finding `
            -Id 'system.restore-point-missing' `
            -Module 'system' `
            -Severity 'Medium' `
            -Title '没有可用的系统还原点' `
            -Detail '系统还原当前没有可用还原点。一旦驱动或更新出问题，就没有"退回上一个正常状态"的退路。' `
            -Evidence $evidence `
            -Advice '建议在"控制面板 → 恢复 → 配置系统还原"里为系统盘开启保护并手动创建一个还原点。'))
    } else {
        [void]$findings.Add((New-Finding `
            -Id 'system.restore-point-ok' `
            -Module 'system' `
            -Severity 'Info' `
            -Title ('已有 {0} 个系统还原点' -f $points.Count) `
            -Detail '系统还原可用，出问题时可以退回到之前的状态。' `
            -Evidence $evidence `
            -Advice ''))
    }

    return $findings.ToArray()
}

function Invoke-PendingRebootScan {
    <#
    .SYNOPSIS
        检查系统是否处于"等待重启"状态（多来源交叉验证，见铁律 L6）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = New-Object System.Collections.ArrayList
    $signals = New-Object System.Collections.ArrayList

    # 来源 1：组件服务（CBS）重建待处理
    try {
        $cbs = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing' -Name RebootPending -ErrorAction Stop
        if ($null -ne $cbs.RebootPending) {
            [void]$signals.Add('组件服务（CBS）标记了待重启')
        }
    } catch {
        Write-ScanLog -Level Info -Message "CBS 重启标记不可读（通常表示无待处理）：$($_.Exception.Message)"
    }

    # 来源 2：Windows 更新待处理
    try {
        $wu = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction Stop
        if ($null -ne $wu) {
            [void]$signals.Add('Windows 更新标记了待重启')
        }
    } catch {
        Write-ScanLog -Level Info -Message "Windows 更新重启标记不可读（通常表示无待处理）：$($_.Exception.Message)"
    }

    # 来源 3：待处理文件重命名
    try {
        $rename = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        if ($null -ne $rename.PendingFileRenameOperations) {
            [void]$signals.Add('存在待处理的文件替换（重启后完成）')
        }
    } catch {
        Write-ScanLog -Level Info -Message "待处理文件重命名不可读（通常表示无待处理）：$($_.Exception.Message)"
    }

    if ($signals.Count -gt 0) {
        [void]$findings.Add((New-Finding `
            -Id 'system.pending-reboot' `
            -Module 'system' `
            -Severity 'Low' `
            -Title '系统正在等待重启以完成某些更改' `
            -Detail '系统有未完成的操作需要重启才能生效。在重启完成前，部分更新和修复不会起效。' `
            -Evidence ([ordered]@{ '检测到的信号' = ($signals -join '；') }) `
            -Advice '找个方便的时间重启一次即可，不需要额外操作。'))
    }

    return $findings.ToArray()
}

function Invoke-SystemScan {
    <#
    .SYNOPSIS
        系统扫描总入口：内存、服务、启动项、安全软件、系统还原、待重启。

    .OUTPUTS
        Finding[]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = New-Object System.Collections.ArrayList

    Write-ScanLog -Level Info -Message '开始检查内存占用…'
    foreach ($item in (Invoke-MemoryScan -Context $Context)) { [void]$findings.Add($item) }

    Write-ScanLog -Level Info -Message '开始检查常驻服务…'
    foreach ($item in (Invoke-ServiceScan -Context $Context)) { [void]$findings.Add($item) }

    Write-ScanLog -Level Info -Message '开始检查开机启动项…'
    foreach ($item in (Invoke-StartupScan -Context $Context)) { [void]$findings.Add($item) }

    Write-ScanLog -Level Info -Message '开始检查安全软件…'
    foreach ($item in (Invoke-SecurityScan -Context $Context)) { [void]$findings.Add($item) }

    Write-ScanLog -Level Info -Message '开始检查系统还原…'
    foreach ($item in (Invoke-RestorePointScan -Context $Context)) { [void]$findings.Add($item) }

    Write-ScanLog -Level Info -Message '开始检查待重启状态…'
    foreach ($item in (Invoke-PendingRebootScan -Context $Context)) { [void]$findings.Add($item) }

    return $findings.ToArray()
}
