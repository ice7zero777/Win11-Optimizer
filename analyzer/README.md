# analyzer —— 架构铁律自动检查器

> 这是 `Win11-Optimizer` 的一个组件。项目总览、安全承诺与快速开始请看[根目录 README](../README.md)。

对 [`docs/PRD.md`](../docs/PRD.md) §12 的架构铁律做**机械化强制**。

这个组件存在的理由是：**审查者的"我会仔细看"不算控制。** 每一条真正重要的铁律都被表达成可执行的检查，
违反了 CI 就直接失败。

## 为什么不用 PSScriptAnalyzer 自带规则

那 75 条内置规则检测不到本项目的失败模式。用一个故意不合规的夹具实测，内置规则只报了一条无关的动词警告，
却漏掉了：

- `-ErrorAction SilentlyContinue`（铁律 L2）
- 空的 `catch { }`（铁律 L2）
- 没有超时的 `Start-Process -Wait`（铁律 L3）

这三处遗漏分别对应本项目历史上三次真实故障。
完整的失败尝试与接口契约分析见 [`experimental/README.md`](experimental/README.md)。

## 检查内容

| 铁律 | 规则 | 拒绝的目标 |
|---|---|---|
| L1 | `AvoidForbiddenCommand` | `Format-Volume`、`Clear-Disk`、`Initialize-Disk`、`Remove-Partition` … |
| L1 | `AvoidForbiddenInlineCommand` | `netsh winsock reset`、`bcdedit /delete`、`net user /delete`、`Set-ExecutionPolicy Unrestricted` … |
| L1 | `AvoidForbiddenPath` | `Desktop`、`Documents`、`Downloads`、`C:\Windows\System32`、`C:\Users`、`C:\Program Files` 等目录下的目标 |
| L2 | `AvoidSilentlyContinueErrorAction` | `-ErrorAction SilentlyContinue`、`$ErrorActionPreference = 'SilentlyContinue'` |
| L2 | `AvoidEmptyCatchBlock` | 所有分支体都为空的 `catch` |
| L3 | `RequireProcessTimeout` | 无超时的 `Start-Process -Wait`、`Stop-Service`、`Restart-Service` |
| L4 | `RequireUtf8Bom` | 不带 UTF-8 BOM 的 `.ps1` / `.psm1` / `.psd1` |
| L5 | `AvoidNonAsciiLauncherName` | 名字含非 ASCII 字符的启动器类文件（`*launch*`、`*start*`、`*boot*`、`*entry*`、`*run*`） |

## 用法

```powershell
# 安装检查器（短路径；原因见下方说明）
$dest = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\IronLaw.Checker'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item .\analyzer\IronLaw\IronLaw.Checker.psm1 $dest

Import-Module IronLaw.Checker

# 扫单个文件或整棵树
Invoke-IronLawCheck -Path .\plugins\010-disk-shadercache\plugin.ps1
Invoke-IronLawCheck -Path .\plugins -Exclude '*\reference\*'

# 跑完整门禁（解锁定、扫描、BOM 自查、Pester）
.\ci\Invoke-Analysis.ps1
```

每条违规是一个记录，含 `Law`、`Rule`、`Severity`、`Message`、`File`、`Line`、`Column`。

`IronLaw-Suppress: <Rule>` 指令提供**文件级**例外机制，让合理的不合规参考文件可以入库，
而不必为整个目录开豁免。

## 硬着头皮发现的环境陷阱

**非交互主机与 `Zone.Identifier`。** 带 `Zone.Identifier` 标记的 `.ps1` 会让 PowerShell 5.1 抛出
`AuthorizationManager 检查失败` 而不是弹信任提示，因为非交互会话无法弹窗。症状很误导人——看起来像权限
或路径问题。因此 `ci/Invoke-Analysis.ps1` 在处理任何文件之前先对整个仓库执行 `Unblock-File`。
排查过程中排除了两个混淆变量：执行策略（`Unrestricted`）与路径长度。

**空集合会消失。** PowerShell 函数返回空集合时，调用点拿到的是 `$null`，于是 `.Count` 是 `$null` 而不是 `0`。
检查器用 `Write-Output -NoEnumerate` 返回结果，因此没有这个问题，但也意味着**不要再包一层 `@()`**：

```powershell
# ✅ 正确：直接接收，10 条违规就是 10
$violations = Invoke-IronLawCheck -Path .\analyzer\tests\fixtures\violations.ps1
$violations.Count    # 10

# ❌ 错误：@() 会把已返回的数组再包一层，数出 1 而不是 10
@(Invoke-IronLawCheck -Path .\analyzer\tests\fixtures\violations.ps1).Count    # 1
```

（只有在使用**管道**时 PowerShell 才会展平：`@(Invoke-IronLawCheck -Path $p | Where-Object { $_.Law -eq 'L1' }).Count` 是正确的。）
测试套件最早就是被这个坑掉的。

**自指问题。** 检查器自己的模式字符串就是字面量，会被它自己命中。
`ci/Invoke-Analysis.ps1` 排除了 `analyzer\IronLaw\*` 与 `analyzer\rules\*`，这是 linter 自排除的标准做法。

**绝不让某个阶段靠"什么都没找到"过关。** 最早的 BOM 检查用 `Get-ChildItem -Include`，而该参数在路径不含
通配符时会静默返回空，然后它在检查了 0 个文件之后报告成功。现在每个阶段都会打印检查了多少文件，
数量为 0 就失败。

## 目录结构

```
analyzer/
  IronLaw/IronLaw.Checker.psm1        可用的检查器
  tests/IronLaw.Tests.ps1             21 个 Pester 测试
  tests/fixtures/violations.ps1       必须产生违规
  tests/fixtures/compliant.ps1        必须零违规
  experimental/                       PSScriptAnalyzer 失败路线 + 分析
ci/
  Invoke-Analysis.ps1                 门禁
```

## 扩展方式

在检查器里加一个 `Test-IronLaw<Name>` 函数，导出它，加进 `Invoke-IronLawCheck`，
然后补两个测试：一个断言它在 `violations.ps1` 上开火（同时扩展夹具），
一个断言它在 `compliant.ps1` 上保持沉默。**只测一个方向的规则等于没测。**
