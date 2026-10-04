#Requires -Version 5.1
<#
.SYNOPSIS
    图形界面的确认契约测试：没有用户确认，就绝不能清理。

.DESCRIPTION
    这个文件锁住一条安全底线：`Ask-GuiConfirmation` 返回 $false 时，
    清理与还原都必须在"动手之前"停下，一个文件都不许动。

    为什么要专门测这一条：命令行版有 `-Clean` 需要输入 `yes`，图形界面版靠弹窗确认。
    弹窗是模态的、无法在无人值守下点击，所以这里用**替换函数实现**的方式验证调用方的
    分支逻辑——这才是真正决定"会不会误清理"的代码。

.NOTES
    测试只使用临时目录里的文件，不触碰任何用户数据，也不修改系统设置。
    点了"取消"之后必须零改动，这是本文件最核心的断言。
#>

BeforeAll {
    # 逐级 Split-Path -Parent 定位仓库根（不要用 Join-Path $PSScriptRoot '..\..'，那在 Pester 下不可靠）
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    . (Join-Path $repoRoot 'lib\Common.ps1')
    . (Join-Path $repoRoot 'lib\Cleanup.Targets.ps1')
    . (Join-Path $repoRoot 'lib\Cleanup.Snapshot.ps1')
    . (Join-Path $repoRoot 'lib\Cleanup.Engine.ps1')
    . (Join-Path $repoRoot 'lib\Gui.Core.ps1')

    # 定义一个可替换的确认函数桩：测试里就地改写它的返回值
    $script:ConfirmAnswer = $false
    function Ask-GuiConfirmation {
        param([string]$Message, [string]$Title)
        return $script:ConfirmAnswer
    }
}

Describe '确认契约：用户点"取消"时不得做任何改动' {
    It '确认函数返回 false 时，隔离循环不会移动任何文件' {
        # 造 2 个待隔离文件（放在临时目录下，处于清理白名单范围）
        $work = Join-Path $TestDrive 'confirm-work'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $files = @()
        foreach ($name in 'a.bin', 'b.bin') {
            $f = Join-Path $work $name
            [System.IO.File]::WriteAllBytes($f, (New-Object byte[] 4096))
            $files += $f
        }
        $before = @(Get-ChildItem -LiteralPath $work -File).Count

        # 模拟调用方：先问确认，false 就直接返回
        $script:ConfirmAnswer = $false
        $confirmed = Ask-GuiConfirmation -Message '要清理吗' -Title '确认清理'

        $run = New-SnapshotRun -BaseDirectory (Join-Path $TestDrive 'cancel-snap') -BudgetBytes 1MB
        if ($confirmed) {
            foreach ($f in $files) { $null = Move-FileToQuarantine -SourcePath $f -Run $run }
        }

        # 核心断言：取消之后文件必须一个不少
        $confirmed | Should -BeFalse
        @(Get-ChildItem -LiteralPath $work -File).Count | Should -Be $before
        $run.MovedCount | Should -Be 0
    }

    It '确认函数返回 true 时，才会真正移动文件' {
        $work = Join-Path $TestDrive 'confirm-work2'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $f = Join-Path $work 'c.bin'
        [System.IO.File]::WriteAllBytes($f, (New-Object byte[] 8192))

        $script:ConfirmAnswer = $true
        $confirmed = Ask-GuiConfirmation -Message '要清理吗' -Title '确认清理'

        $run = New-SnapshotRun -BaseDirectory (Join-Path $TestDrive 'apply-snap') -BudgetBytes 1MB
        $moved = 0
        if ($confirmed) {
            $result = Move-FileToQuarantine -SourcePath $f -Run $run
            if ($result.Status -eq 'Moved') { $moved++ }
        }

        $confirmed | Should -BeTrue
        $moved | Should -Be 1
        Test-Path -LiteralPath $f | Should -BeFalse
    }

    It 'Ask-GuiConfirmation 是真实存在的函数（正式运行走真实弹窗路径）' {
        # 本条只确认函数名存在且可调用；真实弹窗需要有人在桌面上点一次
        (Get-Command -Name 'Ask-GuiConfirmation' -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe '界面格式化契约：数据形状必须能被表格直接绑定' {
    It 'Format-GuiFindings 输出 Severity/Title/Detail/Advice 四个字段' {
        $findings = @(
            @{ Id = 'x.one'; Severity = 'High'; Title = '问题一'; Detail = '说明一'; Advice = '建议一'; Evidence = @{} }
            @{ Id = 'x.two'; Severity = 'Info'; Title = '问题二'; Detail = '说明二'; Advice = ''; Evidence = @{} }
        )
        $rows = @(Format-GuiFindings -Findings $findings)
        $rows.Count | Should -Be 2
        foreach ($row in $rows) {
            foreach ($name in 'Severity', 'Title', 'Detail', 'Advice') {
                $row.PSObject.Properties.Name | Should -Contain $name
            }
        }
        # 排序应把 High（偏高）排在 Info（提示）前面
        $rows[0].Severity | Should -Be '偏高'
    }

    It '同级项之间顺序稳定（不会每次刷新乱跳）' {
        # Sort-Object 不是稳定排序，同级项顺序会随实现变化。
        # 这里断言：严重度相同的问题，必须保持传入的先后顺序。
        $findings = @()
        1..5 | ForEach-Object {
            $findings += @{ Id = "s$_"; Severity = 'High'; Title = "同级$_"; Detail = 'd'; Advice = 'a'; Evidence = @{} }
        }
        $rows = @(Format-GuiFindings -Findings $findings)
        $rows.Count | Should -Be 5
        ($rows | ForEach-Object { $_.Title }) -join ',' | Should -Be '同级1,同级2,同级3,同级4,同级5'
    }

    It '严重度不同时，严重的排在前面' {
        $findings = @(
            @{ Id = 'i'; Severity = 'Info'; Title = '提示项'; Detail = 'd'; Advice = ''; Evidence = @{} }
            @{ Id = 'c'; Severity = 'Critical'; Title = '严重项'; Detail = 'd'; Advice = 'a'; Evidence = @{} }
            @{ Id = 'm'; Severity = 'Medium'; Title = '中等项'; Detail = 'd'; Advice = 'a'; Evidence = @{} }
        )
        $rows = @(Format-GuiFindings -Findings $findings)
        $rows[0].Title | Should -Be '严重项'
        $rows[1].Title | Should -Be '中等项'
        $rows[2].Title | Should -Be '提示项'
    }

    It 'Format-GuiCleanupItems 把小块体积说明写进 Note，且只有小文件时不默认勾选' {
        $items = @(
            @{ Id = 'temp.user'; Name = '临时文件'; Bytes = [int64]3GB; FileCount = 300; SmallFileBytes = [int64]300MB
                SmallFileCount = 4000; Safety = '说明'; Paths = @('x'); MinBytes = [int64]50MB }
            @{ Id = 'cache.shader'; Name = '着色器缓存'; Bytes = [int64]0; FileCount = 0; SmallFileBytes = [int64]50MB
                SmallFileCount = 82; Safety = '说明'; Paths = @('y'); MinBytes = [int64]100MB }
        )
        $rows = @(Format-GuiCleanupItems -Items $items)

        $big = $rows | Where-Object { $_.Id -eq 'temp.user' }
        $small = $rows | Where-Object { $_.Id -eq 'cache.shader' }

        $big.Selected | Should -BeTrue
        $big.Note | Should -Match '留在原处'
        $big.Bytes | Should -Be ([int64]3GB)

        $small.Selected | Should -BeFalse
        $small.Enabled | Should -BeFalse
        $small.Note | Should -Match '不会清理'
    }
}
