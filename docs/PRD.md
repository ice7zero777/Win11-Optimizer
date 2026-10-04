<!-- IronLaw-Suppress: * - This file IS the project's requirements document. Its code samples deliberately show FORBIDDEN anti-patterns (exclusion-based deletion, -ErrorAction SilentlyContinue) as counter-examples; PRD section 12 exists precisely to ban them. A blanket suppression is correct here because the file is the rule specification, and the CI gate still checks every other file. -->

# Win11 一键诊断与安全优化工具 —— 需求文档（PRD）

> **这份文档是本仓库唯一的规格来源。** README、贡献指南、安全政策里所有的"永久不做"清单、
> P1–P5 设计原则、L1–L10 铁律，都以本文为准；任何实现细节与本文冲突时，以本文为准。
>
> ⚠️ 文中的代码片段**故意包含被禁止的反例**（排除法删除、静默失败等）。它们是要被 §12 铁律
> 拒绝的写法，不是可以照抄的实现——这正是本文件带 `IronLaw-Suppress: *` 的原因。
>
> 路径约定：文中提到的目录（`engine/`、`plugins/`、`docs/` 等）均指本仓库根目录下的相对路径。

---

> 文档版本：v1.0
> 状态：待评审
> 目标平台：Windows 11（21H2 及以上）
> 技术栈：PowerShell 5.1+ 引擎 + 可选 GUI 壳
> 文档定位：可直接用于新工作区启动开发
>
> 本文描述的是**目标设计**。实现进度以 [`../README.md`](../README.md) 的
> 「当前进度（诚实版）」为准，不要按本文误认为功能已经实现。

---

## 1. 项目概述

### 1.1 一句话定位

**一个以"安全第一"为铁律的 Windows 11 诊断与优化工具：先只读扫描全盘找出问题，用普通人能看懂的话列成清单，由用户逐项勾选，再在自动快照保护下逐项执行，全程可一键还原。**

### 1.2 要解决的真实痛点

普通用户的 Windows 11 电脑变慢，真正原因往往不是"软件装多了"，而是少数几个隐蔽问题：

| 真实瓶颈 | 典型表现 | 用户为什么找不到 |
|---|---|---|
| 厂商服务内存泄漏（如 Dell `ServiceShell` 吃 1.8 GB） | 开机慢、一直卡 | 进程名看不懂，也没有任何提示 |
| 三套安全软件同时实时扫描 | 磁盘 100%、风扇狂转 | 以为"多装几个更安全" |
| 系统盘剩余空间低于 15% | 全局降速 | 不知道有个"15% 阈值" |
| 第三方软件劫持 hosts / Winsock | 某软件莫名卡死 | 完全看不到这层 |
| 电源方案被第三方组件改写限频 | 特定场景卡 | 不知道 CPU 被压了 |
| 微软更新引入的已知缺陷 | 托盘消失等 | 不会联想到更新 |

**市面工具的失败模式**（本项目要避免的）：
- 一键"深度优化"不解释改了什么 → 用户不敢用
- 用注册表一键清理 → 收益极小、风险极高
- 卸载/删除操作不可逆 → 出问题没救
- 按"通用清单"无差别优化 → 不了解本机实际情况

### 1.3 目标用户

| 用户类型 | 占比预期 | 核心诉求 |
|---|---|---|
| **普通用户（主要）** | 80% | "我不想懂技术，但我想知道它在动什么，而且别搞坏我的电脑" |
| 半技术用户 | 15% | 想知道每一项的技术细节，能自己判断 |
| IT / 开发者 | 5% | 想批量、可脚本化、可审计 |

### 1.4 非目标（明确不做）

以下内容**本项目永久不做**，任何 Feature Request 都不接受：

| 不做的事 | 原因 |
|---|---|
| ❌ 删除或移动用户数据文件 | 最高铁律，见 §3 P1 |
| ❌ "注册表一键清理"类黑盒操作 | 收益极小、风险不可控 |
| ❌ 自动修改网络配置（重置 Winsock/DNS 等） | 有断网风险，只诊断不修 |
| ❌ 自动卸载软件 | 卸载不可逆，只提示"建议卸载"并给出官方卸载入口 |
| ❌ 自动删除 >100 MB 的文件 | 必须用户显式、单独确认 |
| ❌ 驱动与固件自动升级 | 蓝屏/变砖风险，只列出可用更新 |
| ❌ 上传任何用户数据到网络 | 隐私铁律 |

### 1.5 成功标准

| 指标 | 目标 |
|---|---|
| 首次运行到看到诊断报告 | ≤ 3 分钟（不含用户选择时间） |
| 零风险项执行成功率 | ≥ 99% |
| 执行后可一键还原率 | **100%**（每项都要有还原路径） |
| 误删用户数据的案例 | **0**（架构级保证，不靠"小心"） |
| 普通用户能独立看懂报告 | 用户测试中 ≥ 90% 能说出"我的电脑有什么问题" |

---

## 2. 核心设计原则

> 以下五条是**架构级铁律**。任何实现细节与它们冲突时，以本节为准。

### P1 —— 永不触碰用户数据

**定义**：工具**绝不**删除、移动、重命名、修改任何"用户数据文件"。

**用户数据文件判定规则**（满足任一即为用户数据，受最高保护）：
```
1. 位于用户文档目录：Desktop / Documents / Downloads / Pictures / Videos / Music
2. 位于用户指定的任何数据盘路径
3. 非 Windows 系统组件、非已知软件安装目录的任意文件
4. 扩展名为用户内容类型：.docx .xlsx .pptx .pdf .jpg .mp4 .psd .zip .rar .7z 等
5. 无法明确归类为"缓存/临时/日志/安装包"的任何文件
```

**缓存类文件的判定必须"白名单化"**，即：只允许删除**明确列入白名单的缓存路径**，绝不使用"排除法"（排除掉重要的，剩下都删）。

**反例（绝不允许的实现）**：
```powershell
# ❌ 危险：排除法，未预料的目录会被误删
Get-ChildItem 'D:\' -Recurse | Where-Object { $_.FullName -notmatch 'Desktop|Documents' } | Remove-Item
```

**正例（唯一允许的形式）**：
```powershell
# ✅ 白名单，路径写死在插件元数据里
$allowedCachePaths = @(
  "$env:LOCALAPPDATA\NVIDIA\DXCache",
  "$env:LOCALAPPDATA\NVIDIA\GLCache"
)
foreach ($p in $allowedCachePaths) {
  if (Test-Path $p) { Remove-Item "$p\*" -Recurse -Force }
}
```

### P2 —— 默认安全

- 默认**只勾选零风险项**（Risk 0）
- 任何 `Risk ≥ 2` 的项**默认不勾选**，且需用户展开"高级"区域才可见
- `Risk ≥ 3` 的项需要**二次书面确认**（输入指定文字或勾选免责框）
- 存在"预检失败"（如非管理员、非 Win11、磁盘空间不足）时，**对应项自动禁用并说明原因**，而不是静默跳过

### P3 —— 全程可逆

- 每一类操作在**改动前**自动生成快照，写入 `Snapshot/`
- 执行完毕后自动生成 `Restore-All.ps1`，一键还原**所有**已执行的改动
- 还原脚本本身要能被验证（`-WhatIf` 模式先演练）

### P4 —— 透明可解释

- 每个优化项必须提供**三段式说明**：
  - `What`：要做什么（白话）
  - `Why`：为什么这会让你卡/出问题（白话，带数据）
  - `Risk`：最坏情况是什么
- 报告中每个问题必须带**本机实测数据**（不是"可能存在"），例如：
  > ✅ `ServiceShell.exe 正在占用 1782 MB 内存 —— 这是戴尔官方已确认的内存泄漏缺陷`

### P5 —— 了解本机实际情况

- 诊断阶段**先探测本机配置**（机型/内存/磁盘类型/分区布局/系统版本）
- 优化建议必须**基于实测数据生成**，不是照搬通用清单
- 例：如果 C 盘和 D 盘在同一块物理盘，则不应建议"把页面文件移到 D 盘"

---

## 3. 系统架构

### 3.1 分层设计

```
┌─────────────────────────────────────────────────────────┐
│  表现层 (Presentation)                                   │
│  · 控制台 UI (MVP，必须有)                               │
│  · GUI 壳 (Phase 2，可选)                                │
│  职责：渲染报告、收集勾选、展示进度、输出还原脚本          │
└────────────────────────┬────────────────────────────────┘
                         │ 只依赖 IOptimizerEngine 接口
┌────────────────────────┴────────────────────────────────┐
│  引擎层 (Engine)                                         │
│  · DiagnosticRunner  全量扫描调度                        │
│  · PluginLoader      插件发现/校验/加载                   │
│  · SelectionModel    勾选与依赖解析                       │
│  · ExecutionEngine   顺序执行/预检/超时/日志               │
│  · SnapshotManager   快照创建与还原脚本生成                │
│  职责：编排，不含任何具体优化逻辑                          │
└────────────────────────┬────────────────────────────────┘
                         │ 插件契约 (plugin.json + plugin.ps1)
┌────────────────────────┴────────────────────────────────┐
│  插件层 (Plugins)                                        │
│  · 每个优化项 = 一个独立目录                              │
│  · disk/  service/  startup/  power/  security/          │
│    privacy/  device/  network/  environment/  update/    │
│  职责：实现 Scan / Plan / Apply / Rollback / Verify       │
└─────────────────────────────────────────────────────────┘
```

**关键架构约束**：表现层**不得**包含任何优化逻辑。GUI 与 CLI 必须能并行存在且行为一致。

### 3.2 目录结构

```
Win11-Optimizer/
├─ Win11Optimizer.ps1              # 主入口（CLI）
├─ Start-Optimizer.cmd             # ⚠️ 纯 ASCII 文件名的自提权启动器
├─ README.md
├─ LICENSE
├─ CHANGELOG.md
├─ docs/
│  ├─ plugin-development.md        # 插件开发指南
│  ├─ safety-model.md              # 安全模型详解
│  └─ contributing.md
├─ engine/
│  ├─ DiagnosticRunner.ps1
│  ├─ PluginLoader.ps1
│  ├─ SelectionModel.ps1
│  ├─ ExecutionEngine.ps1
│  ├─ SnapshotManager.ps1
│  ├─ ReportRenderer.ps1
│  ├─ Logger.ps1
│  ├─ Preflight.ps1
│  └─ Contracts.ps1                # 所有插件的返回契约定义
├─ plugins/
│  ├─ registry.json                # 插件索引（可选，用于排序/分组）
│  ├─ 010-disk-shadercache/
│  │  ├─ plugin.json
│  │  ├─ plugin.ps1
│  │  └─ README.md
│  ├─ 020-disk-updatecache/
│  ├─ 030-disk-winsxs/
│  ├─ 040-service-vendor-bloat/    # 厂商服务精简
│  ├─ 050-service-security-conflict/# 多套杀软冲突检测
│  ├─ 060-startup-autorun/
│  ├─ 070-startup-scheduledtask/
│  ├─ 080-power-scheme/
│  ├─ 090-power-sustainability/    # 可持续性劫持（实战发现）
│  ├─ 100-privacy-telemetry/
│  ├─ 110-network-hosts-hijack/    # 只诊断！
│  ├─ 120-network-lsp-residue/     # 只诊断！
│  ├─ 130-device-phantom/          # 幽灵设备
│  ├─ 140-environment-preflight/   # 运行环境自检
│  └─ 150-update-pending/
├─ lib/
│  ├─ ps1-encoding.ps1             # BOM 处理（铁律 L2）
│  ├─ safe-delete.ps1              # 白名单删除封装
│  ├─ safe-service.ps1             # 服务操作封装（含超时）
│  ├─ log-scan.ps1                 # 日志静默检测
│  └─ ui-console.ps1               # 控制台渲染工具
└─ tests/
   ├─ unit/
   ├─ integration/
   └─ fixtures/                    # 各机型的诊断数据样本
```

### 3.3 数据流

```
[启动]
   ↓
[Preflight 环境自检]  → 非Win11/非管理员/磁盘不足 → 明确提示并决定能否继续
   ↓
[全量扫描]  插件并行/顺序调用 Scan()  →  产出 DiagnosticFinding[]
   ↓
[生成报告 + 勾选清单]  按风险分级渲染，零风险默认勾选
   ↓
[用户勾选 + 确认高风险项]
   ↓
[依赖解析 + 冲突检测]  → 发现冲突则报告并要求用户调整
   ↓
[执行]  逐项：Preflight → Snapshot → Apply → Verify
   ↓
[生成还原脚本 Restore-All.ps1]
   ↓
[输出最终报告 + 后续建议（如需重启）]
```

---

## 4. 诊断引擎需求

### 4.1 诊断模块清单

| 模块 ID | 模块名 | 检测内容 | 输出示例（白话） |
|---|---|---|---|
| `env` | 运行环境 | 是否管理员、Win11 版本、PowerShell 版本、可用磁盘、系统还原是否可用 | "检测到你不是管理员权限，有 12 项优化无法执行" |
| `disk` | 磁盘空间 | 各分区剩余空间与百分比、`<15%` 降速阈值告警、白名单缓存目录体积 | "C 盘只剩 13.5% 空间，Windows 在低于 15% 时会明显变慢" |
| `component` | 系统组件 | WinSxS 体积、DISM 组件健康状态、更新缓存、WinRE、休眠文件 | "Windows 更新缓存占了 233 MB，可以安全清理" |
| `service` | 服务 | 第三方常驻服务清单、厂商服务识别（Dell/Lenovo/HP/ASUS…）、厂商不匹配检测、**高内存服务进程识别** | "发现 Dell 的 ServiceShell.exe 占用 1782 MB —— 戴尔官方确认的内存泄漏缺陷" |
| `startup` | 启动项 | 注册表 Run 键、启动文件夹、计划任务、StartupApproved 状态 | "Wallpaper Engine 开机自启，会吃掉 GPU 和内存" |
| `task` | 计划任务 | 非微软任务识别、遥测任务、广告推广任务（如 SoftLanding）、更新任务 | "发现 2 个广告推广任务，是 Windows 家庭版预装的" |
| `power` | 电源 | 当前电源方案、CPU 上限（PROCTHROTTLEMAX）、睡眠/合盖设置、**第三方限频方案识别** | "你的电源方案被第三方软件改成了'健康'方案，CPU 被限制在 60%" |
| `security` | 安全软件 | 多套实时防护共存检测、杀软残留（注册表/目录/服务） | "检测到 3 套安全软件同时运行，它们互相扫描会导致磁盘 100%" |
| `privacy` | 隐私/遥测 | 遥测计划任务、有争议的注册表项（诊断为主） | "发现 3 个 Google 遥测任务，会定期联网" |
| `network` | 网络（**只诊断**） | hosts 劫持、Winsock LSP 残留、虚拟网卡、DNS 设置、网络驱动 | "hosts 文件被 Steam++ 写入了 47 条记录，把 Steam 域名指向了本机" |
| `device` | 设备健康 | 幽灵设备、错误设备（Code 28 等）、降级设备、驱动年龄 | "发现 12 个 Intel XTU 幽灵设备，是卸载残留" |
| `update` | 更新 | 待装更新、支持已结束的 Windows 版本、已知问题更新 | "有 1 个 BIOS 固件更新（1.28.0 → 1.37.0），可修复安全漏洞" |
| `residue` | 卸载残留 | 已卸载软件的目录/注册表/服务残留 | "Navicat 已卸载，但注册表里还有 6 个残留项" |

### 4.2 关键检测算法（从实战提炼）

#### 4.2.1 厂商服务识别

```
匹配规则（按优先级）：
1. 服务路径含已知厂商目录：
   C:\Program Files\Dell, \Lenovo, \HP, \ASUS, \Acer, \MSI, \Samsung
2. 服务名/显示名含厂商关键词
3. 交叉校验：机型制造商 vs 服务厂商
   例：Alienware 机器上出现 Lenovo 服务 → 标记为"厂商不匹配，建议处理"
4. 内存泄漏信号：同名进程内存 > 500 MB 且非已知大型应用
```

#### 4.2.2 电源方案劫持检测

```
检查项：
1. 当前方案 GUID 是否属于 Windows 原生（平衡/高性能/节能）
2. 若非原生 → 检查所有方案的 PROCTHROTTLEMAX 值
3. 若任一方案最大值 < 100 → 报告"CPU 被限频"
4. 检查 \Microsoft\Windows\Sustainability\* 计划任务是否启用
5. 检查 WSAIFabricSvc / 相关服务启动类型
→ 关键：要报告"哪个组件在劫持"，不能只说"方案被改了"
```

#### 4.2.3 网络劫持检测（只读）

```
hosts 分析：
1. 读取 hosts，提取非注释行
2. 检测 127.0.0.1 / 0.0.0.0 指向的域名
3. 检查是否有第三方工具标记（如 "# Steam++ Start/End"）
4. 报告：域名清单、疑似来源工具、影响范围
5. ⚠️ 绝不自动修改，只给出建议 + 备份当前 hosts

LSP 分析：
1. netsh winsock show catalog → 统计 Layered Service Provider 数量
2. 若存在第三方 LSP → 报告，并说明"删除 DLL 前必须先注销 LSP"
3. ⚠️ 绝不自动 netsh winsock reset（有断网风险）
```

### 4.3 诊断输出契约

```powershell
# DiagnosticFinding —— 所有诊断模块必须返回此结构
@{
    Id          = 'service.shell-memory-leak'      # 全局唯一，格式 <module>.<slug>
    Module      = 'service'
    Severity    = 'High'                            # Critical | High | Medium | Low | Info
    Title       = 'ServiceShell 内存泄漏（1782 MB）'
    Summary     = '戴尔的服务进程占用了 1782 MB 内存，这是官方已确认的缺陷，会导致严重的内存分页和整机卡顿。'
    Evidence    = @{                                # 必须带实测数据
        ProcessName = 'ServiceShell'
        MemoryMB    = 1782
        ServiceName = 'DellClientManagementService'
        Vendor      = 'Dell'
    }
    Impact      = '开机后持续卡顿，内存被占用 11%'
    Suggestion  = '将该服务启动类型改为"手动"'
    RelatedPlugin = '040-service-vendor-bloat'
    Confidence  = 'Confirmed'                       # Confirmed | Likely | Speculative
    References  = @('https://www.dell.com/community/...')  # 可选，官方来源
}
```

**`Confidence` 字段是硬性要求**：不允许把推测当成确凿问题报告给用户。若无法确认，必须标 `Speculative` 并降低 Severity。

---

## 5. 插件规范

### 5.1 目录结构

```
plugins/<NNN>-<slug>/
├─ plugin.json      # 元数据（必需）
├─ plugin.ps1       # 实现（必需）
└─ README.md        # 说明文档（强烈建议）
```

### 5.2 plugin.json Schema

```jsonc
{
  // === 身份 ===
  "id": "disk.shadercache",              // 唯一，格式 <module>.<slug>
  "name": "清理显卡着色器缓存",
  "module": "disk",
  "version": "1.0.0",
  "author": "community",

  // === 风险与安全（最关键） ===
  "risk": 0,                              // 0=零风险 1=低 2=中 3=高
  "defaultChecked": true,                 // risk=0 时必须为 true；risk>=2 必须为 false
  "reversible": true,                     // 是否可还原
  "requiresAdmin": false,
  "requiresReboot": false,

  // === 前置条件 ===
  "preflight": {
    "minWindowsBuild": 22000,             // Win11 最低版本
    "requiresAC": false,                  // 是否必须接电源
    "minFreeSpaceGB": 0,
    "minFreeSpacePercent": 0,
    "excludeIfProcessRunning": ["Steam.exe"],  // 这些进程在跑时跳过
    "customCheck": "Test-ShaderCachePresent"   // plugin.ps1 中的自定义函数名
  },

  // === 面向用户的说明（P4 铁律，三段式必填） ===
  "explain": {
    "what": "删除显卡驱动程序自动生成的着色器缓存文件。",
    "why": "这些缓存会随着时间累积到数 GB，占用你系统盘的空间。删除后显卡会自动重建，首次进入游戏时会略慢，之后恢复正常。",
    "risk": "无。这些文件是纯缓存，删除不会影响任何功能。"
  },

  // === 目标路径白名单（铁律 L1：只用白名单） ===
  "targets": {
    "allowPaths": [
      "%LOCALAPPDATA%\\NVIDIA\\DXCache",
      "%LOCALAPPDATA%\\NVIDIA\\GLCache",
      "%LOCALAPPDATA%\\AMD\\DxCache"
    ],
    "allowGlobs": ["*.nvph", "*.bin"],
    "denyPaths": []                        // 额外禁止（双层保护）
  },

  // === 快照与还原 ===
  "snapshot": {
    "method": "none",                      // none | fileList | registry | serviceState | custom
    "registryKeys": [],
    "serviceStates": [],
    "customSave": "",
    "customRestore": ""
  },

  // === 预估效果（用于展示收益） ===
  "estimatedBenefit": {
    "type": "space",                       // space | memory | speed | security
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

### 5.3 plugin.ps1 接口契约

```powershell
# 每个插件必须实现以下函数。引擎按顺序调用。

<#
.SYNOPSIS
  扫描本机，返回该插件职责范围内发现的问题。
.OUTPUTS
  DiagnosticFinding[] —— 见 §4.3。无问题时必须返回空数组，不能返回 $null。
#>
function Invoke-Scan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    # $Context 包含：SystemInfo / 已扫描结果 / 插件元数据 / 日志器
}

<#
.SYNOPSIS
  生成执行计划。必须可在不产生副作用的前提下调用任意次。
.OUTPUTS
  @{
    Findings   = DiagnosticFinding[]   # 本次将处理的问题
    Snapshot   = @{ method=...; ... }  # 需要保存什么
    Actions    = @(                    # 可读的操作清单，展示给用户
      @{ Description='删除 C:\...\DXCache (6.75 GB)'; Target='C:\...'; SizeGB=6.75 }
    )
    Warnings   = string[]              # 用户需知晓的注意事项
    NeedsReboot = $false
  }
#>
function Get-Plan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
}

<#
.SYNOPSIS
  执行优化。必须幂等：重复执行结果一致，不报错。
.OUTPUTS
  ApplyResult —— @{ Status='Success'|'Partial'|'Failed'; Details=...; Error=... }
#>
function Invoke-Apply {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    # ⚠️ 硬性要求：所有外部进程调用必须带超时
    # ✅ 正确
    #   $p = Start-Process ... -PassThru
    #   if (-not $p.WaitForExit(60000)) { taskkill /F /PID $p.Id; return Failed }
    # ❌ 禁止
    #   Start-Process ... -Wait      # 无超时，可能永久卡死（铁律 L3）
}

<#
.SYNOPSIS
  还原 Apply 所做的改动。必须能独立于 Apply 运行。
.OUTPUTS
  RollbackResult —— @{ Status=...; Details=... }
#>
function Invoke-Rollback {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
}

<#
.SYNOPSIS
  验证结果是否符合预期。Apply 后与 Rollback 后都会被调用。
.OUTPUTS
  @{ Passed=[bool]; Message=[string] }
#>
function Test-Result {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
}
```

### 5.4 插件质量门（CI 强制）

插件合并前必须通过：

| 检查 | 说明 |
|---|---|
| ✅ Schema 校验 | `plugin.json` 符合 §5.2 全部必填字段 |
| ✅ 风险一致性 | `risk=0` ⟺ `defaultChecked=true`；`risk>=2` ⟹ `defaultChecked=false` |
| ✅ 白名单强制 | `targets.allowPaths` 非空，且不含通配到盘根的路径 |
| ✅ 五函数齐全 | `Invoke-Scan`/`Get-Plan`/`Invoke-Apply`/`Invoke-Rollback`/`Test-Result` |
| ✅ 超时保护 | 静态扫描：所有 `Start-Process` 必须配 `WaitForExit(毫秒)` |
| ✅ 无静默失败 | 禁止在 Apply/Rollback 中使用 `-ErrorAction SilentlyContinue`（铁律 L2） |
| ✅ 编码合规 | 文件必须为 UTF-8 with BOM（铁律 L4） |
| ✅ Pester 单元测试 | 至少覆盖 Scan 与 Rollback |
| ✅ `-WhatIf` 支持 | Apply 在 `$WhatIfPreference` 为真时只能输出计划 |
| ✅ Dry-run 通过 | 在 CI 的 Windows 容器里跑全流程不产生副作用 |

---

## 6. 风险分级与选择列表

### 6.1 风险等级定义

| 等级 | 名称 | 颜色 | 默认勾选 | 说明 | 典型优化项 |
|---|---|---|---|---|---|
| **0** | 零风险 | 🟢 绿 | ✅ **是** | 纯缓存/临时文件，删除后自动重建；或纯配置调整 | 着色器缓存、临时文件、回收站、更新缓存 |
| **1** | 低风险 | 🔵 蓝 | ✅ 是 | 可逆的配置改动，可能轻微改变使用习惯 | 关闭自启项、调整视觉特效、电源方案 |
| **2** | 中风险 | 🟡 黄 | ❌ **否** | 改变系统行为，需用户主动展开"高级"才可见 | 服务改手动、禁用遥测任务、卸载建议 |
| **3** | 高风险 | 🔴 红 | ❌ **否** | 需要二次确认；可能影响功能或需重启 | 页面文件迁移、组件清理、更新安装 |
| **4** | 极高风险 | ⛔ 黑 | ❌ **永不勾选** | 仅作为"建议"输出，工具不代执行 | 卸载软件、BIOS 更新、驱动升级 |

### 6.2 选择列表 UI 规格（控制台）

```
╔══════════════════════════════════════════════════════════════════════════╗
║  Win11 优化工具 —— 诊断结果                                              ║
║  机型: Alienware m15 R3 | Win11 25H2 (26200.9457) | 内存 15.77 GB        ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                          ║
║  🟢 零风险 —— 建议全部执行（预计释放 12.4 GB，无副作用）                  ║
║  ──────────────────────────────────────────────────────────────────────  ║
║  [✓] 1. 清理显卡着色器缓存                             释放 6.75 GB  ⓘ   ║
║  [✓] 2. 清理 Windows 更新缓存                          释放 0.23 GB  ⓘ   ║
║  [✓] 3. 清理临时文件                                   释放 3.40 GB  ⓘ   ║
║  [✓] 4. 重建显示图标缓存                               提升响应速度  ⓘ   ║
║                                                                          ║
║  🔵 低风险 —— 可逆的配置调整                                              ║
║  ──────────────────────────────────────────────────────────────────────  ║
║  [✓] 5. 关闭 Wallpaper Engine 开机自启                 省 96 MB      ⓘ   ║
║  [✓] 6. 电源方案恢复为"平衡" + CPU 上限 100%           解除限频      ⓘ   ║
║                                                                          ║
║  🟡 中风险 —— 需要你确认（输入 a 展开）                                   ║
║  ──────────────────────────────────────────────────────────────────────  ║
║  [ ] 7. 将 9 个戴尔服务改为"手动"启动                  省 300 MB     ⓘ   ║
║  [ ] 8. 禁用 Windows 遥测计划任务                      提升隐私      ⓘ   ║
║                                                                          ║
║  ⛔ 仅建议（工具不会代你执行）                                            ║
║  ──────────────────────────────────────────────────────────────────────  ║
║  !  卸载"微软电脑管家"—— 与 Defender 冲突，请从"设置→应用"手动卸载      ║
║  !  有 1 个 BIOS 更新可用（1.28.0 → 1.37.0），建议单独进行                ║
║                                                                          ║
╠══════════════════════════════════════════════════════════════════════════╣
║  已选 6 项 | 预计释放 12.4 GB + 396 MB 内存                              ║
║  [Enter] 开始执行   [a] 展开高级项   [d] 查看某项详情   [n] 全不选   [q]  ║
╚══════════════════════════════════════════════════════════════════════════╝
```

**要求**：
- `ⓘ` 可展开查看三段式说明（What/Why/Risk）
- 每项必须显示**预估收益**（带单位）
- 分风险区段展示，**高风险区默认折叠**
- 底部实时显示已选数量与预计总收益
- 支持键盘操作（不依赖鼠标）

### 6.3 依赖与冲突处理

```powershell
# 冲突示例：关闭 Defender 与安装第三方杀软互斥
"conflictsWith": ["security.install-thirdparty-av"]

# 依赖示例：组件清理依赖 DISM 健康检查通过
"dependsOn": ["component.dism-healthcheck"]
```

**处理规则**：
- 用户勾选 A，但 A 与已勾选的 B 冲突 → **立即提示，要求二选一**，不允许静默去掉一个
- 用户勾选 A，但 A 依赖未勾选的 C → **自动勾选 C 并高亮提示**，或要求用户手动勾选
- 依赖链中存在 `Risk ≥ 2` 的项 → 必须逐项确认

---

## 7. 安全架构

> 本节是项目的**核心价值**，也是与市面工具的**主要差异点**。

### 7.1 快照机制

| 操作类型 | 快照方式 | 存储位置 | 还原方式 |
|---|---|---|---|
| 文件删除 | 记录文件清单 + 大小 + 时间戳 | `Snapshot/filelist-<id>.json` | 无法还原文件内容（缓存类无需还原） |
| 服务启动类型 | 导出 `Get-Service` 名称/StartType/Status | `Snapshot/services-<ts>.json` | `Set-Service -StartupType <原值>` |
| 注册表改动 | `reg export` 导出相关键 | `Snapshot/registry-<id>.reg` | `reg import` |
| 计划任务 | 导出 `Get-ScheduledTask` 定义 | `Snapshot/tasks-<ts>.json` | `Register-ScheduledTask` |
| 电源方案 | `powercfg /list` + 关键设置值 | `Snapshot/power-<ts>.json` | `powercfg /setacvalueindex` |
| 启动项 | 导出 Run 键 | `Snapshot/startup-<ts>.reg` | `reg import` |
| 页面文件 | 记录原配置 | `Snapshot/pagefile-<ts>.json` | 恢复注册表 PagingFiles |

**快照目录结构**：
```
Snapshot/
├─ 2026-10-04_143022/                 # 每次运行一个时间戳目录
│  ├─ manifest.json                   # 本次执行的变更总账
│  ├─ services-143022.json
│  ├─ registry-startup.reg
│  ├─ power-143022.json
│  └─ ...
└─ Restore-All.ps1                    # 最新一次的一键还原
```

**`manifest.json` 结构**（变更总账，供还原脚本读取）：
```jsonc
{
  "runId": "2026-10-04_143022",
  "startedAt": "2026-10-04T14:30:22",
  "systemInfo": { "model": "Alienware m15 R3", "build": "26200.9457" },
  "changes": [
    {
      "pluginId": "service.vendor-bloat",
      "risk": 2,
      "appliedAt": "2026-10-04T14:32:10",
      "status": "Success",
      "snapshotFile": "services-143022.json",
      "rollbackHint": "Set-Service -Name DellClientManagementService -StartupType Automatic"
    }
  ]
}
```

### 7.2 一键还原脚本

执行完毕后必须生成 `Restore-All.ps1`，要求：

```powershell
# 特性要求：
# 1. 支持 -WhatIf 演练模式（只显示将做什么）
# 2. 支持 -Only <pluginId> 单独还原某一项
# 3. 支持 -List 列出所有可还原项
# 4. 还原失败要明确报告，不静默跳过
# 5. 自带管理员权限检查
# 6. 还原后自动验证并输出结果
```

### 7.3 执行前预检（Preflight）

每一项执行前必须通过的检查：

| 检查 | 失败处理 |
|---|---|
| 管理员权限 | 需要则提示提权，否则跳过该项（**不静默跳过，要说明**） |
| 系统版本 | 非 Win11 则禁用相关项 |
| 磁盘空间 | 不足则拒绝并说明需要多少 |
| 电源状态 | 需要 AC 的项（如页面文件迁移）在电池下拒绝 |
| 目标进程未运行 | 从 `excludeIfProcessRunning` 读取 |
| 目标路径在白名单内 | **强制校验**，不在白名单直接拒绝 |
| 无冲突项已选 | 检测 `conflictsWith` |
| 依赖项已选 | 检测 `dependsOn` |

### 7.4 危险操作白名单（架构级）

引擎必须内置以下**运行时防护**，不依赖插件自觉：

```powershell
# 引擎强制拦截：任何插件试图操作以下路径 → 立即中止并报错
$FORBIDDEN_PATHS = @(
  "$env:USERPROFILE\Desktop",
  "$env:USERPROFILE\Documents",
  "$env:USERPROFILE\Downloads",
  "$env:USERPROFILE\Pictures",
  "$env:USERPROFILE\Videos",
  "$env:USERPROFILE\Music",
  'C:\Windows\System32',
  'C:\Windows\SysWOW64',
  'C:\Windows\WinSxS',           # 只能通过 DISM 操作
  'C:\Program Files',
  'C:\Program Files (x86)',
  'C:\ProgramData\Microsoft',
  'C:\Users',
  'C:\$Recycle.Bin',
  'C:\System Volume Information',
  'C:\Recovery'
)

# 引擎强制拦截：以下命令模式禁止出现在插件中
$FORBIDDEN_PATTERNS = @(
  'Remove-Item.*-Recurse.*C:\\$',           # 删除盘根
  'Format-Volume',
  'Clear-Disk',
  'Initialize-Disk',
  'Remove-Partition',
  'net\s+user.*\/delete',                    # 删用户
  'netsh\s+winsock\s+reset',                 # 网络重置
  'bcdedit.*\/delete',
  'Set-ExecutionPolicy\s+Unrestricted',      # 放宽执行策略
  'Disable-RealtimeMonitoring',              # 关 Defender
  'Stop-Service.*WinDefend'
)

# 引擎强制拦截：单次删除超过阈值需显式确认
$BULK_DELETE_THRESHOLD_MB = 100
```

**校验时机**：插件加载时静态扫描 + 运行时动态拦截（双重）。

---

## 8. 用户体验流程

### 8.1 完整流程

```
[1] 启动
    ├─ 检查管理员权限
    │   └─ 非管理员 → 显示"部分功能不可用"，并给出提权指引
    ├─ 检查 Windows 版本
    │   └─ 非 Win11 → 明确提示不支持并退出
    └─ 显示欢迎 + 本工具的安全承诺（一句话）

[2] 环境与权限自检（约 5 秒）
    输出：机型、Windows 版本、内存、磁盘布局、权限状态
    ⚠️ 若检测到高风险环境（如 BitLocker 加密、系统还原不可用）→ 提前告知

[3] 全量扫描（约 30 秒 ~ 2 分钟，带进度条）
    逐模块扫描并显示当前在查什么
    允许用户中途查看已发现的问题

[4] 诊断报告 + 勾选清单
    ├─ 顶部：本机概要 + 发现的问题统计
    ├─ 分区段展示（按风险分级）
    ├─ 每项可展开看三段式说明 + 实测证据
    └─ 高风险项默认折叠

[5] 用户选择
    ├─ 冲突检测 → 提示并解决
    ├─ 依赖补全 → 自动勾选或要求手动
    └─ 显示"将执行 X 项，预计释放 Y，需重启：是/否"

[6] 确认与执行
    ├─ 显示操作摘要清单
    ├─ Risk>=3 项二次确认
    └─ 逐项执行：
        Preflight → Snapshot → Apply → Verify
        实时输出每项结果

[7] 生成还原脚本 + 最终报告
    ├─ 报告：成功/失败/跳过 统计
    ├─ 效果：实际释放空间、内存变化
    ├─ 后续：是否需要重启、重启后要做什么
    └─ 还原：Restore-All.ps1 的位置和使用方法

[8] 完成
    可选择：立即重启 / 稍后 / 查看详细日志 / 还原
```

### 8.2 文案规范（普通用户向）

**必须遵守**：

| 规则 | 反例 ❌ | 正例 ✅ |
|---|---|---|
| 用白话解释技术问题 | "ServiceShell 进程内存占用异常" | "戴尔的一个后台程序吃掉了 1.78 GB 内存（占总量的 11%），这会让你的电脑一直发卡" |
| 带本机实测数据 | "可能存在缓存占用" | "显卡缓存占了 6.75 GB" |
| 说明最坏情况 | "调整服务启动类型" | "把 9 个戴尔服务改成手动启动。最坏情况：以后要更新戴尔驱动时，需要先手动开一次服务（工具会告诉你怎么做）" |
| 避免绝对化承诺 | "能让电脑快 50%" | "预计释放 12.4 GB 空间。空间不足是导致卡顿的原因之一，但卡顿通常有多个原因" |
| 不使用未解释的缩写 | "清理 WinSxS" | "清理 Windows 组件存储（系统更新的历史备份，微软官方支持清理）" |

**三段式说明的模板**：

```
【要做什么】
  删除显卡驱动程序自动生成的着色器缓存。

【为什么这会影响你】
  这些缓存会随着时间累积。你的电脑上已经积累了 6.75 GB，
  占了系统盘可用空间的 24%。Windows 在系统盘剩余空间低于 15% 时会
  明显变慢，你现在是 13.5%，已经越线。

【最坏情况】
  无。这些文件是纯缓存，删除后显卡会在你下次玩游戏时自动重建，
  首次进入游戏会略慢几秒。
```

### 8.3 错误与失败处理规范

**铁律：不允许静默失败。**

```powershell
# ❌ 禁止：错误被吞掉，用户以为成功了
$ErrorActionPreference = 'SilentlyContinue'
Remove-Item $path -Recurse -Force

# ✅ 正确：捕获并报告
try {
    Remove-Item $path -Recurse -Force -ErrorAction Stop
} catch {
    return @{
        Status  = 'Failed'
        Message = "无法删除 $path：$($_.Exception.Message)"
        Hint    = "可能原因：文件被占用（尝试关闭相关程序后重试）"
        Recoverable = $true
    }
}
```

**失败必须包含三要素**：
1. **发生了什么**（客观描述）
2. **可能的原因**（给用户排查方向）
3. **怎么补救**（具体操作或指出还原脚本）

---

## 9. GUI 壳需求（Phase 2）

### 9.1 架构约束

- GUI **必须是引擎的纯前端**，不得包含任何优化逻辑
- GUI 与 CLI 共享同一套 `plugin.json` 与引擎接口
- GUI 通过调用引擎的 PowerShell API 或 `pwsh -File` 子进程 工作

### 9.2 技术选型（待定，建议）

| 方案 | 优势 | 劣势 |
|---|---|---|
| **WPF (PowerShell + XAML)** | 纯 PS 生态，无需额外运行时 | 界面较老，XAML 手写繁琐 |
| **Tauri** | 现代 UI，体积小 | 需 Rust 工具链，体积仍 >20 MB |
| **HTML 报告 + 本地服务** | 复用浏览器渲染，开发快 | 需起本地服务，用户可能疑惑 |

**建议 Phase 2 从"生成 HTML 报告"开始**，风险最低、收益明显，再考虑完整 GUI。

### 9.3 GUI 必须具备

- 与 CLI 完全一致的风险分级与默认勾选逻辑
- 每项的三段式说明可展开
- 执行进度实时可见
- 一键还原入口醒目

---

## 10. 技术架构

### 10.1 目标环境

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 11 21H2 (build 22000) 及以上 |
| PowerShell | 5.1（内置）必须支持；7.x 兼容更好 |
| 权限 | 建议管理员（部分功能需要），非管理员也能运行只读诊断 |
| 磁盘占用 | 工具本体 < 1 MB；运行时快照 < 10 MB |
| 网络 | **完全离线可用**（除文献链接外，不发起任何网络请求） |

### 10.2 编码规范

| 规则 | 说明 |
|---|---|
| **PS1 文件必须 UTF-8 with BOM** | 否则中文系统上 PS 5.1 按 GBK 解析会语法错误（铁律 L4） |
| JSON 文件使用 UTF-8 (无 BOM) | `ConvertFrom-Json` 兼容性 |
| 日志文件使用 UTF-8 | 便于跨工具查看 |
| 源码缩进 4 空格 | 统一风格 |
| 函数使用 `Verb-Noun` 命名 | PowerShell 规范 |
| 所有公开函数加 `.SYNOPSIS` 注释 | 便于 `Get-Help` |

### 10.3 日志规范

```
Logs/
├─ optimizer-YYYYMMDD-HHmmss.log     # 主日志（每个动作一行）
├─ errors-YYYYMMDD-HHmmss.log        # 仅错误，便于用户反馈
└─ engine-trace-YYYYMMDD-HHmmss.log  # 引擎内部追踪（-Verbose 时启用）
```

**日志格式**：
```
2026-10-04 14:30:22.123 | INFO  | Engine      | 开始扫描，共 15 个插件
2026-10-04 14:30:22.456 | INFO  | PluginLoader| 已加载 plugins/010-disk-shadercache
2026-10-04 14:30:25.789 | INFO  | Scan        | disk.shadercache | 发现 6.75 GB
2026-10-04 14:32:10.012 | INFO  | Apply       | service.vendor-bloat | SUCCESS
2026-10-04 14:32:11.345 | ERROR | Apply       | service.xxx | 失败: Access denied
2026-10-04 14:32:11.346 | ERROR | Apply       | service.xxx | 原因: 服务被系统占用
2026-10-04 14:32:11.347 | ERROR | Apply       | service.xxx | 建议: 重启后重试
```

### 10.4 状态码约定

| 状态 | 含义 | 用户可见文案 |
|---|---|---|
| `Success` | 完全成功 | ✅ 已完成 |
| `Partial` | 部分成功（如多目标只删了部分） | ⚠️ 部分完成（详见日志） |
| `Skipped` | 预检未通过而跳过 | ⏭️ 已跳过（原因：…） |
| `Failed` | 失败 | ❌ 失败（原因：… 建议：…） |
| `RolledBack` | 已还原 | ↩️ 已还原 |

---

## 11. 非功能需求

### 11.1 性能

| 指标 | 目标 |
|---|---|
| 启动到显示环境信息 | < 3 秒 |
| 全量扫描 | < 2 分钟（90% 场景） |
| 单个优化项执行 | < 30 秒（不含需要重启的项） |
| 内存占用 | 峰值 < 200 MB |

### 11.2 可靠性

| 场景 | 要求 |
|---|---|
| 执行中途用户关闭窗口 | 已完成的改动保留，快照与 manifest 已落盘，可还原 |
| 执行中途断电 | 同上；重启后提供"检测到未完成的优化，是否还原？" |
| 单个插件崩溃 | 引擎捕获，标记该插件 Failed，**继续执行其他插件** |
| 磁盘空间在执行中耗尽 | 引擎预估收益与开销，空间不足时提前警告 |

### 11.3 安全

| 要求 | 说明 |
|---|---|
| 不联网 | 除文档链接外无任何网络请求；不收集遥测 |
| 不修改自身 | 工具不自我更新（用户手动下载新版） |
| 提权最小化 | 只在确实需要时请求管理员 |
| 不触碰凭据 | 绝不读取/修改密码、令牌、证书 |

### 11.4 兼容性测试矩阵

| 维度 | 覆盖 |
|---|---|
| Windows 版本 | 21H2 / 22H2 / 23H2 / 24H2 / 25H2 |
| 硬件类型 | 笔记本（有电池）/ 台式机 / 虚拟机 / Surface 类二合一 |
| 磁盘类型 | 单盘 / 多盘 / NVMe / SATA SSD / HDD |
| 启动模式 | UEFI / Legacy（主要 UEFI） |
| 分区表 | GPT / MBR |
| 权限 | 管理员 / 标准用户 |
| 厂商 | Dell / Lenovo / HP / ASUS / 组装机 / 微软 Surface |
| 语言 | 简体中文 / 英文（重点测试中文路径） |
| 特殊环境 | BitLocker 启用 / 系统还原禁用 / 企业策略限制 |

---

## 12. 架构级硬性约束（铁律）

> **本章来自真实项目的踩坑记录。每条都对应一次实际故障。**
> 这些不是"建议"，是**代码审查必须拒绝的红线**。

### L1 —— 白名单，永不用排除法

**来源**：实战中差点误删用户数据。

```powershell
# ❌ 禁止：排除法，未预料到的东西会被删
Get-ChildItem 'D:\' -Recurse | Where-Object { $_.FullName -notmatch 'important' } | Remove-Item

# ✅ 必须：白名单，只操作明确列出的路径
$allowed = @("$env:LOCALAPPDATA\NVIDIA\DXCache")
```

**强制机制**：引擎在运行时校验每个操作的目标路径，不在白名单则拒绝执行。

### L2 —— 禁止静默失败

**来源**：实战中 `Remove-Item` 在函数内被 `$ErrorActionPreference='SilentlyContinue'` 吞掉，导致"报告删除成功但实际什么都没删"，我误判了整整一轮。

**规则**：
- 插件代码中 **禁止** 使用 `-ErrorAction SilentlyContinue`（除少数明确无害的探测）
- 引擎提供的 `Invoke-SafeAction` 包装器统一处理错误
- 所有 `catch` 块必须记录日志并返回 `Failed` 状态
- **绝不允许** `catch { }` 空块

```powershell
# ❌ 禁止
$ErrorActionPreference = 'SilentlyContinue'
Remove-Item $path -Recurse -Force

# ✅ 必须
try { Remove-Item $path -Recurse -Force -ErrorAction Stop }
catch { return @{ Status='Failed'; Message=$_.Exception.Message } }
```

### L3 —— 所有外部进程调用必须带超时

**来源**：实战中 `Stop-Service` 对一个 "Stop Pending" 服务无限重试，刷了几百行警告，脚本卡死 10 分钟。

**规则**：
```powershell
# ❌ 禁止：可能永久阻塞
Start-Process $exe -Wait

# ✅ 必须：硬超时 + 强制终止
$p = Start-Process $exe -PassThru
if (-not $p.WaitForExit(60000)) {
    taskkill /F /PID $p.Id /T
    return Failed
}
```

**禁止的操作模式**：
- `Stop-Service` 不判断服务状态就直接调用（对 Stop Pending 会无限重试）
- 正确做法：用 `sc.exe query` 检查状态，用 `sc.exe delete` 标记删除而非停服务

### L4 —— PS1 文件必须 UTF-8 with BOM

**来源**：实战中一个 339 行的脚本报了 18 个语法错误，根因是 UTF-8 无 BOM，中文系统上 PS 5.1 按 GBK 解析导致乱码。

**规则**：
- 所有 `.ps1` 文件必须 UTF-8 **with BOM**
- CI 中加检查：读取前 3 字节必须为 `EF BB BF`
- 生成文件时使用：`New-Object System.Text.UTF8Encoding($true)`

```powershell
# ✅ 写入带 BOM 的文件
[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($true)))
```

### L5 —— 启动器使用纯 ASCII 文件名

**来源**：实战中 `一键优化.cmd` 双击后一闪而过。根因是中文文件名在 cmd → PowerShell 传参时编码损坏，`Start-Process -FilePath '%~f0'` 拿到非法路径后静默失败。

**规则**：
- 提权启动器文件名必须纯 ASCII（如 `Start-Optimizer.cmd`）
- 内部调用的脚本路径也建议 ASCII
- 中文只出现在**脚本内部的输出文字**，不出现在**路径**中

### L6 —— 区分"日志提示需重启"与"系统标记需重启"

**来源**：实战中 `setupapi.dev.log` 显示 "Restart required"，但 WU API 报 `RebootRequired=False`。两者不矛盾，但需分别判断。

**规则**：
- 判断是否需要重启要**多源交叉验证**：WU API + CBS RebootPending + PendingFileRenameOperations + setupapi 日志
- 不能只信一个来源

### L7 —— 高风险操作必须有"人在场"设计

**来源**：BIOS 固件更新。

**规则**：
- 固件/BIOS 类操作**永不由工具自动执行**，只输出建议 + 官方更新方式
- 若未来支持，必须：接电源检查 + 电量检查 + 明确告知"电脑将重启数次，不可中断" + 用户输入确认文字

### L8 —— 监控不能依赖"看起来在跑"

**来源**：实战前期让一个卡死的循环跑了 10 分钟才被发现。

**规则**：
- 长任务必须有**活动信号**：日志文件增长量、CPU 增量、磁盘 I/O
- 连续 N 分钟无活动 → 主动标记"疑似卡死"并询问用户
- 不允许用"进程还在"作为"正在工作"的唯一判据

### L9 —— 不要盲目相信 API 返回的元数据

**来源**：实战中 WU API 把累积更新报成 `92399.7 MB`（92 GB），实际只有 109 MB。

**规则**：
- 展示给用户的数字要**经过合理性校验**
- 明显不合理的值（如 92 GB 的更新包）要在 UI 上标注"数据可能不准确"或改用其他来源
- 磁盘空间类数字以实际测量为准，不用 API 预估

### L10 —— 卸载残留要用"注册表+目录+服务"三重探测

**来源**：实战中发现大量软件卸载后目录仍在（FeverGames 1.37 GB、Oopz 746 MB）。

**规则**：
- 检测残留要同时查：卸载注册表项、安装目录、残留服务、启动项
- 残留识别要有明确信号，不能凭目录名猜测

---

## 13. 测试策略

### 13.1 测试层级

| 层级 | 范围 | 工具 |
|---|---|---|
| **单元测试** | 每个插件的扫描逻辑、路径校验、快照/还原 | Pester |
| **契约测试** | 所有插件符合 §5.3 接口；plugin.json 符合 schema | Pester + JSON Schema |
| **集成测试** | 引擎 + 插件全流程（在容器/VM 中） | Pester + Windows Sandbox |
| **快照矩阵** | 用固定机型的诊断数据样本验证输出稳定性 | fixtures |
| **安全测试** | 尝试越权路径、危险命令，验证被拦截 | 专门的 negative test |
| **UI 测试** | 控制台渲染、勾选逻辑、依赖解析 | 手工 + 快照比对 |

### 13.2 关键测试用例（必须覆盖）

```
✅ 安全类
  T-SEC-01  插件试图删除 C:\Users\...\Desktop 下的文件 → 必须被拦截
  T-SEC-02  插件试图执行 Format-Volume → 必须被拦截
  T-SEC-03  插件目标路径不在白名单 → 必须拒绝执行
  T-SEC-04  非管理员运行时，需要管理员的功能 → 说明后跳过，不静默
  T-SEC-05  单次删除超过 100 MB → 必须要求显式确认

✅ 可靠性类
  T-REL-01  外部进程 60 秒不退出 → 必须强制终止并返回 Failed
  T-REL-02  单个插件抛异常 → 引擎捕获，其他插件继续
  T-REL-03  执行中途用户 Ctrl+C → 快照与 manifest 完整，可还原
  T-REL-04  Stop Pending 状态的服务 → 不能进入无限重试

✅ 编码类
  T-ENC-01  所有 ps1 文件带 UTF-8 BOM
  T-ENC-02  中文路径下的脚本正常运行
  T-ENC-03  中文文件名启动器闪退问题（应使用 ASCII 名）

✅ 还原类
  T-RB-01   每一项执行后，Restore-All.ps1 都能还原
  T-RB-02   还原脚本 -WhatIf 模式不产生副作用
  T-RB-03   还原脚本对未执行的项不报错
  T-RB-04   还原后再执行，结果与首次一致（幂等）

✅ 正确性类
  T-COR-01  风险等级与默认勾选状态一致
  T-COR-02  冲突项不能同时勾选
  T-COR-03  依赖项缺失时有明确提示
  T-COR-04  展示的预估收益与实际相符（误差 < 30%）
```

### 13.3 手工验收场景

| 场景 | 环境 | 验收标准 |
|---|---|---|
| 全新安装的 Win11 | VM | 扫描正常，无误报为"问题"的正常项 |
| 长期使用的机器 | 真实机 | 能发现真实问题，收益与预估相符 |
| 中文用户名 | VM | 路径处理正确，不闪退 |
| 无管理员权限 | VM | 只读诊断可用，需提权的项明确说明 |
| BitLocker 启用 | VM | 明确提示风险，不执行危险操作 |
| 系统还原被禁用 | VM | 快照机制仍工作（不依赖还原点） |

---

## 14. 交付物

### 14.1 代码交付

| 交付物 | 说明 |
|---|---|
| `Win11Optimizer.ps1` | 主入口 |
| `Start-Optimizer.cmd` | ASCII 名自提权启动器 |
| `engine/` | 引擎层完整实现 |
| `plugins/` | ≥ 15 个优化插件（覆盖 §4.1 全部模块） |
| `lib/` | 工具库 |
| `tests/` | Pester 测试套件，覆盖率 ≥ 70% |
| `.github/workflows/` | CI：schema 校验 + 单元测试 + BOM 检查 + 静态安全扫描 |

### 14.2 文档交付

| 文档 | 内容 |
|---|---|
| `README.md` | 项目介绍、安全承诺、快速开始、截图 |
| `docs/plugin-development.md` | 插件开发完整指南（含模板） |
| `docs/safety-model.md` | 安全模型详解（为什么这样设计） |
| `docs/risk-classification.md` | 风险分级标准 |
| `docs/contributing.md` | 贡献指南、代码规范、PR 检查清单 |
| `CHANGELOG.md` | 版本历史 |
| `LICENSE` | 建议 MIT 或 Apache-2.0 |
| `SECURITY.md` | 安全政策、漏洞报告流程 |

### 14.3 社区资产

| 资产 | 说明 |
|---|---|
| Issue 模板 | Bug 报告（含日志采集指引）、插件请求、安全报告 |
| PR 模板 | 强制自检清单（含 §12 铁律核对） |
| 插件模板仓库 | `plugins/_template/` 可直接复制 |

---

## 15. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| **M1 引擎骨架** | 引擎 + 契约 + 日志 + Preflight + 快照 | 空插件能跑通全流程 |
| **M2 首批插件** | disk(3) + service(2) + startup(2) | 能在真机上发现并处理真实问题 |
| **M3 安全加固** | 白名单校验 + 危险命令拦截 + 还原脚本 | 通过 §13.2 全部安全类测试 |
| **M4 体验打磨** | 控制台 UI + 三段式文案 + 报告渲染 | 普通用户能独立看懂并使用 |
| **M5 插件补全** | 补齐 §4.1 全部 15 个模块 | 覆盖率达标，CI 全绿 |
| **M6 文档与发布** | 全部文档 + CI + 模板 + v1.0 发布 | GitHub Release |
| **M7 GUI（可选）** | HTML 报告 → WPF/Tauri GUI | 与 CLI 行为一致 |

---

## 16. 待讨论问题（Open Questions）

| # | 问题 | 影响 | 建议 |
|---|---|---|---|
| 1 | 是否支持 Windows 10？ | 工作量 +40%，兼容性分支多 | 建议 v1.0 仅 Win11，v2.0 再评估 |
| 2 | 还原脚本是否要能跨重启？ | 部分改动需重启才生效 | 建议支持，manifest 落盘即可 |
| 3 | 多语言（英文）支持？ | 影响文案架构 | 建议 v1.0 中文，架构预留 i18n |
| 4 | 是否接入 Windows Sandbox 做自动测试？ | CI 复杂度 | 建议 M3 后评估 |
| 5 | 插件是否允许引用外部下载的工具？ | 违背"离线可用"铁律 | **建议禁止**，只用系统自带工具 |
| 6 | 是否需要"优化方案导出/导入"（团队批量）？ | 增加企业向价值 | 建议 v1.1 |
| 7 | 快照保留策略？（无限增长） | 磁盘占用 | 建议保留最近 10 次，可配置 |
| 8 | 是否提供 unattended 模式（-Auto）？ | 便捷 vs 安全 | 建议提供但强制要求显式 `-Auto -Risk 0` |

---

## 17. 附录

### 17.1 本项目实战验证过的参考清单

以下是真实环境下有效、安全、可复现的优化项，可作为首批插件的直接依据：

| 类别 | 优化项 | 风险 | 典型收益 |
|---|---|---|---|
| 磁盘 | 清理 `NVIDIA\DXCache` / `GLCache` | 0 | 2–7 GB |
| 磁盘 | 清理 Windows 更新缓存 | 0 | 0.2–1 GB |
| 磁盘 | DISM 组件清理 | 3 | 1–5 GB |
| 磁盘 | 清理 `%TEMP%` | 0 | 0.1–3 GB |
| 磁盘 | 清理 pip/npm 缓存 | 0 | 0.1–1 GB |
| 服务 | 厂商遥测服务改手动（DDV/Dell Data Vault 等） | 2 | 50–300 MB 内存 |
| 服务 | `DellClientManagementService` 内存泄漏处理 | 2 | 最高 1.8 GB 内存 |
| 服务 | 安全软件冲突检测与提示 | 2 | 磁盘 I/O 大幅下降 |
| 启动 | 关闭非必要开机自启 | 1 | 100–500 MB 内存 |
| 启动 | 清理孤儿启动项（已卸载软件） | 1 | 少量 |
| 计划任务 | 禁用遥测任务 | 2 | 少量 |
| 计划任务 | 删除广告推广任务（SoftLanding 类） | 2 | 隐私 |
| 电源 | 恢复原生电源方案 | 1 | 解除 CPU 限频 |
| 电源 | 禁用 Sustainable/可持续性劫持 | 1 | 防止方案被改回 |
| 隐私 | 遥测相关只诊断不修改 | 0 | — |
| 网络 | hosts 劫持检测（**只诊断**） | 0 | — |
| 网络 | Winsock LSP 残留检测（**只诊断**） | 0 | — |
| 设备 | 幽灵/错误设备识别与清理建议 | 1 | 消除设备管理器报错 |
| 更新 | 待装更新提示 | 0 | — |

### 17.2 参考文献

- [Windows 11 25H2 已知问题（微软官方）](https://learn.microsoft.com/en-us/windows/release-health/status-windows-11-25h2)
- [Dell ServiceShell 内存泄漏报告（戴尔社区）](https://www.dell.com/community/en/conversations/xps/xps-16-9640-serviceshellexe-is-consuming-several-gigabytes-of-ram-causing-heavy-paging-and-severe-performance-issues/69f9a1852b77a37128962806)
- [Microsoft Update 指南](https://learn.microsoft.com/en-us/windows/deployment/update/)
- [PowerShell 最佳实践](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/cmdlet-development-guidelines)
- [Pester 测试框架](https://pester.dev/)

### 17.3 术语表

| 术语 | 含义 |
|---|---|
| **Finding** | 诊断发现的一个问题 |
| **Plugin** | 一个独立、可插拔的优化项模块 |
| **Snapshot** | 改动前的状态快照 |
| **Manifest** | 一次运行的变更总账 |
| **Preflight** | 执行前的预检 |
| **Risk Level** | 风险等级 0–4 |
| **Iron Law** | 架构级铁律，不可违反 |

---

*文档结束。本文档以安全为第一优先级，任何与之冲突的功能需求都应被拒绝或重新设计。*
