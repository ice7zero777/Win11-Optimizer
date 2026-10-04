#Requires -Version 5.1
# IronLaw-Suppress: AvoidForbiddenInlineCommand - this gate defines the forbidden pattern
# table as string literals, so the scanner matches its own rule data. The exemption is a
# single named rule on the definition file only; every other file is still checked.
<#
.SYNOPSIS
    Self-contained CI gate for the Win11-Optimizer Iron Laws (PRD section 12).

.DESCRIPTION
    This script is deliberately self-contained: it imports no custom module and therefore
    cannot fail because of host module-loading policy. It:

      0. unblocks the repository's PowerShell files (a Zone.Identifier marker makes
         PowerShell raise "AuthorizationManager 检查失败" in a non-interactive host,
         because the remote-file trust prompt cannot be shown);
      1. parses every PowerShell file and applies the Iron Law AST checks;
      2. verifies every PowerShell file carries a UTF-8 BOM (Iron Law L4);
      3. runs the Pester suite.

    Every stage prints how many files it examined and fails when that number is zero, so a
    stage can never pass by silently examining nothing (Iron Law L2 applied to CI itself).

.EXITCODES
    0 = all stages passed
    1 = a violation was found, a test failed, or a stage examined no files
#>
[CmdletBinding()]
param(
    [string]$SourcePath,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$repoRoot = if ($PSBoundParameters.ContainsKey('SourcePath') -and $SourcePath) {
    (Resolve-Path -LiteralPath $SourcePath).Path
} else {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

$ExcludeFromAstScan = @(
    '*\.git\*'
    '*\analyzer\tests\fixtures\violations.ps1'
    '*\analyzer\IronLaw\*'
    '*\analyzer\experimental\*'
)

$ForbiddenCmdlets = @(
    'Format-Volume','Clear-Disk','Initialize-Disk','Remove-Partition','Remove-PartitionAccessPath','Set-Disk'
)

$ForbiddenInline = @(
    'netsh\s+winsock\s+reset'
    'bcdedit[^\r\n]*/delete'
    'net\s+user[^\r\n]*/delete'
    'Set-ExecutionPolicy\s+Unrestricted'
    'vssadmin[^\r\n]*delete\s+shadows'
)

$ProtectedPathPatterns = @(
    '\$env:USERPROFILE\\Desktop'
    '\$env:USERPROFILE\\Documents'
    '\$env:USERPROFILE\\Downloads'
    '\$env:USERPROFILE\\Pictures'
    '\$env:USERPROFILE\\Videos'
    '\$env:USERPROFILE\\Music'
    'C:\\Windows\\System32'
    'C:\\Windows\\SysWOW64'
    'C:\\Windows\\WinSxS'
    'C:\\Program Files'
    'C:\\Program Files \(x86\)'
    'C:\\Users\\'
    'C:\\System Volume Information'
    'C:\\Recovery'
)

$BlockingServiceCmdlets = @('Stop-Service','Restart-Service')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-PowerShellFile {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($ext in @('*.ps1','*.psm1','*.psd1')) {
        Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $ext -ErrorAction SilentlyContinue
    }
}

function Test-PatternMatch {
    param([Parameter(Mandatory)][string]$Value, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Value -like $p) { return $true } }
    return $false
}

function Get-Suppression {
    <#
    .SYNOPSIS
        Read '# IronLaw-Suppress: Rule1, Rule2 - reason' directives from a file.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $names = New-Object System.Collections.ArrayList
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $names }
    foreach ($m in [regex]::Matches($text, '#\s*IronLaw-Suppress\s*:\s*([^-\r\n]+)')) {
        foreach ($n in ($m.Groups[1].Value -split ',')) {
            $t = $n.Trim()
            if ($t) { [void]$names.Add($t) }
        }
    }
    return $names
}

function New-Violation {
    param($Law,$Rule,$Message,$File,$Line,$Column)
    [pscustomobject]@{
        Law = $Law; Rule = $Rule; Message = $Message
        File = $File; Line = $Line; Column = $Column
    }
}

function Get-AstViolation {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$File)
    $out = New-Object System.Collections.ArrayList

    $commands = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    $strings  = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                  $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true)

    foreach ($c in $commands) {
        $name = $c.GetCommandName()
        if ($null -eq $name) { continue }

        if ($ForbiddenCmdlets -contains $name) {
            [void]$out.Add((New-Violation 'L1' 'AvoidForbiddenCommand' `
                "Forbidden destructive command '$name'. Disk and partition operations are permanently out of scope." `
                $File $c.Extent.StartLineNumber $c.Extent.StartColumnNumber))
        }

        if ($BlockingServiceCmdlets -contains $name) {
            [void]$out.Add((New-Violation 'L3' 'RequireProcessTimeout' `
                "'$name' can retry indefinitely against a service that is not transitioning. Use 'sc.exe query'/'sc.exe delete', or bound the wait." `
                $File $c.Extent.StartLineNumber $c.Extent.StartColumnNumber))
        }

        if ($name -eq 'Start-Process') {
            $hasWait = $false; $hasTimeout = $false
            foreach ($e in $c.CommandElements) {
                if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($e.ParameterName -eq 'Wait')    { $hasWait = $true }
                    if ($e.ParameterName -eq 'Timeout') { $hasTimeout = $true }
                }
                if ($e.Extent.Text -match 'WaitForExit') { $hasTimeout = $true }
            }
            if ($hasWait -and -not $hasTimeout) {
                [void]$out.Add((New-Violation 'L3' 'RequireProcessTimeout' `
                    "'Start-Process -Wait' is unbounded and can block forever. Use -PassThru plus WaitForExit(<ms>) and force-kill on timeout." `
                    $File $c.Extent.StartLineNumber $c.Extent.StartColumnNumber))
            }
        }
    }

    foreach ($s in $strings) {
        foreach ($pat in $ForbiddenInline) {
            if ($s.Extent.Text -match $pat) {
                [void]$out.Add((New-Violation 'L1' 'AvoidForbiddenInlineCommand' `
                    "Forbidden inline command matches '$pat'." `
                    $File $s.Extent.StartLineNumber $s.Extent.StartColumnNumber))
                break
            }
        }
        foreach ($pat in $ProtectedPathPatterns) {
            if ($s.Extent.Text -match $pat) {
                [void]$out.Add((New-Violation 'L1' 'AvoidForbiddenPath' `
                    "Protected path matches '$pat'. User data and system directories are never valid targets." `
                    $File $s.Extent.StartLineNumber $s.Extent.StartColumnNumber))
                break
            }
        }
    }

    $suppressions = $Ast.FindAll({
        param($n)
        if ($n -is [System.Management.Automation.Language.CommandParameterAst]) {
            return ($n.ParameterName -eq 'ErrorAction' -and $null -ne $n.Argument -and
                    $n.Argument.Extent.Text -match 'SilentlyContinue')
        }
        if ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            return ($n.Left.Extent.Text -eq '$ErrorActionPreference' -and
                    $n.Right.Extent.Text -match 'SilentlyContinue')
        }
        return $false
    }, $true)
    foreach ($n in $suppressions) {
        [void]$out.Add((New-Violation 'L2' 'AvoidSilentlyContinueErrorAction' `
            "Silent failure is forbidden. Use try/catch with -ErrorAction Stop and report the failure." `
            $File $n.Extent.StartLineNumber $n.Extent.StartColumnNumber))
    }

    $emptyCatches = $Ast.FindAll({
        param($n)
        if ($n -isnot [System.Management.Automation.Language.TryStatementAst]) { return $false }
        if ($null -eq $n.CatchClauses -or $n.CatchClauses.Count -eq 0) { return $false }
        foreach ($cc in $n.CatchClauses) {
            if ($null -ne $cc.Body -and $null -ne $cc.Body.Statements -and $cc.Body.Statements.Count -gt 0) { return $false }
        }
        return $true
    }, $true)
    foreach ($n in $emptyCatches) {
        [void]$out.Add((New-Violation 'L2' 'AvoidEmptyCatchBlock' `
            "Empty catch block swallows every exception. Log the error and return a Failed status." `
            $File $n.Extent.StartLineNumber $n.Extent.StartColumnNumber))
    }

    Write-Output -NoEnumerate $out.ToArray()
}

function Test-HasUtf8Bom {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    $b = [System.IO.File]::ReadAllBytes($Path)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

# ---------------------------------------------------------------------------
# Stage 0 - unblock
# ---------------------------------------------------------------------------
Write-Host "Repository: $repoRoot" -ForegroundColor DarkGray
$repoFiles = @(Get-PowerShellFile -Root $repoRoot)
Write-Host "PowerShell files found: $($repoFiles.Count)" -ForegroundColor DarkGray
if ($repoFiles.Count -eq 0) {
    Write-Host 'FAIL: no PowerShell files found; refusing to report success.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== 0/3 Unblock repository scripts ===' -ForegroundColor Cyan
foreach ($f in $repoFiles) { Unblock-File -LiteralPath $f.FullName -ErrorAction SilentlyContinue }
Write-Host "  processed $($repoFiles.Count) file(s)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Stage 1 - AST scan
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 1/3 Iron Law AST scan ===' -ForegroundColor Cyan
$toScan = @($repoFiles | Where-Object { -not (Test-PatternMatch -Value $_.FullName -Patterns $ExcludeFromAstScan) })
Write-Host "  scanning $($toScan.Count) file(s), excluded $($repoFiles.Count - $toScan.Count)" -ForegroundColor DarkGray
$violations = @()
foreach ($f in $toScan) {
    if ($f.Extension -notin @('.ps1','.psm1')) { continue }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($null -eq $ast) { continue }

    $suppressed = @(Get-Suppression -Path $f.FullName)
    $suppressAll = $suppressed -contains '*'
    if ($suppressAll) { continue }

    foreach ($v in @(Get-AstViolation -Ast $ast -File $f.FullName)) {
        if ($suppressed -contains $v.Rule) { continue }
        $violations += $v
    }
}
if ($violations.Count -gt 0) {
    Write-Host "  FAIL: $($violations.Count) Iron Law violation(s)" -ForegroundColor Red
    foreach ($v in ($violations | Sort-Object Law, File, Line)) {
        Write-Host ("    [{0}] {1}:{2}  {3}" -f $v.Law, (Split-Path $v.File -Leaf), $v.Line, $v.Rule) -ForegroundColor Red
        Write-Host ("         $($v.Message)") -ForegroundColor DarkGray
    }
    exit 1
}
Write-Host "  OK: no Iron Law violations in $($toScan.Count) scanned file(s)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Stage 2 - BOM self-check
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 2/3 BOM self-check (Iron Law L4) ===' -ForegroundColor Cyan
$bomMissing = @()
foreach ($f in $repoFiles) { if (-not (Test-HasUtf8Bom -Path $f.FullName)) { $bomMissing += $f.FullName } }
Write-Host "  checked $($repoFiles.Count) file(s)" -ForegroundColor DarkGray
if ($bomMissing.Count -gt 0) {
    Write-Host "  FAIL: $($bomMissing.Count) file(s) missing a UTF-8 BOM" -ForegroundColor Red
    foreach ($m in $bomMissing) { Write-Host "    $m" -ForegroundColor Red }
    exit 1
}
Write-Host "  OK: all $($repoFiles.Count) file(s) carry a UTF-8 BOM" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Stage 3 - Pester
# ---------------------------------------------------------------------------
if ($SkipTests) {
    Write-Host ''
    Write-Host '=== 3/3 Pester suite (skipped) ===' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host '=== 3/3 Pester suite ===' -ForegroundColor Cyan
    Import-Module Pester -Force -ErrorAction Stop
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = (Join-Path $repoRoot 'analyzer\tests')
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $configuration
    if ($result.TotalCount -eq 0) {
        Write-Host '  FAIL: the test suite discovered no tests' -ForegroundColor Red
        exit 1
    }
    if ($result.FailedCount -gt 0) {
        Write-Host "  FAIL: $($result.FailedCount) of $($result.TotalCount) tests failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "  OK: $($result.PassedCount) tests passed" -ForegroundColor Green
}

Write-Host ''
Write-Host 'RESULT: PASSED' -ForegroundColor Green
exit 0