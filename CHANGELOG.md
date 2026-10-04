# 更新日志

本文件记录 Win11-Optimizer 的所有重要变更。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号规划遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> **当前状态说明（请先读这段）**
> 最新发布版本是 **v1.0.0**（见下方「1.0.0」区块），可从
> [Releases](https://github.com/ice7zero777/Win11-Optimizer/releases) 下载 ZIP 使用。
> v0.1.0 是只读诊断版；v1.0.0 在此之上补齐了「零风险缓存清理 + 一键还原」。
> 需要改服务、改注册表、需要重启的那类"深度优化"**仍未实现**，也不在 v1.0 范围内。

---

## [未发布]

### 规划中

- 服务启动项改手动、开机启动项管理、DISM 组件清理等需要改系统行为或重启的功能。
- 诊断模块补齐到 PRD §4.1 的 15 类。

## [1.1.0] - 2026-10-04

### 新增

- **图形界面（WPF，零第三方依赖）**：双击即用真正的窗口，不再需要看命令行。
  - `Win11Optimizer.Gui.ps1`：GUI 入口——建窗口、绑按钮、渲染结果。
  - `lib/Gui.Window.ps1`：主窗口 XAML（18 个控件、2 个 DataGrid：诊断结果 4 列 / 可清理缓存 5 列）。
  - `lib/Gui.Core.ps1`：编排层——后台 runspace 执行扫描与清理，主线程用 `DispatcherFrame` 泵消息，窗口全程不假死；扫描过程文字经线程安全队列实时回传界面。
  - `Start-Gui.cmd`：直接打开图形界面的启动器。
  - 界面流程：本机信息 → 开始扫描 → 结果表格 → 勾选缓存 → 确认清理 → 一键还原。
- **`Start-Optimizer.cmd` 改为选择菜单**：1 图形界面 / 2 只读诊断 / 3 清理缓存 / 4 一键还原。
- **输出改道机制**：`lib/Common.ps1` 新增 `Set-OutputSink`。注册接收器时扫描输出送到界面；不注册时行为与原来完全一致（CLI 不受影响）。
- **确认弹窗接缝** `Ask-GuiConfirmation`：把"是/否"确认抽成独立函数，便于自动化测试覆盖"勾选 → 确认 → 执行"链路。正式运行时仍是真实弹窗，**确认这道闸不会被跳过**。
- **截图** `docs/screenshots/`：真实运行时的界面截图。

### 修复

- **报告目录被重复拼接**：GUI 里 `Get-GuiQuarantineSummary` / `Restore-GuiQuarantine` 把 `Join-Path $Root 'Reports'` 当基目录，指定 `-OutputDirectory` 时会去找不存在的 `仓库\Reports\Snapshot`，导致"隔离区：无"、还原按钮形同虚设。改为显式传 `-BaseDirectory`，并让 `Start-GuiScan` / `Start-GuiCleanup` 一并接收。
- **隔离区摘要统计错误**：原来只数台账条目，已还原的记录也被算进去，界面会一直显示"还有 N 个文件可还原"。改为逐个确认文件**此刻仍在隔离区**才计数；还原后正确显示"隔离区：无"。
- **点源入口脚本会永久阻塞**：`ShowDialog()` 是阻塞调用，点源一个末尾调用它的脚本会卡死，自动化测试根本没机会执行。新增 `-TestMode`，点源时只定义函数与绑定事件。
- **`Sort-Object` 表达式用错变量**：写了外层 for 循环的 `$finding` 而不是管道变量 `$_`，界面整理结果时直接报错。
- **跨 runspace 对象被 PSObject 包住**：`$_['Severity']` 抛 "Unable to index into an object of type PSObject"。新增 `Get-GuiField` 兼容 Hashtable 与 PSObject 两种形态。
- **PowerShell 5.1 不支持泛型类型字面量**：`New-Object 'ConcurrentQueue[string]'` 静默返回 `$null`，导致后台输出队列建不起来。改用 `System.Collections.Queue` 的 `Synchronized` 包装。
- **空 Queue 被枚举成 `$null`**：函数返回空集合时 PowerShell 的自动枚举会把它展开没，队列返回 `$null`。用 `return ,` 阻止枚举（与 `Get-CleanupItem` 同源的坑）。
- **`DispatcherFrame` 依赖未加载**：`Gui.Core.ps1` 单独使用时 `WindowsBase` 未加载，显式 `Add-Type`。

### 验证

- 门禁：16 个文件 0 铁律违规、20 个文件 UTF-8 BOM 全过、36 个 Pester 用例全过。
- 真实机器上：窗口成功创建并显示（截图存档）；**点击"开始扫描"按钮**得到 5 行诊断 + 4 项可清理缓存，界面显示"扫描完成：发现 3 项需要关注，4 类可清理缓存"；**点击"一键还原"按钮**把 4 个文件（10 MB）全部放回原位、隔离区清空；复选框列 `IsReadOnly=False`（用户可勾选）。

### 已知限制

- 真实鼠标点击复选框、以及确认弹窗的人工点击，未做自动化验证（`MessageBox` 是模态的，会阻塞消息泵，无人值守下既关不掉也点不了）——需要人工在桌面上确认一次。
- GUI 以普通权限启动时，"服务详情 / 安全软件 / 系统还原"等项会如实标注"读不到"。

## [1.0.0] - 2026-10-04

### 新增

- **零风险缓存清理**（必须显式 `-Clean` 开启）：
  - `lib/Cleanup.Targets.ps1`：清理白名单（用户临时目录、显卡着色器缓存、Windows 更新缓存、pip/npm 缓存、缩略图缓存），含白名单校验与受保护路径拦截。
  - `lib/Cleanup.Snapshot.ps1`：隔离机制——把待清理文件**移动**到 `Snapshot/<时间戳>/quarantine`，并生成可一键还原的 `Restore-All.ps1`。
  - `lib/Cleanup.Engine.ps1`：体积测量、按白名单枚举、逐个隔离、体积预算（默认 2 GB）、过期隔离区清理。
  - `lib/Cleanup.Ui.ps1`：控制台交互——编号勾选（支持 `1,3`、`1-3`、`all`、回车取默认、`d 编号` 看详情、`q` 放弃）、`yes` 二次确认、非交互环境自动跳过。
  - 主入口新增 `-Clean` / `-Restore` / `-SelectTargets` / `-AssumeYes` / `-QuarantineBudgetMB`。
  - 安全约束：`-AssumeYes` 必须与 `-SelectTargets` 同时使用，不提供任何一键无人值守清理。
- **一键还原**：`-Restore` 把隔离区文件移回原位；原位置已有同名文件时跳过不覆盖；重复执行会识别为"此前已还原"。
- **回归测试** `analyzer/tests/Cleanup.Safety.Tests.ps1`：15 个用例覆盖白名单放行/拒绝、路径穿越、数组契约、隔离与还原闭环、体积预算、还原脚本 BOM 与语法。

### 修复

- **8.3 短路径导致的校验失效**：`[System.IO.Path]::GetTempPath()` 返回短名（如 `C:\Users\ALIENW~1\...`），与白名单里的长名做字符串比较会失败。新增 `Get-NormalizedPath`，用 Win32 `GetLongPathName` 还原长名后再比较。
- **数组嵌套（`.Count` 读成 1）**：`Get-CleanupItem` 曾用 `return , $array` 叠加调用点 `@()`，导致 5 个目标被当成 1 个、命令行选目标全部"未知目标"。已统一为"函数返回数组、调用点 `@()` 展平"的单一约定，并写进回归测试。
- **重复还原被误报**：再次运行还原脚本时会打印"隔离区文件已不存在 + 跳过"，让用户以为出错。现在会先判断原文件是否已在原位，识别为"此前已还原"。
- **`-Restore` 被无关模块拖累**：交互界面模块缺失时整个工具无法启动。现在该模块只在 `-Clean` 时必需，扫描与还原照常可用。
- **`-SelectTargets` 逗号传参**：用 `powershell -File` 传 `a,b` 会作为单个字符串进来，现已统一按逗号再拆分。

### 变更

- README 与 CHANGELOG 改为如实反映"诊断 + 可选清理"的实际能力，不再把所有内容标成未实现。

## [0.1.0] - 2026-10-04

### 新增

- **只读诊断工具（首个可用版本）**：双击 `Start-Optimizer.cmd` 即可扫描并生成中文报告，全程不修改系统。
  - 主入口 `Win11Optimizer.ps1`：环境探测、自动提权（可用 `-NoElevate` 跳过）、扫描调度、控制台报告、Markdown 报告落盘、日志记录。
  - `lib/Common.ps1`：日志与输出、目录体积测量（带超时与错误计数）、系统信息探测、Finding 契约。
  - `lib/Scan.Disk.ps1`：分区剩余空间（含 15% 降速线，<8% 升为严重）、可清理缓存体积（只测量不删除）、下载目录大文件提示。
  - `lib/Scan.System.ps1`：内存占用与吃内存最多的进程（同名进程合并统计）、厂商常驻服务与厂商不匹配检测、开机启动项、杀毒软件冲突、系统还原状态、待重启状态（多来源交叉验证）。
  - `lib/Scan.Power.ps1`：当前电源方案是否被改成第三方、CPU 是否被限频（PROCTHROTTLEMAX）、可持续性计划任务是否已启用。
  - `Start-Optimizer.cmd`：纯 ASCII 文件名的启动器（铁律 L5），含编码设置与退出码处理。
  - 实测：在本机（Alienware m15 R3 / Win11 26200）完整扫描约 6 秒，正确报出"2 套安全软件同时实时防护"与"缓存占用 4.65 GB"。
- **铁律检查器** `analyzer/IronLaw/IronLaw.Checker.psm1`：基于 PowerShell AST 的静态检查，逐条落实 PRD §12 的 L1–L5。
  - L1 `AvoidForbiddenCommand` / `AvoidForbiddenInlineCommand` / `AvoidForbiddenPath`
  - L2 `AvoidSilentlyContinueErrorAction` / `AvoidEmptyCatchBlock`
  - L3 `RequireProcessTimeout`
  - L4 `RequireUtf8Bom`
  - L5 `AvoidNonAsciiLauncherName`
- **Pester 测试** `analyzer/tests/IronLaw.Tests.ps1`：21 个用例，双向验证——违规夹具必须被检出，合规夹具必须零误报。
- **测试夹具** `analyzer/tests/fixtures/`：`violations.ps1` 与 `compliant.ps1`。
- **CI 门禁** `ci/Invoke-Analysis.ps1`：自包含的 3 阶段检查（解除文件阻止标记 → 铁律扫描 + 自身 BOM 校验 → Pester），任一阶段失败即整体失败；每个阶段都会打印实际检查的文件数，检查数为 0 视为失败。
- **失败路线记录** `analyzer/experimental/`：PSScriptAnalyzer 自定义规则尝试失败的过程与接口契约分析，保留下来避免重复踩坑。
- **规格文档** `docs/PRD.md`：需求文档正文入库，作为本仓库唯一的规格来源（含 §2 设计原则 P1–P5 与 §12 铁律 L1–L10）。文中代码示例刻意展示被禁止的反模式，因此文件头带 `IronLaw-Suppress: *` 说明。
- **文档** `docs/plugin-development.md`（插件开发完整指南 + 可直接复制的 `010-disk-shadercache` 完整示例）、`docs/safety-model.md`（安全模型详解，逐条对应铁律背后的真实事故）、`docs/risk-classification.md`（风险分级标准）—— 已编写。
- **仓库门面与贡献文件**：`LICENSE`（MIT）、`CHANGELOG.md`、`CONTRIBUTING.md`、`SECURITY.md`、`.gitignore`、`.github/ISSUE_TEMPLATE/` 下的 4 个 Issue 模板、`.github/pull_request_template.md`。

### 变更

- 无。项目仍在起步阶段，没有对外行为发生过变更。

### 当时未做（已在后续版本补齐）

- **清理与一键还原**：v0.1.0 只诊断不执行。已在 **v1.0.0** 补齐（零风险缓存清理 + 隔离区 + `-Restore`）。
- **交互勾选列表**：v0.1.0 没有。已在 v1.0.0 补齐（`-Clean`）。
- 仍**未实现**：`engine/` 完整引擎、`plugins/` 插件体系、改服务/改注册表类优化、GUI 壳（Phase 2）。

> 换句话说：v0.1.0 拿到的是一个能跑只读诊断并出报告的工具（外加铁律检查器与 CI），
> 它不会替你清理任何东西——清理能力在 v1.0.0 才出现。

---

## 版本发布历史

暂无。第一个版本号会在主入口与首批插件落地、CI 全绿之后确定。

---

## 如何维护本文件

- 每次对外可见的改动（新功能、行为变更、修复、安全相关）都往 `[未发布]` 下对应小节追加一条。
- 使用 Keep a Changelog 的标准小节名：`新增` / `变更` / `废弃` / `移除` / `修复` / `安全`；没有内容的小节可以不写。
- 发版时：把 `[未发布]` 改成 `[x.y.z] - YYYY-MM-DD`，并在文件上方新开一个空的 `[未发布]` 小节。
- 不要为本文件补写"记忆中的"历史版本，也不要提前声明未发布的日期。
