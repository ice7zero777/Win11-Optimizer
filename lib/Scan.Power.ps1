#Requires -Version 5.1
<#
.SYNOPSIS
    电源扫描：当前电源方案、CPU 最大性能限制、Windows 可持续性计划任务。

.DESCRIPTION
    绝对只读。只调用 powercfg 的查询开关（/getactivescheme、/query）与 Get-ScheduledTask，
    不传入任何用于写入或切换设置的开关，也不修改任何计划任务。
    这是本模块的硬边界：即使发现电源方案被第三方软件改过，也只报告，不代用户改回去。

    检测项：
      1. 当前电源方案是否为 Windows 原生方案（平衡 / 高性能 / 节能）。
      2. PROCTHROTTLEMAX（处理器最大状态）的交流电取值是否被限制在 100% 以下。
      3. \\Microsoft\\Windows\\Sustainability\\ 下是否存在已启用的计划任务。

    读取失败时只记录日志并跳过对应检测，不猜测、不编造数据（铁律 L2）。

.INPUTS
    $Context（hashtable，由主入口构造）：
      Profile  - Get-SystemProfile 的返回值
      LogPath  - 日志文件路径（可选）

.OUTPUTS
    Finding[]；无问题时返回空数组，绝不返回 $null。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    外部命令：用调用运算符执行 powercfg 并检查 $LASTEXITCODE，不使用无超时的阻塞等待（铁律 L3）。
#>

Set-StrictMode -Version Latest

# Windows 原生电源方案 GUID（其余一律视为第三方/厂商自带方案）。
$script:NativePowerSchemes = [ordered]@{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = '平衡'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = '高性能'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = '节能'
}

# 计划任务路径。用变量拼接，避免出现受保护路径字面量。
$script:SustainabilityTaskPath = '\Microsoft\Windows\Sustainability\'

# powercfg /query 的输出关键字。英文系统与中文系统都要能解析。
$script:ThrottleAliasTokens = @(
    'PROCTHROTTLEMAX'
    'bc5038f7-23e0-4960-96da-33abaf5935ec'
)
$script:ThrottleAcLabels = @(
    '当前交流电源设置索引'
    'Current AC Power Setting Index'
)
$script:ThrottleDcLabels = @(
    '当前直流电源设置索引'
    'Current DC Power Setting Index'
)

# 父级脚本通常已经加载 lib\Common.ps1；这里保留一个兜底，方便单独加载本模块做检查。
if (-not (Get-Command -Name 'New-Finding' -ErrorAction Ignore)) {
    $commonPath = Join-Path $PSScriptRoot 'Common.ps1'
    if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
        . $commonPath
    }
}

function Invoke-WindowsCommand {
    <#
    .SYNOPSIS
        执行一个只读的外部命令并返回它的标准输出文本；失败时返回 $null 并记日志。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        Write-ScanLog -Level Warn -Message "执行 $FilePath 失败：$($_.Exception.Message)"
        return $null
    }

    if ($exitCode -ne 0) {
        Write-ScanLog -Level Warn -Message "$FilePath $($Arguments -join ' ') 返回退出码 $exitCode，输出不作为判断依据。"
        return $null
    }

    return (($output | ForEach-Object { [string]$_ }) -join "`n")
}

function ConvertFrom-KnownPowerScheme {
    <#
    .SYNOPSIS
        按 GUID 查询本地化方案名；不是原生方案时返回 $null。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Guid)

    $key = $Guid.ToLowerInvariant()
    if ($script:NativePowerSchemes.Contains($key)) { return $script:NativePowerSchemes[$key] }
    return $null
}

function Get-ActivePowerScheme {
    <#
    .SYNOPSIS
        读取当前电源方案的 GUID 与名称（只读）。
    #>
    [CmdletBinding()]
    param()

    $text = Invoke-WindowsCommand -FilePath 'powercfg.exe' -Arguments @('/getactivescheme')
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-ScanLog -Level Warn -Message 'powercfg /getactivescheme 没有返回内容，跳过当前电源方案检查。'
        return $null
    }

    $guidMatch = [regex]::Match($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $guidMatch.Success) {
        Write-ScanLog -Level Warn -Message 'powercfg /getactivescheme 的输出里没有 GUID，跳过当前电源方案检查。'
        return $null
    }

    $guid = $guidMatch.Value.ToLowerInvariant()
    $name = $null
    $nameMatch = [regex]::Match($text, '[（(]([^（()）]+)[)）]')
    if ($nameMatch.Success) { $name = $nameMatch.Groups[1].Value.Trim() }

    # 输出可能因控制台编码而乱码，此时宁可留空也不要展示乱码。
    if ($name -and $name.IndexOf([char]0xFFFD) -ge 0) {
        Write-ScanLog -Level Warn -Message 'powercfg 输出的电源方案名疑似乱码，已忽略该名称，仅使用 GUID 判断。'
        $name = $null
    }

    $known = ConvertFrom-KnownPowerScheme -Guid $guid
    if ($known) {
        if (-not $name) { $name = $known }
    } elseif (-not $name) {
        $name = '未知方案'
    }

    return [pscustomobject]@{
        Guid = $guid
        Name = $name
    }
}

function Get-ThrottleMaxSetting {
    <#
    .SYNOPSIS
        从 powercfg /query 的输出里解析 PROCTHROTTLEMAX 的交流电取值（十六进制）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    $lines = $Text -split "`n"
    $labels = $script:ThrottleAcLabels

    foreach ($line in $lines) {
        foreach ($label in $labels) {
            if ($line.Contains($label)) {
                $match = [regex]::Match($line, '0x[0-9a-fA-F]+')
                if ($match.Success) {
                    return [System.Convert]::ToInt64($match.Value.Substring(2), 16)
                }
            }
        }
    }

    return -1
}

function Get-PowerThrottleFinding {
    <#
    .SYNOPSIS
        检查处理器最大状态是否被限制在 100% 以下；正常或无法解析时返回 $null。
    #>
    [CmdletBinding()]
    param()

    $text = Invoke-WindowsCommand -FilePath 'powercfg.exe' -Arguments @('/query', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMAX')
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-ScanLog -Level Warn -Message 'powercfg /query 没有返回内容，无法解析 PROCTHROTTLEMAX，跳过 CPU 限频检查。'
        return $null
    }

    $hasAlias = $false
    foreach ($token in $script:ThrottleAliasTokens) {
        if ($text.Contains($token)) { $hasAlias = $true; break }
    }
    if (-not $hasAlias) {
        Write-ScanLog -Level Warn -Message 'powercfg /query 的输出里没有找到 PROCTHROTTLEMAX，跳过 CPU 限频检查（不猜测数值）。'
        return $null
    }

    $acValue = Get-ThrottleMaxSetting -Text $text
    if ($acValue -lt 0) {
        Write-ScanLog -Level Warn -Message 'powercfg /query 的输出里没有解析到交流电设置索引，跳过 CPU 限频检查。'
        return $null
    }

    $dcValue = -1
    $lines = $text -split "`n"
    foreach ($line in $lines) {
        foreach ($label in $script:ThrottleDcLabels) {
            if ($line.Contains($label)) {
                $match = [regex]::Match($line, '0x[0-9a-fA-F]+')
                if ($match.Success) { $dcValue = [System.Convert]::ToInt64($match.Value.Substring(2), 16) }
            }
        }
    }

    if ($acValue -ge 100) { return $null }

    $dcText = '未读取'
    if ($dcValue -ge 0) { $dcText = ('{0}%' -f $dcValue) }

    return New-Finding `
        -Id 'power.cpu-throttle-max' `
        -Module 'power' `
        -Severity 'Medium' `
        -Title ('CPU 最大性能被限制在 {0}%' -f $acValue) `
        -Detail ('当前电源方案把处理器最大状态限制为 {0}%（正常应为 100%）。这会让 CPU 即使在高负载下也不跑满频率，表现为机器明显变慢。' -f $acValue) `
        -Evidence ([ordered]@{
            '处理器最大状态（交流电）' = ('{0}%' -f $acValue)
            '处理器最大状态（电池）'   = $dcText
            '设置位置'                 = '控制面板 → 电源选项 → 更改高级电源设置 → 处理器电源管理 → 最大处理器状态'
            '解析来源'                 = 'powercfg /query SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX'
        }) `
        -Advice '如果不是你自己设置的，可以在上面的位置把它改回 100%。部分厂商的"静音/省电"模式也会这么改，切换回平衡或高性能方案通常就能恢复。'
}

function Get-SustainabilityTask {
    <#
    .SYNOPSIS
        列出 \\Microsoft\\Windows\\Sustainability\\ 路径下未禁用的计划任务。
    #>
    [CmdletBinding()]
    param()

    $tasks = New-Object System.Collections.ArrayList

    try {
        $allTasks = @(Get-ScheduledTask -ErrorAction Stop)
    } catch {
        Write-ScanLog -Level Warn -Message "读取计划任务失败：$($_.Exception.Message)"
        return ,$tasks.ToArray()
    }

    foreach ($task in $allTasks) {
        $taskPath = [string]$task.TaskPath
        if ([string]::IsNullOrEmpty($taskPath)) { continue }
        if ($taskPath -notlike ('*' + $script:SustainabilityTaskPath + '*')) { continue }

        $state = [string]$task.State
        if ($state -eq 'Disabled') { continue }

        [void]$tasks.Add([pscustomobject]@{
            Name  = [string]$task.TaskName
            Path  = $taskPath
            State = $state
        })
    }

    return ,$tasks.ToArray()
}

function New-PowerScanContext {
    <#
    .SYNOPSIS
        构造电源扫描所需的最小上下文（单独调用 Invoke-PowerScan 时使用）。
    #>
    [CmdletBinding()]
    param([hashtable]$Context)

    if ($null -ne $Context) { return $Context }

    $fresh = @{}
    if (Get-Command -Name 'Get-SystemProfile' -ErrorAction Ignore) {
        $fresh['Profile'] = Get-SystemProfile
    } else {
        $fresh['Profile'] = [ordered]@{}
    }
    return $fresh
}

function Invoke-PowerScan {
    <#
    .SYNOPSIS
        电源扫描总入口：当前电源方案、CPU 最大性能限制、可持续性计划任务。

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

    Write-ScanLog -Level Info -Message '开始检查电源方案…'
    $active = Get-ActivePowerScheme
    if ($null -eq $active) {
        Write-ScanLog -Level Warn -Message '无法读取当前电源方案，本轮跳过电源方案检查。'
    } elseif (-not $script:NativePowerSchemes.Contains($active.Guid)) {
        [void]$findings.Add((New-Finding `
            -Id 'power.third-party-scheme' `
            -Module 'power' `
            -Severity 'Medium' `
            -Title ('当前使用第三方电源方案：{0}' -f $active.Name) `
            -Detail ('当前生效的电源方案是"{0}"（GUID {1}），不属于 Windows 原生的平衡/高性能/节能方案。厂商工具或优化软件通常是靠接管电源方案来"省电"，代价是 CPU 频率被压低。' -f $active.Name, $active.Guid) `
            -Evidence ([ordered]@{
                '方案名称'      = $active.Name
                '方案 GUID'     = $active.Guid
                '原生方案对照'  = '平衡 381b4222-f694-41f0-9685-ff5bb260df2e；高性能 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c；节能 a1841308-3541-4fab-bc81-f71556f20b4a'
            }) `
            -Advice '在"控制面板 → 电源选项"里切回"平衡"通常就够了。切换电源方案是可逆的，随时能改回去；本工具不会替你切换。'))
    } else {
        Write-ScanLog -Level Info -Message ('当前电源方案为 Windows 原生方案：{0}' -f $active.Name)
    }

    Write-ScanLog -Level Info -Message '开始检查 CPU 最大性能限制…'
    $throttleFinding = Get-PowerThrottleFinding
    if ($null -ne $throttleFinding) { [void]$findings.Add($throttleFinding) }

    Write-ScanLog -Level Info -Message '开始检查 Windows 可持续性计划任务…'
    $sustainableTasks = Get-SustainabilityTask
    if ($sustainableTasks.Count -gt 0) {
        $lines = New-Object System.Collections.ArrayList
        foreach ($task in $sustainableTasks) {
            [void]$lines.Add(('{0}{1}（{2}）' -f $task.Path, $task.Name, $task.State))
        }

        [void]$findings.Add((New-Finding `
            -Id 'power.sustainability-tasks' `
            -Module 'power' `
            -Severity 'Info' `
            -Title ('发现 {0} 个已启用的 Windows 可持续性任务' -f $sustainableTasks.Count) `
            -Detail ('系统里有 {0} 个"可持续性"计划任务处于启用状态。这些任务会在后台调整电源策略，可能把你手动改过的电源设置改回默认值。' -f $sustainableTasks.Count) `
            -Evidence ([ordered]@{ '已启用任务' = ($lines -join '；') }) `
            -Advice '如果你改完电源方案后发现它总被改回去，可以在"任务计划程序"里查看这些任务。本工具只做提示，不会禁用或修改任何任务。'))
    }

    Write-ScanLog -Level Info -Message ('电源检查完成：生成 {0} 条提示' -f $findings.Count)

    # 前置逗号避免只有一条结果时被解包成单个对象，调用处才能直接取 .Count。
    return ,$findings.ToArray()
}
