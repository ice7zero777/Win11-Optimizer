# 更新日志

本文件记录 Win11-Optimizer 的所有重要变更。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号规划遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> **当前状态说明（请先读这段）**
> 本项目**尚未发布任何带版本号的版本**，仓库里也没有 `v0.x` / `v1.0` 的 tag 或 GitHub Release。
> 目前真正落地并经过验证的只有"铁律分析器"（源码文本检查 + Pester 测试 + CI 门禁）；
> 引擎层、插件层、主入口都还没有写。下面「未发布」区块忠实反映这一事实。

---

## [未发布]

### 新增

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

### 规划中（**尚未实现，尚无代码**）

以下内容是 PRD 里的设计，不是已完成的功能，写在这里是为了让"什么还没做"一目了然：

- **引擎层** `engine/`：`DiagnosticRunner`、`PluginLoader`、`SelectionModel`、`ExecutionEngine`、`SnapshotManager`、`ReportRenderer`、`Logger`、`Preflight`、`Contracts` —— 未实现。
- **插件层** `plugins/`：PRD §4.1 规划的 15 个优化模块（disk / service / startup / power / security / privacy / device / network / environment / update）—— 未实现，目前只有目录结构设计。
- **主入口**：`Win11Optimizer.ps1`（CLI）与 `Start-Optimizer.cmd`（纯 ASCII 名自提权启动器）—— 未实现。
- **诊断与优化能力本身**：全量只读扫描、勾选列表、快照与一键还原、报告渲染 —— 均未实现。
- **GUI 壳（Phase 2）**—— 未开始。

> 换句话说：现在克隆本仓库，你拿到的是一个**能跑的代码检查器**、一套设计文档，还不是一个能优化电脑的工具。
> 主入口落地并跑通「扫描 → 勾选 → 执行 → 还原」全流程之后，才会出现第一个带版本号的 Release。

---

## 版本发布历史

暂无。第一个版本号会在主入口与首批插件落地、CI 全绿之后确定。

---

## 如何维护本文件

- 每次对外可见的改动（新功能、行为变更、修复、安全相关）都往 `[未发布]` 下对应小节追加一条。
- 使用 Keep a Changelog 的标准小节名：`新增` / `变更` / `废弃` / `移除` / `修复` / `安全`；没有内容的小节可以不写。
- 发版时：把 `[未发布]` 改成 `[x.y.z] - YYYY-MM-DD`，并在文件上方新开一个空的 `[未发布]` 小节。
- 不要为本文件补写"记忆中的"历史版本，也不要提前声明未发布的日期。
