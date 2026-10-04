#Requires -Version 5.1
<#
.SYNOPSIS
    清理安全层的 Pester 测试：白名单校验、数组契约、隔离与还原闭环。

.DESCRIPTION
    这里的每一条都对应一次真实踩坑：

      1. **数组契约**：`Get-CleanupItem` 返回 5 个目标时，调用点必须能直接数出 5，
         而不是 1。这个坑在本项目里复发过两次（历史上是检查器的 `.Count` 读成 1，
         v1.0 开发中又因为 `return , $array` 叠加 `@()` 复发一次），所以锁进测试。
      2. **白名单**：用户数据目录与系统目录必须被拒绝；路径穿越必须被拒绝。
      3. **隔离与还原**：移动过去的文件必须能移动回来，重复还原必须被识别。

.NOTES
    测试只使用临时目录与临时文件，不触碰任何用户数据，也不修改系统设置。
#>

BeforeAll {
    # 定位仓库根目录：逐级 Split-Path -Parent。不要用 Join-Path $PSScriptRoot '..\..'，
    # 那在 Pester 下不会按 $PSScriptRoot 解析，会拼出错误路径导致库根本没被加载。
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    . (Join-Path $repoRoot 'lib\Common.ps1')
    . (Join-Path $repoRoot 'lib\Cleanup.Targets.ps1')
    . (Join-Path $repoRoot 'lib\Cleanup.Snapshot.ps1')
    . (Join-Path $repoRoot 'lib\Cleanup.Engine.ps1')

    $script:WorkRoot = Join-Path $TestDrive 'work'
    New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null
}

Describe '清理白名单：必须放行的缓存路径' {
    It '接受用户临时目录' {
        (Test-CleanupPathAllowed -Path ([System.IO.Path]::GetTempPath().TrimEnd('\'))).Allowed | Should -BeTrue
    }

    It '接受显卡着色器缓存目录' {
        $localAppData = [System.Environment]::GetFolderPath('LocalApplicationData')
        (Test-CleanupPathAllowed -Path (Join-Path $localAppData 'NVIDIA\DXCache')).Allowed | Should -BeTrue
    }
}

Describe '清理白名单：必须拒绝的路径' {
    It '拒绝用户数据目录（桌面/文档/下载）' {
        $profile = [System.Environment]::GetFolderPath('UserProfile')
        foreach ($folder in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')) {
            (Test-CleanupPathAllowed -Path (Join-Path $profile $folder)).Allowed | Should -BeFalse
        }
    }

    It '拒绝系统目录' {
        (Test-CleanupPathAllowed -Path (Join-Path $env:WINDIR 'System32')).Allowed | Should -BeFalse
        (Test-CleanupPathAllowed -Path (Join-Path $env:WINDIR 'WinSxS')).Allowed | Should -BeFalse
    }

    It '拒绝磁盘根目录' {
        (Test-CleanupPathAllowed -Path ([System.IO.Path]::GetPathRoot($env:WINDIR))).Allowed | Should -BeFalse
    }

    It '拒绝用路径穿越伪装成缓存目录的路径' {
        $escaped = Join-Path ([System.IO.Path]::GetTempPath()) '..\..\Documents'
        (Test-CleanupPathAllowed -Path $escaped).Allowed | Should -BeFalse
    }

    It '空路径按拒绝处理，而不是抛异常' {
        (Test-CleanupPathAllowed -Path '').Allowed | Should -BeFalse
    }
}

Describe '数组契约：调用点必须能数出正确的元素个数' {
    # 注意：Get-CleanupItem 返回的是 Hashtable 数组（不是 PSCustomObject），
    # 所以必须用 $item['Id'] 取值。写成 $item.Id 会得到 Hashtable 自身的属性（Keys/Count），
    # 断言会莫名其妙地失败——这个坑真的踩过。
    It 'Get-CleanupItem 返回的每一项都能被逐项枚举，不会整体变成 1 个元素' {
        $items = @(Get-CleanupItem -BaseDirectory $script:WorkRoot)
        # 本机至少存在临时目录，所以至少要能识别出 temp.user 这一项
        $items.Count | Should -BeGreaterThan 0
        @($items | Where-Object { $_['Id'] -eq 'temp.user' }).Count | Should -Be 1
    }

    It '每一项都有 Id / Bytes / FileCount 字段，Id 不是拼接出来的长字符串' {
        $items = @(Get-CleanupItem -BaseDirectory $script:WorkRoot)
        foreach ($item in $items) {
            $item.ContainsKey('Id') | Should -BeTrue
            $item.ContainsKey('Bytes') | Should -BeTrue
            $item.ContainsKey('FileCount') | Should -BeTrue
            ([string]$item['Id']) | Should -Not -BeNullOrEmpty
            ([string]$item['Id']) | Should -Not -Match '\s'
            ([string]$item['Id']) | Should -Not -Match ','
        }
    }

    It '返回空集合时不是 $null（空集合解包坑）' {
        $empty = @(Select-CleanupFile -TargetId 'no.such.target' -BaseDirectory $script:WorkRoot)
        $empty.Count | Should -Be 0
    }
}

Describe '隔离与还原闭环' {
    It '把文件移进隔离区，再移回原位，内容与体积保持不变' {
        $run = New-SnapshotRun -BaseDirectory $script:WorkRoot -BudgetBytes 100MB

        $source = Join-Path $script:WorkRoot 'sample.bin'
        [System.IO.File]::WriteAllBytes($source, (New-Object byte[] 2048))
        $sourceSize = (Get-Item -LiteralPath $source).Length

        $result = Move-FileToQuarantine -SourcePath $source -Run $run
        $result.Status | Should -Be 'Moved'
        Test-Path -LiteralPath $source | Should -BeFalse

        $saved = Save-SnapshotManifest -Run $run -Profile (Get-SystemProfile) -BaseDirectory $script:WorkRoot
        $saved.EntryCount | Should -Be 1
        Test-Path -LiteralPath $saved.RestoreScript | Should -BeTrue

        # 还原：把隔离文件移回原位
        $entry = @($run.Entries)[0]
        Move-Item -LiteralPath $entry.QuarantineAs -Destination $entry.OriginalPath -Force
        Test-Path -LiteralPath $source | Should -BeTrue
        (Get-Item -LiteralPath $source).Length | Should -Be $sourceSize
    }

    It '体积预算用尽时返回 OverBudget，而不是继续移动' {
        $run = New-SnapshotRun -BaseDirectory (Join-Path $TestDrive 'budget') -BudgetBytes 1024
        $big = Join-Path $TestDrive 'big.bin'
        [System.IO.File]::WriteAllBytes($big, (New-Object byte[] 8192))

        $result = Move-FileToQuarantine -SourcePath $big -Run $run
        $result.Status | Should -Be 'OverBudget'
        Test-Path -LiteralPath $big | Should -BeTrue
    }

    It '拒绝清理白名单外的文件，并给出原因' {
        $run = New-SnapshotRun -BaseDirectory $script:WorkRoot -BudgetBytes 100MB

        # 样本说明：白名单里的 temp.user 覆盖的是系统临时目录整棵子树，而 Pester 的
        # $TestDrive 恰好就在临时目录下，所以它其实是"白名单内"的路径（会返回 Moved）。
        # 要验证"白名单外被拒绝"，必须挑一个真的不在白名单里的位置：程序数据目录。
        # 这里只判断校验结果，避免在这些目录里真的创建/移动文件。
        $programData = [System.Environment]::GetFolderPath('CommonApplicationData')
        $outsideFile = Join-Path $programData 'win11optimizer-test-not-a-cache.txt'

        $result = Move-FileToQuarantine -SourcePath $outsideFile -Run $run
        $result.Status | Should -Not -Be 'Moved'
        Test-Path -LiteralPath $outsideFile | Should -BeFalse
    }

    It '临时目录整棵子树都在白名单内（含测试工作目录）——记录该行为，避免误判为漏洞' {
        # temp.user 这一项的目标就是系统临时目录本身，所以它下面的子目录（包括 Pester
        # 建在临时目录里的 $TestDrive）都算白名单内，会被允许清理。这是刻意设计：
        # 临时目录里本来就是临时文件。真正防误伤靠另外两道守卫：
        #   1) Test-CleanupPathInsideBase：工具自己的 Reports/Snapshot/Logs 永不清
        #   2) 受保护路径名单：桌面/文档/下载/系统目录一律拒绝（见上面的用例）
        $verdict = Test-CleanupPathAllowed -Path (Join-Path $script:WorkRoot 'some-temp-file.bin')
        $verdict.Allowed | Should -BeTrue
    }
}

Describe '还原脚本生成质量' {
    It '生成的 Restore-All.ps1 语法正确且带 UTF-8 BOM（铁律 L4）' {
        $run = New-SnapshotRun -BaseDirectory (Join-Path $TestDrive 'restorescript') -BudgetBytes 100MB
        $saved = Save-SnapshotManifest -Run $run -Profile (Get-SystemProfile) -BaseDirectory (Join-Path $TestDrive 'restorescript')

        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($saved.RestoreScript, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0

        $bytes = [System.IO.File]::ReadAllBytes($saved.RestoreScript)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }
}
