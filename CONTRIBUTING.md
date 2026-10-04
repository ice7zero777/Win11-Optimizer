# 贡献指南

感谢你愿意看这个项目。这是一个人利用课余时间写的 Windows 11 优化工具，规模不大，
所以流程尽量保持简单：**读一下铁律 → 本地跑一次门禁 → 提 PR 并勾完自检清单**。

如果你只想提一个想法或报个问题，不用读完整篇，直接开 Issue 就好（见文末）。

---

## 1. 先了解这个项目在坚持什么

这个工具的全部价值建立在"安全第一"上：它可能会去改你电脑的服务、计划任务、电源方案，
所以宁可功能少，也不能出事。动手之前请至少翻一下这几处：

> 需求文档已经入库：它在本仓库里的位置是 [`docs/PRD.md`](docs/PRD.md)，也是**本仓库唯一的规格来源**。

| 材料 | 位置 | 为什么重要 |
|---|---|---|
| 需求文档 §1.4「非目标」 | [`docs/PRD.md`](docs/PRD.md) | 里面列的事**永久不做**，提这类 PR 会被直接关闭 |
| 需求文档 §2「核心设计原则 P1–P5」 | 同上 | 冲突时以这一节为准 |
| 需求文档 §12「铁律 L1–L10」 | 同上 | 代码审查红线，CI 只覆盖了其中的 L1–L5 |
| 会话对接文档 | 工作区根目录的 `会话对接文档.md`（**该文件不在仓库内**，仅开发工作区可见） | 每条铁律背后的真实事故，读了才知道为什么这么规定 |

---

## 2. 当前项目状态（别被文档误导）

说清楚现状比画大饼有用：

**已经落地并验证过的**

- `analyzer/IronLaw/IronLaw.Checker.psm1` —— 铁律静态检查器（AST 分析）
- `analyzer/tests/IronLaw.Tests.ps1` —— 21 个 Pester 测试，全绿
- `analyzer/tests/fixtures/` —— 违规/合规双向夹具
- `ci/Invoke-Analysis.ps1` —— 3 阶段本地门禁
- `analyzer/experimental/` —— PSScriptAnalyzer 路线失败的记录
- `docs/` —— `PRD.md`（规格来源）、`plugin-development.md`、`safety-model.md`、`risk-classification.md`

**还没写的（欢迎认领，但请先开 Issue 对齐设计）**

- `engine/` 引擎层（调度、插件加载、选择、执行、快照、日志）
- `plugins/` 插件层（PRD §4.1 的 15 个模块）
- `Win11Optimizer.ps1` 主入口与 `Start-Optimizer.cmd` 启动器
- GUI 壳（Phase 2，HTML 报告 → WPF/Tauri）

**换句话说：现在这个仓库还不是一个能优化电脑的工具，只是一个能检查代码有没有违反铁律的分析器。**
写 PR 描述时请如实描述你实际改了什么，不要把"规划"写成"已完成"。

---

## 3. 环境准备

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 11（21H2 及以上）。项目只支持 Win11，不接受 Win10 兼容性 PR |
| PowerShell | 5.1（系统自带，必须能跑）；7.x 也要能跑 |
| Pester | 5.x（门禁脚本使用 `New-PesterConfiguration`，4.x 跑不起来） |

安装 / 更新 Pester（当前用户即可，不必管理员）：

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

> 如果 `Install-PSResource` / `Install-Module` 拉不动，先确认网络，或改用公司/学校的内部源；
> 这个项目本身完全离线可用，只有装开发依赖时才需要联网。

---

## 4. 本地怎么跑检查

### 4.1 一把梭：跑完整门禁

在仓库根目录（也就是包含 `analyzer\` 和 `ci\` 的那一层）执行：

```powershell
.\ci\Invoke-Analysis.ps1
```

它会依次做三件事，任何一步失败整体就失败：

1. 对仓库内文件执行 `Unblock-File`（避免下载来的文件带 `Zone.Identifier` 导致模块加载失败）；
2. 用铁律检查器扫描源码 + 校验每个 `.ps1` 自身的 BOM，并打印实际检查的文件数（检查数为 0 视为失败）；
3. 跑 Pester 测试。

**提 PR 之前请确保这条命令是绿的**，并在 PR 描述里写一句"本地门禁已通过"。

### 4.2 只检查某几个文件

先把检查器模块装到一个**浅路径**下（深路径会加载失败，这是踩过的坑）：

```powershell
$dest = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\IronLaw.Checker'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item .\analyzer\IronLaw\IronLaw.Checker.psm1 $dest

Import-Module IronLaw.Checker
```

然后对单个文件或整棵目录做检查：

```powershell
Invoke-IronLawCheck -Path .\plugins\010-disk-shadercache\plugin.ps1
Invoke-IronLawCheck -Path .\plugins -Exclude '*\reference\*'
```

每条违规是一条记录，含 `Law` / `Rule` / `Severity` / `Message` / `File` / `Line` / `Column`，按行号定位即可。
数条数时直接取 `.Count` 即可（检查器用 `Write-Output -NoEnumerate` 返回数组，空结果也是数组）；
不要写成 `@(Invoke-IronLawCheck -Path $p).Count`——那会把数组再包一层，数出 1。

### 4.3 修不动但确实合理的例外

如果某个文件**故意**包含不合规写法（典型场景：夹具、参考实现、检查器自身的模式字符串），
在文件里加一行文件级豁免指令，不要为了它给整个目录开豁免：

```powershell
# IronLaw-Suppress: AvoidSilentlyContinueErrorAction
```

`ci\Invoke-Analysis.ps1` 已经对 `analyzer\IronLaw\*` 和 `analyzer\rules\*` 做了自查排除，
这是 linter 的常规自排除，别把它当成先例随意扩大。

---

## 5. 编码规范

| 规则 | 说明 |
|---|---|
| **所有 `.ps1` / `.psm1` / `.psd1` 必须 UTF-8 with BOM** | 中文系统上 PowerShell 5.1 会把无 BOM 的 UTF-8 当 GBK 解析，直接报一堆语法错误（铁律 L4）。**CI 会检查前 3 字节是否为 `EF BB BF`，不通过就红。** |
| 写文件时显式指定编码 | `[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($true)))` |
| Markdown 用 UTF-8（**不要** BOM） | 本文件、README、CHANGELOG 等都是无 BOM UTF-8 |
| JSON 用 UTF-8（无 BOM） | `ConvertFrom-Json` 的兼容性要求（PRD §10.2） |
| 源码缩进 4 空格 | 不要用 Tab |
| 函数名用 `Verb-Noun` | PowerShell 规范，例如 `Invoke-IronLawCheck` |
| 公开函数写 `.SYNOPSIS` 注释 | 方便 `Get-Help` |
| 注释和界面文案用简体中文 | 目标用户以中文普通用户为主 |

另外几条从真实事故里来的硬性要求，写代码时请主动遵守：

- **不要静默失败**（L2）：代码里禁止 `-ErrorAction SilentlyContinue`（除了明确无害的探测）、禁止空的 `catch { }`；错误要记录并返回 `Failed`。
- **外部进程必须带超时**（L3）：不要 `Start-Process -Wait` 裸用，也不要在不判断状态下直接 `Stop-Service`（对 "Stop Pending" 的服务会无限重试）。
- **路径必须白名单**（L1）：永远不要写"排除掉重要的，剩下都删"这种反模式。
- **不要编造数据**：文档和注释里不要写没验证过的数字；不知道就写"未验证"。

---

## 6. 提交 PR

1. Fork 后从 `main` 切一个分支，分支名说明意图即可（例如 `fix/l2-catch-block`、`docs/plugin-guide`）。
2. **一次 PR 只做一件事**，不要把无关的格式化、重命名、新功能混在一起。
3. 改动涉及 `.ps1` 就同步补测试：新增检查规则要有"违规夹具必须检出"和"合规夹具必须零误报"两个方向的用例。只测一个方向的规则等于没测。
4. 本地跑 `.\ci\Invoke-Analysis.ps1`，绿了再提。
5. 提交信息写清楚"改了什么、为什么"。
6. 按 `.github/pull_request_template.md` 填描述，并**逐条勾完自检清单**。清单不是形式主义：勾不上就先别提。

### PR 自检清单（对应 PRD §12 的 L1–L10）

复制到你的 PR 描述里，逐条确认：

- [ ] **L1 白名单，永不用排除法**：没有出现"排除掉重要的、剩下都删"的写法；所有删除/改动目标都在明确列出的白名单里。
- [ ] **L2 禁止静默失败**：没有 `-ErrorAction SilentlyContinue` 滥用，没有空 `catch { }`；`catch` 里都记录日志并返回 `Failed`。
- [ ] **L3 外部进程带超时**：所有 `Start-Process` / 外部命令都有硬超时与强制终止路径；没有裸 `Stop-Service`。
- [ ] **L4 `.ps1` 为 UTF-8 with BOM**：新增/修改的脚本前 3 字节是 `EF BB BF`，门禁的 BOM 阶段通过。
- [ ] **L5 启动器纯 ASCII 文件名**：新增的启动器/入口文件没有中文文件名；中文只出现在脚本内部输出里。
- [ ] **L6 重启判断多源交叉验证**：涉及"是否需要重启"的逻辑不只依赖单一来源（WU API / CBS / PendingFileRenameOperations / setupapi 日志）。
- [ ] **L7 高风险操作有人在场**：固件/BIOS 类操作永不自动执行，只输出建议与官方方式；需要用户显式确认的地方有确认输入。
- [ ] **L8 监控有真实活动信号**：长任务的进度判断基于日志增长 / CPU 增量 / 磁盘 I/O 等信号，不是"进程还在"。
- [ ] **L9 不盲信 API 元数据**：展示给用户的数字经过合理性校验，明显不合理的值有标注或改用实测。
- [ ] **L10 卸载残留三重探测**：残留检测同时查注册表项、安装目录、残留服务/启动项，不靠目录名猜。
- [ ] **不动用户数据（§2 P1）**：改动不删除、移动、重命名任何用户数据文件；本 PR 不触碰用户数据路径。
- [ ] **测试已跑**：`.\ci\Invoke-Analysis.ps1` 本地通过（贴一句结果即可）。
- [ ] **描述诚实**：没有把未实现的功能写成已完成，没有编造实测数据。

> CI 目前只能自动拦住 L1–L5 的一部分（静态可判定的那些）。L6–L10 以及"是否动了用户数据"靠上面的人工勾选——
> 请真的核对，`git diff` 里有没有 `Remove-Item`、有没有落到 `Desktop` / `Documents` / `Downloads` 的路径，几秒钟就能看出来。

---

## 7. 提 Issue

- **碰到问题 / 有优化项想法**：用仓库的 Issue 模板（Bug 报告、插件请求）。
- **安全类问题**（越权删除、绕过白名单、误删风险等）：请优先走私有渠道，见 [SECURITY.md](SECURITY.md)，
  **不要在公开 Issue 里贴完整的漏洞利用细节**。
- 提 Bug 时请附上：系统版本、PowerShell 版本、是否管理员、复现步骤，以及相关日志。
  **贴日志前请把用户名等个人隐私路径替换成占位符**（例如 `C:\Users\<用户名>\...`）。

## 8. 语气与协作

- 对事不对人，review 意见尽量给出理由和依据。
- 这个项目很小，回复可能不快，但每个有价值的 Issue / PR 都会得到回应。
- 不需要客套，也不需要写"企业级"的繁复文档；把话说清楚最重要。
