#Requires -Version 5.1
<#
.SYNOPSIS
    Pester test suite for the Iron Law checker (PRD section 12).

.DESCRIPTION
    Two-directional verification: every rule must fire on a violating fixture AND stay
    silent on a compliant one. A rule that fires on both, or neither, is broken.

.NOTES
    Call convention: `Invoke-IronLawCheck` returns the violation records. BeforeAll
    flattens the result into a plain ArrayList once, so every assertion sees flat
    records. Wrapping an already-collected result in `@()` nests it, which is what
    previously made every count read as 1.

    The repository's PowerShell files are unblocked before discovery. In a non-interactive
    host a Zone.Identifier marker makes PowerShell raise "AuthorizationManager 检查失败"
    because it cannot show the remote-file trust prompt. The CI entry point does the same.
#>

BeforeDiscovery {
    foreach ($filter in @('*.ps1', '*.psm1', '*.psd1')) {
        Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\..') -Recurse -File -Filter $filter -ErrorAction SilentlyContinue |
            ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    }
}

BeforeAll {
    Import-Module PSScriptAnalyzer -Force -ErrorAction SilentlyContinue

    # Prefer the installed copy; fall back to the repository copy.
    Get-Module IronLaw.Checker | Remove-Module -Force -ErrorAction SilentlyContinue
    try {
        Import-Module IronLaw.Checker -Force -ErrorAction Stop
    } catch {
        Import-Module (Join-Path $PSScriptRoot '..\IronLaw\IronLaw.Checker.psm1') -Force -ErrorAction Stop
    }

    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:Violations = Join-Path $script:FixtureDir 'violations.ps1'
    $script:Compliant = Join-Path $script:FixtureDir 'compliant.ps1'

    Unblock-File -LiteralPath $script:Violations -ErrorAction SilentlyContinue
    Unblock-File -LiteralPath $script:Compliant -ErrorAction SilentlyContinue

    # Flatten once so assertions never deal with a nested result.
    $script:Bad = New-Object System.Collections.ArrayList
    foreach ($item in (Invoke-IronLawCheck -Path $script:Violations)) { [void]$script:Bad.Add($item) }

    $script:Good = New-Object System.Collections.ArrayList
    foreach ($item in (Invoke-IronLawCheck -Path $script:Compliant)) { [void]$script:Good.Add($item) }

    function Get-LawCount {
        param([Parameter(Mandatory)][string]$Law)
        return @($script:Bad | Where-Object { $_.Law -eq $Law }).Count
    }
    function Get-RuleCount {
        param([Parameter(Mandatory)][string]$Rule)
        return @($script:Bad | Where-Object { $_.Rule -eq $Rule }).Count
    }
}

Describe 'Iron Law checker - module contract' {
    It 'exposes the public functions' {
        foreach ($fn in @(
                'Invoke-IronLawCheck', 'Test-IronLawWhiteList', 'Test-IronLawProtectedPath',
                'Test-IronLawSilentFailure', 'Test-IronLawProcessTimeout',
                'Test-IronLawUtf8Bom', 'Test-IronLawAsciiLauncher'
            )) {
            Get-Command -Name $fn -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }
    }

    It 'ships both fixtures' {
        Test-Path $script:Violations | Should -BeTrue
        Test-Path $script:Compliant | Should -BeTrue
    }

    It 'returns objects carrying the documented fields' {
        $first = $script:Bad | Select-Object -First 1
        foreach ($field in @('Law', 'Rule', 'Severity', 'Message', 'File', 'Line', 'Column')) {
            $first.PSObject.Properties.Name | Should -Contain $field
        }
    }
}

Describe 'Iron Law L1 - forbidden commands and protected paths' {
    It 'detects forbidden destructive cmdlets' {
        (Get-RuleCount 'AvoidForbiddenCommand') | Should -BeGreaterThan 0
    }

    It 'detects forbidden inline command lines' {
        (Get-RuleCount 'AvoidForbiddenInlineCommand') | Should -BeGreaterThan 0
    }

    It 'detects protected user/system paths' {
        (Get-RuleCount 'AvoidForbiddenPath') | Should -BeGreaterThan 0
    }

    It 'reports L1 violations' {
        (Get-LawCount 'L1') | Should -BeGreaterThan 0
    }
}

Describe 'Iron Law L2 - no silent failure' {
    It 'detects -ErrorAction SilentlyContinue' {
        (Get-RuleCount 'AvoidSilentlyContinueErrorAction') | Should -BeGreaterThan 0
    }

    It 'detects empty catch blocks' {
        (Get-RuleCount 'AvoidEmptyCatchBlock') | Should -BeGreaterThan 0
    }

    It 'reports L2 violations' {
        (Get-LawCount 'L2') | Should -BeGreaterThan 0
    }
}

Describe 'Iron Law L3 - bounded process calls' {
    It 'detects unbounded blocking process calls' {
        (Get-RuleCount 'RequireProcessTimeout') | Should -BeGreaterThan 0
    }

    It 'reports L3 violations' {
        (Get-LawCount 'L3') | Should -BeGreaterThan 0
    }
}

Describe 'Iron Law L4 - UTF-8 BOM' {
    It 'detects a PowerShell file without a BOM' {
        $tmp = Join-Path $TestDrive 'no-bom.ps1'
        [System.IO.File]::WriteAllText($tmp, 'Write-Output "x"', (New-Object System.Text.UTF8Encoding($false)))
        Unblock-File -LiteralPath $tmp -ErrorAction SilentlyContinue
        @(Test-IronLawUtf8Bom -Path $tmp).Count | Should -BeGreaterThan 0
    }

    It 'accepts a PowerShell file with a BOM' {
        $tmp = Join-Path $TestDrive 'with-bom.ps1'
        [System.IO.File]::WriteAllText($tmp, 'Write-Output "x"', (New-Object System.Text.UTF8Encoding($true)))
        Unblock-File -LiteralPath $tmp -ErrorAction SilentlyContinue
        @(Test-IronLawUtf8Bom -Path $tmp).Count | Should -Be 0
    }

    It 'ignores files that are not PowerShell scripts' {
        $tmp = Join-Path $TestDrive 'notes.txt'
        [System.IO.File]::WriteAllText($tmp, 'plain text', (New-Object System.Text.UTF8Encoding($false)))
        @(Test-IronLawUtf8Bom -Path $tmp).Count | Should -Be 0
    }
}

Describe 'Iron Law L5 - ASCII launcher names' {
    It 'detects a non-ASCII launcher file name' {
        $tmp = Join-Path $TestDrive '启动-run.cmd'
        '@echo off' | Out-File -LiteralPath $tmp -Encoding ASCII
        @(Test-IronLawAsciiLauncher -Path $tmp).Count | Should -BeGreaterThan 0
    }

    It 'accepts an ASCII launcher file name' {
        $tmp = Join-Path $TestDrive 'Start-Optimizer.cmd'
        '@echo off' | Out-File -LiteralPath $tmp -Encoding ASCII
        @(Test-IronLawAsciiLauncher -Path $tmp).Count | Should -Be 0
    }

    It 'ignores localized names that are not launchers' {
        $tmp = Join-Path $TestDrive '报告.ps1'
        'Write-Output 1' | Out-File -LiteralPath $tmp -Encoding UTF8
        @(Test-IronLawAsciiLauncher -Path $tmp).Count | Should -Be 0
    }
}

Describe 'Two-directional guarantee' {
    It 'produces zero violations on the compliant fixture' {
        @($script:Good).Count | Should -Be 0
    }

    It 'produces more violations on the violating fixture than on the compliant one' {
        @($script:Bad).Count | Should -BeGreaterThan @($script:Good).Count
    }

    It 'reports accurate line numbers' {
        $withLine = @($script:Bad | Where-Object { $_.Line -gt 0 }).Count
        $withLine | Should -Be @($script:Bad).Count
    }
}
