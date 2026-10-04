# Win11-Optimizer

用纯 PowerShell 写的 Windows 11 诊断与优化工具，面向用了几年没怎么优化过、也不想为此学运维的普通用户。

- **轻量**：不用安装，不需要 Python 或任何运行库，不常驻后台，不联网。
- **可解释**：先只读扫描，用大白话列出发现的问题和实测数据，再由你自己勾选要处理哪些。
- **可还原**：改动前落盘快照，运行结束生成一键还原脚本（设计目标，尚未实现）。

> 项目动机：把一次真实的人工优化流程（扫描 → 勾选 → 可还原执行）做成普通人敢点的工具。

**状态：早期开发。** 目前可用的只有架构铁律检查器和本地门禁；扫描引擎、主入口、插件都还没实现，现在还不能一键优化。详见[项目状态](#项目状态)。

---

## 它解决什么问题

下面这些情况在一台用了几年、几乎没优化过的 Win11 机器上都真实出现过。它们的共同点是：进程名看不懂，也没有任何软件会主动提示。

| 现象 | 实情 |
|---|---|
| 开机慢、持续卡顿 | Dell 后台进程 `ServiceShell.exe` 占用 1797 MB 内存，戴尔官方已确认的内存泄漏缺陷 |
| 磁盘长期满载 | 三套杀毒软件同时实时扫描（Defender + 微软电脑管家 + 360 残留） |
| 特定场景卡顿 | 电源方案被后台计划任务改回第三方方案，CPU 被限频 |
| Steam 反复报错 | hosts 被加速器塞入 47 条记录，把 47 个域名（含 15 个 Steam 域名）指向 `127.0.0.1` |
| C 盘常年飘红 | 仅剩 27.70 GB（13.5%），低于 15% 时 Windows 会明显变慢 |

同一台机器手工处理前后的对比：

| 指标 | 处理前 | 处理后 |
|---|---|---|
| 内存空闲 | 4.62 GB | 9.99 GB |
| 第三方常驻服务 | 22 个 | 5 个 |
| C 盘可用 | 27.70 GB（13.5%） | 41.73 GB |
| E 盘可用 | 403.60 GB | 622.55 GB |
| 同时运行的安全软件 | 3 套 | 1 套 |

以上数字是单机实测结果，来自一次完整的人工优化，**不是本工具产出的**。那次能做成靠的是每一步都有人盯着并手工确认；这个项目想把它变成普通人也敢点的流程。

---

## 安全设计

工具会修改服务启动类型、计划任务、电源方案这类系统设置，所以安全机制全部前置，不依赖"使用时小心"。完整说明见 [docs/safety-model.md](docs/safety-model.md)。

- 只用白名单：可清理的路径写死在插件元数据里，不使用"排除掉重要的、剩下都删"的排除法。
- 不静默失败：错误必须被捕获并说明发生了什么、可能的原因、怎么补救，不允许把失败当成功。
- 外部调用带超时：所有外部进程调用都有硬超时与强制终止，避免脚本卡死。
- 改前先快照：每次改动前落盘快照，运行结束生成 `Restore-All.ps1`，支持 `-WhatIf` 演练、`-List` 查看、`-Only <插件>` 单独还原。（未实现）
- 按风险分级：零风险项默认勾选，中高风险默认不勾且需展开才可见，高风险需二次确认。标准见 [docs/risk-classification.md](docs/risk-classification.md)。

以下事情永久不做，相关功能请求不会被接受：删除或移动用户数据文件、注册表"一键清理"、自动修改网络配置（重置 Winsock 或 DNS）、自动卸载软件、自动升级驱动与固件、上传任何用户数据、插件引用外部下载的工具（必须离线可用）。大于 100 MB 的删除不在此列，但必须由你单独确认。

---

## 项目状态

| 模块 | 状态 |
|---|---|
| 铁律检查器：L1–L5 静态检查 + 21 个 Pester 用例（含违规/合规双向验证） | 已完成，本地门禁三阶段全绿 |
| 扫描引擎、主入口、优化插件、快照与还原 | 未实现 |

里程碑按 [docs/PRD.md](docs/PRD.md) 的编号推进：

- **M1** 引擎骨架：契约、日志、预检、快照 —— 未开始
- **M2** 首批插件：磁盘 3 个、服务 2 个、启动项 2 个 —— 未开始
- **M3** 安全加固：白名单校验、危险命令拦截、还原脚本 —— 未开始
- **M4** 体验打磨：控制台界面、三段式文案、报告渲染 —— 未开始
- **M5** 补齐全部 15 个诊断模块 —— 未开始
- **M6** 文档、CI、社区模板、v1.0 发布 —— 进行中

> M1–M3 完成前，本仓库不具备优化电脑的能力。检查器先于引擎存在是刻意的：安全规则要先于被约束的代码落地。

---

## 需求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 11（21H2 / build 22000 及以上）。不支持 Windows 10 |
| PowerShell | 5.1（系统自带）或 7+。5.1 必须能跑通 |
| Pester | 5.x，仅运行测试套件时需要（4.x 不支持 `New-PesterConfiguration`） |
| 权限 | 只读扫描不需要管理员；执行优化项需要（启动器会请求提权） |
| 其他依赖 | 无。不用 Python、不用运行库、不联网 |

---

## 安装

面向使用者的安装方式**暂时没有**——主入口还未实现。想等它可用，可以先 Star 或 Watch 本仓库。

面向贡献者：

```powershell
git clone https://github.com/ice7zero777/Win11-Optimizer.git
cd Win11-Optimizer

# 运行测试套件需要 Pester 5.x
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force

# 铁律检查器需要安装到浅路径（深路径下模块加载会失败）
$dest = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\IronLaw.Checker'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item .\analyzer\IronLaw\IronLaw.Checker.psm1 $dest
Import-Module IronLaw.Checker
```

## 用法

一键优化尚未可用。目标形态是双击 `Start-Optimizer.cmd`，扫描 30 秒到 2 分钟后给出报告与勾选清单，选定后逐项执行，最后生成还原脚本。

现在可以运行的是代码检查：

```powershell
# 检查检查器自己的违规夹具，应当报出违规
Invoke-IronLawCheck -Path .\analyzer\tests\fixtures\violations.ps1

# 检查整个 analyzer 目录
Invoke-IronLawCheck -Path .\analyzer -Exclude '*\experimental\*'

# 完整本地门禁：解锁定、铁律扫描、BOM 自查、Pester
.\ci\Invoke-Analysis.ps1
```

检查器只检查 `.ps1` / `.psm1` / `.psd1`。仓库里目前还没有 `plugins/` 目录，插件落地后示例会改成对插件目录的检查。

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/PRD.md](docs/PRD.md) | 需求规格：设计原则、十条铁律、15 个诊断模块、插件契约 |
| [docs/plugin-development.md](docs/plugin-development.md) | 插件开发指南与完整示例 |
| [docs/safety-model.md](docs/safety-model.md) | 安全模型：威胁模型与防护机制 |
| [docs/risk-classification.md](docs/risk-classification.md) | 风险分级标准 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 贡献指南、编码规范、PR 自检清单 |
| [SECURITY.md](SECURITY.md) | 安全政策与漏洞报告流程 |
| [CHANGELOG.md](CHANGELOG.md) | 更新日志（首个版本尚未发布） |
| [analyzer/README.md](analyzer/README.md) | 铁律检查器的实现说明 |

## 常见问题

**清理掉的文件能找回来吗？**
重启之类的系统设置改动可以通过还原脚本恢复。缓存类文件（着色器缓存、临时文件等）只记录清单、不备份内容，因为它们会被系统自动重建——工具不会删除有独立价值的用户文件。

**什么时候能真正用上？**
M1 到 M3 完成之后。在那之前仓库里的东西只对开发者和审阅者有意义。

**支持 Windows 10 吗？**
v1.0 不支持，见 [docs/PRD.md](docs/PRD.md) §16。

**出错了怎么办？**
先看 `.\ci\Invoke-Analysis.ps1` 的输出；如果有还原脚本，用 `-WhatIf` 先演练一次。问题解决不了就开 Issue，模板会提示需要哪些信息。

## 参与

- 报告 Bug 或提优化建议：开 Issue，模板会提示需要哪些环境信息。
- 贡献优化插件：先读 [docs/plugin-development.md](docs/plugin-development.md)。
- 提 PR 前请读 [CONTRIBUTING.md](CONTRIBUTING.md) 里的十条铁律自检清单，并确认 `.\ci\Invoke-Analysis.ps1` 通过。
- 发现安全漏洞（尤其是可能导致误删的）：走 [SECURITY.md](SECURITY.md) 的私有报告流程，不要开公开 Issue。

## 关于作者

我是计算机相关专业的在读学生。电脑用了几年越来越卡，翻了一圈"一键优化"工具，发现它们普遍的问题是：点完按钮你不知道它动了什么，出了问题也退不回去。后来我一边查资料一边用 AI 把那台电脑整理了一遍，就想到把这套流程做成工具，给有同样需求的人省点事。

项目里的十条铁律都是自己踩坑之后总结的，比如用 `SilentlyContinue` 吞掉删除失败、报告"已清理"实际一个文件都没删。所以这个项目最看重那些看起来多余的限制。目前 AI 在开发中帮了相当大一部分忙，代码质量还在慢慢提高，欢迎指出问题。觉得有用的话点个 Star；发现哪里做得不对，欢迎开 Issue，最好带上日志。

## 许可

MIT License，按"原样"提供，详见 [LICENSE](LICENSE)。
