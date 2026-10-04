# 插件开发指南

> 一个插件 = **一个优化项**。它由两部分组成：`plugin.json`（元数据，声明它想动什么、风险多大）
> 和 `plugin.ps1`（实现，五个函数）。
>
> ⚠️ **诚实声明**：插件加载器与引擎还在开发中（见[根目录 README](../README.md#当前进度诚实版)），
> 本文描述的契约已经固定，但暂时还不能端到端跑通。契约本身来自
> [需求文档 §5](PRD.md)，未经我擅自修改。提交前请对照 [`../CONTRIBUTING.md`](../CONTRIBUTING.md)
> 里的十条铁律自检清单。

---

## 0. 先读这三条

1. **你声明不了的事，引擎就不让你做。** 插件不能自己决定删什么——删除目标必须写在 `plugin.json` 的
   `targets.allowPaths` 白名单里，由引擎校验后执行（铁律 L1）。
2. **失败必须说话。** 不允许 `-ErrorAction SilentlyContinue`，不允许空 `catch`（铁律 L2）。
3. **调用外部程序必须带超时。** 不允许没有边界的 `Start-Process -Wait`（铁律 L3）。

这三条不是"代码风格建议"，是**会被 CI 拒绝**的硬检查。

---

## 1. 目录结构

```
plugins/<NNN>-<slug>/
├─ plugin.json      # 元数据（必需）
├─ plugin.ps1       # 实现（必需）
└─ README.md        # 给用户和审查者看的说明（强烈建议）
```

- `<NNN>`：三位数字，决定加载顺序（`010`、`020`…）
- `<slug>`：小写连字符，纯 ASCII
- 目录名里**不要**出现 `start` / `boot` / `run` / `launch` / `entry` 这类词——
  L5 检查会把它们当启动器，非 ASCII 名会被拒

模板目录：`plugins/_template/`，可直接复制。

---

## 2. `plugin.json` 字段说明

```jsonc
{
  // === 身份 ===
  "id": "disk.shadercache",              // 必需。全局唯一，格式 <module>.<slug>
  "name": "清理显卡着色器缓存",           // 必需。给用户看的中文名
  "module": "disk",                      // 必需。见 §4.1 的模块清单
  "version": "1.0.0",
  "author": "community",

  // === 风险与安全（最关键） ===
  "risk": 0,                             // 必需。0=零风险 1=低 2=中 3=高 4=仅建议
  "defaultChecked": true,                // 必需。risk=0 ⟺ true；risk>=2 ⟹ false
  "reversible": true,                    // 必需。能否还原
  "requiresAdmin": false,
  "requiresReboot": false,

  // === 前置条件 ===
  "preflight": {
    "minWindowsBuild": 22000,            // Win11 最低 build
    "requiresAC": false,                 // 是否必须接电源
    "minFreeSpaceGB": 0,
    "minFreeSpacePercent": 0,
    "excludeIfProcessRunning": ["Steam.exe"],
    "customCheck": "Test-ShaderCachePresent"   // 指向 plugin.ps1 里的自定义检查函数
  },

  // === 面向用户的说明（三段式，必填） ===
  "explain": {
    "what": "要做什么（白话）",
    "why":  "为什么这会影响你（白话，带数据）",
    "risk": "最坏情况是什么（不许写“请自行判断”）"
  },

  // === 目标路径白名单（铁律 L1） ===
  "targets": {
    "allowPaths": ["%LOCALAPPDATA%\\NVIDIA\\DXCache"],
    "allowGlobs": ["*.nvph", "*.bin"],
    "denyPaths": []                      // 额外禁止，双层保护
  },

  // === 快照与还原 ===
  "snapshot": {
    "method": "none",                    // none | fileList | registry | serviceState | custom
    "registryKeys": [],
    "serviceStates": [],
    "customSave": "",
    "customRestore": ""
  },

  // === 预估效果 ===
  "estimatedBenefit": {
    "type": "space",                     // space | memory | speed | security
    "typicalValue": "2-7 GB",
    "unit": "GB"
  },

  // === 冲突与依赖 ===
  "conflictsWith": [],
  "dependsOn": [],
  "supersedes": [],

  // === 文档 ===
  "references": []
}
```

**三段式说明不是可选项。** 想象你在跟你妈解释这件事——她不懂"着色器缓存"，
但她能听懂"删了以后显卡会自动重建，就是第一次进游戏会慢几秒"。

---

## 3. 五个函数（发动机按顺序调用）

```powershell
# 1. 扫描：只读，返回发现的问题（DiagnosticFinding[]，无问题返回空数组，不能返回 $null）
function Invoke-Scan { param([hashtable]$Context) }

# 2. 计划：生成执行计划，必须无副作用，可反复调用
function Get-Plan { param([hashtable]$Context) }

# 3. 执行：必须幂等（重复执行结果一致，且不报错）
function Invoke-Apply { param([hashtable]$Context) }

# 4. 还原：必须能独立于 Apply 运行
function Invoke-Rollback { param([hashtable]$Context) }

# 5. 验证：Apply 后与 Rollback 后都会被调用
function Test-Result { param([hashtable]$Context) }
```

`$Context` 提供：`SystemInfo`（机型 / 内存 / 磁盘布局 / build）、已扫描结果、插件元数据、日志器。

---

## 4. 完整示例：`010-disk-shadercache`

一个真实可用的零风险插件——清理显卡驱动程序自动生成的着色器缓存。
这个项目历史上的真实收益是 **6.75 GB**。

### `plugin.json`

```json
{
  "id": "disk.shadercache",
  "name": "清理显卡着色器缓存",
  "module": "disk",
  "version": "1.0.0",
  "author": "community",
  "risk": 0,
  "defaultChecked": true,
  "reversible": true,
  "requiresAdmin": false,
  "requiresReboot": false,
  "preflight": {
    "minWindowsBuild": 22000,
    "requiresAC": false,
    "minFreeSpaceGB": 0,
    "minFreeSpacePercent": 0,
    "excludeIfProcessRunning": ["Steam.exe", "WeGame.exe"],
    "customCheck": ""
  },
  "explain": {
    "what": "删除显卡驱动程序自动生成的着色器缓存文件。",
    "why": "这些缓存会随着时间累积到数 GB，占用你系统盘的空间。Windows 在系统盘剩余空间低于 15% 时会明显变慢。",
    "risk": "无。这些文件是纯缓存，删除后显卡会在下次玩游戏时自动重建，首次进入游戏会略慢几秒。"
  },
  "targets": {
    "allowPaths": [
      "%LOCALAPPDATA%\\NVIDIA\\DXCache",
      "%LOCALAPPDATA%\\NVIDIA\\GLCache",
      "%LOCALAPPDATA%\\AMD\\DxCache"
    ],
    "allowGlobs": [],
    "denyPaths": []
  },
  "snapshot": { "method": "fileList", "registryKeys": [], "serviceStates": [], "customSave": "", "customRestore": "" },
  "estimatedBenefit": { "type": "space", "typicalValue": "2-7 GB", "unit": "GB" },
  "conflictsWith": [],
  "dependsOn": [],
  "supersedes": [],
  "references": []
}
```

### `plugin.ps1`（骨架，保留 `#Requires` 与函数签名）

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    清理显卡着色器缓存（disk.shadercache）。
.NOTES
    风险等级 0。删除目标由 plugin.json 的 targets.allowPaths 白名单声明，
    由引擎校验后执行；插件自身不拼接、不删除任意路径（铁律 L1）。
#>

Set-StrictMode -Version Latest

function Get-ShaderCacheDirectory {
    <#
    .SYNOPSIS
        只从白名单里挑出真实存在的目录。路径写死在元数据里，这里不拼接通配路径。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $declared = @($Context.Plugin.Meta.targets.allowPaths)
    $found = New-Object System.Collections.ArrayList
    foreach ($entry in $declared) {
        $expanded = [System.Environment]::ExpandEnvironmentVariables($entry)
        if (Test-Path -LiteralPath $expanded -PathType Container) {
            [void]$found.Add($expanded)
        }
    }
    return $found.ToArray()
}

function Get-ShaderCacheSize {
    <#
    .SYNOPSIS
        测量白名单目录的体积。无法读取的文件计入 Skipped，而不是算成 0（铁律 L2）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Directory)

    $total = [int64]0
    $skipped = 0
    foreach ($dir in $Directory) {
        $items = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            try {
                $total += $item.Length
            } catch {
                $skipped++
                $Context.Logger.Warn("无法读取 $($item.FullName)：$($_.Exception.Message)")
            }
        }
    }
    return [pscustomobject]@{ Bytes = $total; Skipped = $skipped }
}

function Invoke-Scan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = New-Object System.Collections.ArrayList
    $dirs = Get-ShaderCacheDirectory -Context $Context
    if ($dirs.Count -eq 0) { return $findings.ToArray() }

    $measured = Get-ShaderCacheSize -Context $Context -Directory $dirs
    $sizeGB = [math]::Round($measured.Bytes / 1GB, 2)
    if ($sizeGB -lt 0.5) { return $findings.ToArray() }

    [void]$findings.Add(@{
        Id            = 'disk.shadercache'
        Module        = 'disk'
        Severity      = 'Low'
        Title         = "显卡着色器缓存占用 $sizeGB GB"
        Summary       = "显卡驱动自动生成的缓存文件累积到了 $sizeGB GB，占了系统盘空间。删掉后显卡会自动重建。"
        Evidence      = @{
            Paths     = $dirs
            SizeGB    = $sizeGB
            Skipped   = $measured.Skipped
        }
        Impact        = '占用系统盘空间；系统盘剩余低于 15% 时 Windows 会全局降速。'
        Suggestion    = '清理这些缓存文件'
        RelatedPlugin = 'disk.shadercache'
        Confidence    = 'Confirmed'
        References    = @()
    })
    return $findings.ToArray()
}

function Get-Plan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $dirs = Get-ShaderCacheDirectory -Context $Context
    $measured = Get-ShaderCacheSize -Context $Context -Directory $dirs
    $sizeGB = [math]::Round($measured.Bytes / 1GB, 2)

    $actions = New-Object System.Collections.ArrayList
    foreach ($dir in $dirs) {
        [void]$actions.Add(@{
            Description = "清理 $dir 下的缓存文件"
            Target      = $dir
            SizeGB      = $sizeGB
        })
    }

    $warnings = @()
    if ($measured.Skipped -gt 0) {
        $warnings += "有 $($measured.Skipped) 个文件因被占用无法统计，实际可释放空间可能略有差异。"
    }

    return @{
        Findings    = @()
        Snapshot    = @{ method = 'fileList' }
        Actions     = $actions.ToArray()
        Warnings    = $warnings
        NeedsReboot = $false
    }
}

function Invoke-Apply {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    try {
        # 实际删除由引擎按 plugin.json 里的 targets 白名单执行；
        # 插件通过引擎提供的受限接口发起请求，拿不到任意路径的删除能力。
        $result = $Context.Engine.RemoveWhitelistedContent -PluginId 'disk.shadercache' -ErrorAction Stop
        return @{
            Status  = 'Success'
            Details = "已清理显卡着色器缓存，释放 $([math]::Round($result.Bytes / 1GB, 2)) GB"
            Error   = ''
        }
    } catch {
        return @{
            Status  = 'Failed'
            Details = ''
            Error   = "清理失败：$($_.Exception.Message)（可能原因：文件正被游戏或驱动占用；可稍后重试，或用还原脚本核查）"
        }
    }
}

function Invoke-Rollback {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    # 缓存类文件不需要还原：显卡会在下次使用时自动重建。
    # 但"不需要还原"必须显式说明，而不是留空函数装作做了事。
    return @{
        Status  = 'Skipped'
        Details = '着色器缓存属于可再生数据，无需还原（删除后显卡会自动重建）。'
    }
}

function Test-Result {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $dirs = Get-ShaderCacheDirectory -Context $Context
    $measured = Get-ShaderCacheSize -Context $Context -Directory $dirs
    $remainingGB = [math]::Round($measured.Bytes / 1GB, 2)

    if ($remainingGB -lt 0.5) {
        return @{ Passed = $true; Message = "缓存已清理，剩余 $remainingGB GB" }
    }
    return @{ Passed = $false; Message = "仍有 $remainingGB GB 缓存未清理（可能有文件被占用）" }
}
```

**这个例子里值得注意的三件事**：

1. `Invoke-Scan` 无问题时返回**空数组**（`$findings.ToArray()`），不是 `$null`——
   否则调用点 `.Count` 会是 `$null`，这是踩过的坑。
2. 读不了的文件单独计数并告警，**不静默忽略**。
3. `Invoke-Rollback` 明确返回 `Skipped` + 原因，而不是留一个空函数假装做了事。

---

## 5. 质量门（合并前必须全过）

| 检查 | 说明 |
|---|---|
| ✅ Schema 校验 | `plugin.json` 必填字段齐全、类型正确 |
| ✅ 风险一致性 | `risk=0` ⟺ `defaultChecked=true`；`risk>=2` ⟹ `defaultChecked=false` |
| ✅ 白名单强制 | `targets.allowPaths` 非空，且不含通配到盘根的路径 |
| ✅ 五函数齐全 | `Invoke-Scan` / `Get-Plan` / `Invoke-Apply` / `Invoke-Rollback` / `Test-Result` |
| ✅ 超时保护 | 所有 `Start-Process` 必须配 `WaitForExit(<毫秒>)` |
| ✅ 无静默失败 | `Invoke-Apply` / `Invoke-Rollback` 中禁止 `-ErrorAction SilentlyContinue` |
| ✅ 编码合规 | 文件必须是 **UTF-8 with BOM**（铁律 L4） |
| ✅ Pester 单元测试 | 至少覆盖 `Invoke-Scan` 与 `Invoke-Rollback` |
| ✅ `-WhatIf` 支持 | `$WhatIfPreference` 为真时，`Invoke-Apply` 只能输出计划 |
| ✅ Dry-run 通过 | 在 CI 的 Windows 容器里跑全流程，不产生副作用 |

### 本地自查命令

```powershell
# 铁律静态检查（L1/L2/L3/L4/L5）
Import-Module IronLaw.Checker
Invoke-IronLawCheck -Path .\plugins\010-disk-shadercache\plugin.ps1

# 完整门禁
.\ci\Invoke-Analysis.ps1
```

### 关于编码：为什么必须 UTF-8 with BOM

PowerShell 5.1 在中文系统上会把**无 BOM** 的文件按 ANSI（GBK）解析。后果是中文注释变乱码，
严重时直接报一堆莫名其妙的语法错误——真实事故里一个 339 行的脚本报了 18 个语法错误，
根因就是这个。

```powershell
# 写文件时显式带 BOM
[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($true)))
```

---

## 6. 提交前自检清单

- [ ] `plugin.json` 的 `risk` 和 `defaultChecked` 符合 §2 的一致性规则
- [ ] 三段式说明是**白话**，而且 `risk` 字段写了具体的最坏情况
- [ ] `targets.allowPaths` 是白名单（没有排除法、没有通配到盘根）
- [ ] 没有任何用户数据目录出现在代码或元数据里
- [ ] 没有 `-ErrorAction SilentlyContinue`，没有空 `catch`
- [ ] 所有外部调用都有超时
- [ ] 文件是 UTF-8 with BOM
- [ ] 跑了 `.\ci\Invoke-Analysis.ps1`，绿的
- [ ] 在插件 `README.md` 里写清**为什么给它定这个风险等级**

最后一条最容易被跳过，但它恰恰最重要：**定不出风险等级的理由，说明你还没想清楚它会做什么。**
