# 安全模型

> 这份文档回答一个问题：**凭什么相信一个陌生人写的小工具不会搞坏你的电脑？**

答案不是"因为我小心"。答案是：**这个工具被设计成做不到那些危险的事。**

---

## 1. 威胁模型：我们假设什么会出错

一个优化工具最危险的三种坏法，都不是"故意使坏"，而是**无意的疏忽**：

| 威胁 | 真实发生过的形态 |
|---|---|
| **误删用户数据** | 想删缓存，结果通配符写错，扫到了文档目录 |
| **静默失败** | 删除失败了，但错误被吞掉，工具报告"已清理 3.7 GB"，用户看到的是假成绩 |
| **无限阻塞** | 调用了系统命令，命令卡在"正在停止"状态，脚本就此挂住，用户以为电脑死机 |

这个项目的对策不是"写代码时小心点"，而是**把这三类坏事变成架构上做不到的事**。

---

## 2. 第一条防线：白名单（铁律 L1）

**所有删除类操作的路径，必须写死在插件的元数据里。**

引擎在**执行前**校验目标路径是否落在白名单内；不在就拒绝执行并报错。插件不能"顺手多删一个目录"。

```powershell
# ❌ 永久禁止：排除法。任何未预料到的目录都会被卷进去
Get-ChildItem 'D:\' -Recurse |
    Where-Object { $_.FullName -notmatch '重要的' } |
    Remove-Item -Recurse -Force

# ✅ 唯一允许的形式：白名单，路径逐条列出
$allowed = @(
    "$env:LOCALAPPDATA\NVIDIA\DXCache"
    "$env:LOCALAPPDATA\NVIDIA\GLCache"
)
```

**为什么这是铁律而不是建议**：排除法的安全性取决于"你想到的例外够不够全"。
你没见过的目录名，它就删。真实项目里就因此差点删掉 Java 的 `javapath` 目录。

### 运行时硬拦截名单

即使有插件想绕过，引擎也会在**两个时机**拦截（插件加载时静态扫描 + 执行时动态校验）：

```
拦截路径：Desktop / Documents / Downloads / Pictures / Videos / Music
          C:\Windows\System32 / SysWOW64 / WinSxS
          C:\Program Files (/x86) / C:\ProgramData\Microsoft
          C:\Users / C:\$Recycle.Bin / C:\System Volume Information / C:\Recovery

拦截命令：删除盘根、Format-Volume、Clear-Disk、Initialize-Disk、Remove-Partition、
          net user /delete、netsh winsock reset、bcdedit /delete、
          Set-ExecutionPolicy Unrestricted、关闭 Defender 实时防护

额外阈值：单次删除超过 100 MB 需要用户显式确认
```

这些不只是"写在文档里"。它们同时是 AST 级别的 CI 检查（见 [`../analyzer/README.md`](../analyzer/README.md)），
写进代码就会让 CI 红掉，合不进去。

---

## 3. 第二条防线：禁止静默失败（铁律 L2）

这是最阴险的一类 bug，因为它**看起来是成功的**：

```powershell
# ❌ 曾经真实发生过：报告"已删除 25 个文件"，实际一个都没删
$ErrorActionPreference = 'SilentlyContinue'
Remove-Item $path -Recurse -Force
```

正确做法是让失败必然可见、且必须包含用户能用的信息：

```powershell
try {
    Remove-Item $path -Recurse -Force -ErrorAction Stop
} catch {
    return @{
        Status      = 'Failed'
        Message     = "无法删除 $path：$($_.Exception.Message)"
        Hint        = '可能原因：文件正被占用（试着关掉相关程序后重试）'
        Recoverable = $true
    }
}
```

**失败报告必须包含三要素**：发生了什么、可能的原因、怎么补救。
`catch { }` 空块被 CI 静态检查直接拒绝。

---

## 4. 第三条防线：所有外部调用带超时（铁律 L3）

```powershell
# ❌ 永久禁止：可能永久阻塞，用户只能看着它挂着
Start-Process $exe -Wait

# ✅ 硬超时 + 强制终止
$p = Start-Process $exe -PassThru
if (-not $p.WaitForExit(60000)) {
    taskkill /F /PID $p.Id /T
    return @{ Status = 'Failed'; Message = '命令超时（60 秒），已强制结束' }
}
```

**为什么值得单列一条铁律**：真实事故是 `Stop-Service` 撞上一个"正在停止"的服务，
命令无限重试，刷了几百行警告，脚本卡死 10 分钟才被发现。停服务这类操作改用
先 `sc.exe query` 查状态、必要时 `sc.exe delete` 标记删除，而不是无脑停。

---

## 5. 可逆性：快照与还原（原则 P3）

**每一次改动之前**，先落盘一份快照；**一次运行结束之后**，生成 `Restore-All.ps1`。

```
Snapshot/
├─ 2026-10-04_143022/          # 每次运行一个时间戳目录
│  ├─ manifest.json            # 本次变更总账
│  ├─ services-143022.json     # 服务原始启动类型
│  ├─ registry-startup.reg     # 注册表原始导出
│  └─ power-143022.json        # 电源方案原值
└─ Restore-All.ps1             # 最新一次的一键还原
```

| 改动类型 | 快照内容 | 还原方式 |
|---|---|---|
| 文件删除 | 文件清单 + 大小 + 时间戳 | 缓存类无需还原（会自动重建） |
| 服务启动类型 | 名称 / StartType / Status | `Set-Service -StartupType <原值>` |
| 注册表改动 | `reg export` 导出 | `reg import` |
| 计划任务 | 任务定义导出 | `Register-ScheduledTask` |
| 电源方案 | `powercfg /list` + 关键设置 | `powercfg /setacvalueindex` |

`Restore-All.ps1` 必须具备的能力：

1. `-WhatIf` 演练模式（只显示将要做什么，先看清楚再动手）
2. `-Only <pluginId>` 单独还原某一项
3. `-List` 列出所有可还原项
4. 还原失败明确报告，**不静默跳过**
5. 自带管理员权限检查
6. 还原后自动验证并输出结果

**诚实声明**：文件删除类快照记录的是"清单"，不是文件内容。所以**缓存类文件不需要还原**
（删了会自动重建），而**任何有独立价值的用户文件都不在删除范围内**——这两件事是配套的，
不是巧合。

---

## 6. 默认安全：风险分级与"人在场"（原则 P2 + 铁律 L7）

| 等级 | 名称 | 默认勾选 | 约束 |
|---|---|---|---|
| 0 | 🟢 零风险 | ✅ 是 | 纯缓存 / 临时文件，删了自动重建 |
| 1 | 🔵 低风险 | ✅ 是 | 可逆的配置改动 |
| 2 | 🟡 中风险 | ❌ 否 | 需展开"高级"区域才可见 |
| 3 | 🔴 高风险 | ❌ 否 | 需**二次书面确认** |
| 4 | ⛔ 极高风险 | 永不勾选 | **只输出建议**，工具绝不代执行（卸载软件、BIOS、驱动） |

判定细节见 [`risk-classification.md`](risk-classification.md)。

**"人在场"的含义**：固件 / BIOS 这类操作，工具**永远不会**自动执行，只告诉你"有更新可用，请去官网"。
原因很朴素——这些操作中断的电费比省的性能贵得多。

---

## 7. 预检失败要说清楚，不许偷偷跳过（原则 P2）

每一项执行前都要过预检：

| 检查 | 失败怎么办 |
|---|---|
| 管理员权限 | 提示提权；不满足就**跳过并说明原因** |
| 系统版本 | 非 Win11 则禁用相关项 |
| 磁盘空间 | 不足则拒绝，并说明需要多少 |
| 电源状态 | 需要接电源的项（如页面迁移）在电池下拒绝 |
| 目标进程在跑 | 按 `excludeIfProcessRunning` 跳过 |
| **目标路径在白名单内** | **强制校验**，不在就拒绝 |
| 冲突项已选 | 按 `conflictsWith` 提示并解决 |
| 依赖项已选 | 按 `dependsOn` 自动补全或要求手动 |

"静默跳过"被明确禁止——你以为它做了，其实没有，这和静默失败一样有害。

---

## 8. 隐私：不上传任何东西

- 工具**不联网**、**不请求任何外部服务**、**不上传任何用户数据**（含机型、路径、日志、诊断结果）
- 插件**不允许**引用外部下载的工具——必须用系统自带能力，保证离线可用
- 诊断结果里的敏感信息（用户名、SID、路径）由引擎在生成报告时提示用户"分享前先看一眼"

---

## 9. 这个模型的边界（说清楚它保证不了什么）

诚实一点，这套设计**保证不了**的事：

- ❌ 保证不了"永远不会出问题"。它保证的是**出了问题能还原**、**失败会明说**
- ❌ 保证不了性能提升幅度。卡顿往往有多个原因，工具只解决它能实测到的那几类
- ❌ 保证不了插件作者的主观判断一定合理。所以高风险项永远要你自己点确认
- ❌ 保证不了非 Win11 环境。v1.0 就是只做 Win11，宁可少支持也不做半吊子兼容

如果你发现了这套模型里的漏洞——尤其是**能导致误删或不可逆操作**的那种——
请走 [`../SECURITY.md`](../SECURITY.md) 里的私有报告流程，先别开公开 Issue。
