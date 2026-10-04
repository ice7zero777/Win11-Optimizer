#Requires -Version 5.1
<#
.SYNOPSIS
    AST-based Iron Law checker for the Win11-Optimizer project (PRD section 12).

.DESCRIPTION
    Enforces the project's architectural Iron Laws mechanically so CI can reject
    violations instead of relying on reviewer diligence.

    This is implemented over System.Management.Automation.Language (the PowerShell
    AST) with plain functions rather than PSScriptAnalyzer custom classes, because
    class-based PSScriptAnalyzer rules could not be discovered reliably on
    Windows PowerShell 5.1 in the development environment. The AST work is identical.

    Iron Law coverage:
      L1  Test-IronLawWhiteList        - no protection-bypassing deletion/format cmdlets
      L1  Test-IronLawProtectedPath    - no protected user/system paths as targets
      L2  Test-IronLawSilentFailure    - no -ErrorAction SilentlyContinue / empty catch
      L3  Test-IronLawProcessTimeout   - no unbounded blocking process/service calls
      L4  Test-IronLawUtf8Bom          - .ps1 files carry a UTF-8 BOM
      L5  Test-IronLawAsciiLauncher    - launcher scripts use ASCII-only file names
#>

Set-StrictMode -Version Latest

# Paths that must never appear as a deletion or modification target (Iron Law L1).
$script:ProtectedPathPatterns = @(
    '\$env:USERPROFILE\\Desktop'
    '\$env:USERPROFILE\\Documents'
    '\$env:USERPROFILE\\Downloads'
    '\$env:USERPROFILE\\Pictures'
    '\$env:USERPROFILE\\Videos'
    '\$env:USERPROFILE\\Music'
    'C:\\Windows\\System32'
    'C:\\Windows\\SysWOW64'
    'C:\\Windows\\WinSxS'
    'C:\\Program Files\\'
    'C:\\Program Files \(x86\)'
    'C:\\Users\\'
    'C:\\System Volume Information'
    'C:\\Recovery'
    'C:\\\$Recycle\.Bin'
)

# Cmdlet families that are permanently out of scope (Iron Law L1).
$script:ForbiddenCmdlets = @(
    'Format-Volume'
    'Clear-Disk'
    'Initialize-Disk'
    'Remove-Partition'
    'Remove-PartitionAccessPath'
    'Set-Disk'
)

# Inline command lines that must never be constructed (Iron Law L1).
$script:ForbiddenInline = @(
    'netsh\s+winsock\s+reset'
    'bcdedit[^\r\n]*/delete'
    'net\s+user[^\r\n]*/delete'
    'Set-ExecutionPolicy\s+Unrestricted'
    'vssadmin[^\r\n]*delete\s+shadows'
)

# Blocking calls that can hang forever (Iron Law L3).
$script:BlockingServiceCmdlets = @('Stop-Service', 'Restart-Service')

function Get-IronLawDiagnostic {
    <#
    .SYNOPSIS
        Build one violation record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Law,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int]$Line,
        [Parameter(Mandatory)][int]$Column,
        [string]$Severity = 'Error'
    )
    [pscustomobject]@{
        Law      = $Law
        Rule     = $Rule
        Severity = $Severity
        Message  = $Message
        File     = $File
        Line     = $Line
        Column   = $Column
    }
}

function Test-IronLawWhiteList {
    <#
    .SYNOPSIS
        L1: forbid protection-bypassing destructive cmdlets and inline command lines.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$File = '')

    $out = New-Object System.Collections.ArrayList

    foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if ($null -ne $name -and $script:ForbiddenCmdlets -contains $name) {
            [void]$out.Add((Get-IronLawDiagnostic -Law 'L1' -Rule 'AvoidForbiddenCommand' `
                -Message "Forbidden destructive command '$name'. Disk and partition operations are permanently out of scope." `
                -File $File -Line $c.Extent.StartLineNumber -Column $c.Extent.StartColumnNumber))
        }
    }

    foreach ($s in $Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                      $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)) {
        foreach ($pat in $script:ForbiddenInline) {
            if ($s.Extent.Text -match $pat) {
                [void]$out.Add((Get-IronLawDiagnostic -Law 'L1' -Rule 'AvoidForbiddenInlineCommand' `
                    -Message "Forbidden inline command matches '$pat'. The safety model does not permit constructing this command." `
                    -File $File -Line $s.Extent.StartLineNumber -Column $s.Extent.StartColumnNumber))
                break
            }
        }
    }
    foreach ($item in $out) { $item }
}

function Test-IronLawProtectedPath {
    <#
    .SYNOPSIS
        L1: forbid protected user/system paths as string targets.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$File = '')

    $out = New-Object System.Collections.ArrayList
    foreach ($s in $Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                      $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)) {
        foreach ($pat in $script:ProtectedPathPatterns) {
            if ($s.Extent.Text -match $pat) {
                [void]$out.Add((Get-IronLawDiagnostic -Law 'L1' -Rule 'AvoidForbiddenPath' `
                    -Message "Protected path matches '$pat'. User data and system directories are never valid targets; use an explicit allow-list of cache paths." `
                    -File $File -Line $s.Extent.StartLineNumber -Column $s.Extent.StartColumnNumber))
                break
            }
        }
    }
    foreach ($item in $out) { $item }
}

function Test-IronLawSilentFailure {
    <#
    .SYNOPSIS
        L2: forbid silent error suppression and empty catch blocks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$File = '')

    $out = New-Object System.Collections.ArrayList

    $suppress = $Ast.FindAll({
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

    foreach ($n in $suppress) {
        [void]$out.Add((Get-IronLawDiagnostic -Law 'L2' -Rule 'AvoidSilentlyContinueErrorAction' `
            -Message "Silent failure is forbidden. Use try/catch with -ErrorAction Stop and report the failure to the caller." `
            -File $File -Line $n.Extent.StartLineNumber -Column $n.Extent.StartColumnNumber))
    }

    $emptyCatch = $Ast.FindAll({
            param($n)
            if ($n -isnot [System.Management.Automation.Language.TryStatementAst]) { return $false }
            if ($null -eq $n.CatchClauses -or $n.CatchClauses.Count -eq 0) { return $false }
            foreach ($c in $n.CatchClauses) {
                if ($null -ne $c.Body -and $null -ne $c.Body.Statements -and $c.Body.Statements.Count -gt 0) { return $false }
            }
            return $true
        }, $true)

    foreach ($n in $emptyCatch) {
        [void]$out.Add((Get-IronLawDiagnostic -Law 'L2' -Rule 'AvoidEmptyCatchBlock' `
            -Message "Empty catch block swallows every exception. Log the error and return a Failed status." `
            -File $File -Line $n.Extent.StartLineNumber -Column $n.Extent.StartColumnNumber))
    }
    foreach ($item in $out) { $item }
}

function Test-IronLawProcessTimeout {
    <#
    .SYNOPSIS
        L3: forbid unbounded blocking process and service calls.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$File = '')

    $out = New-Object System.Collections.ArrayList
    foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if ($null -eq $name) { continue }

        if ($script:BlockingServiceCmdlets -contains $name) {
            [void]$out.Add((Get-IronLawDiagnostic -Law 'L3' -Rule 'RequireProcessTimeout' `
                -Message "'$name' can retry indefinitely against a service that is not transitioning. Use 'sc.exe query'/'sc.exe delete' or bound the wait." `
                -File $File -Line $c.Extent.StartLineNumber -Column $c.Extent.StartColumnNumber))
            continue
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
                [void]$out.Add((Get-IronLawDiagnostic -Law 'L3' -Rule 'RequireProcessTimeout' `
                    -Message "'Start-Process -Wait' is unbounded and can block forever. Use -PassThru plus WaitForExit(<ms>) and force-kill on timeout." `
                    -File $File -Line $c.Extent.StartLineNumber -Column $c.Extent.StartColumnNumber))
            }
        }
    }
    foreach ($item in $out) { $item }
}

function Test-IronLawUtf8Bom {
    <#
    .SYNOPSIS
        L4: every .ps1/.psm1/.psd1 must start with a UTF-8 BOM.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $out }
    if ((Get-Item -LiteralPath $Path).Extension -notin @('.ps1', '.psm1', '.psd1')) { return $out }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if (-not $hasBom) {
        [void]$out.Add((Get-IronLawDiagnostic -Law 'L4' -Rule 'RequireUtf8Bom' `
            -Message "Missing UTF-8 BOM. Windows PowerShell 5.1 parses BOM-less files as ANSI, which corrupts non-ASCII text and produces bogus syntax errors." `
            -File $Path -Line 1 -Column 1))
    }
    foreach ($item in $out) { $item }
}

function Test-IronLawAsciiLauncher {
    <#
    .SYNOPSIS
        L5: elevation launchers must use ASCII-only file names.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $out = New-Object System.Collections.ArrayList
    $name = Split-Path -Leaf $Path
    if ($name -notmatch '\.(cmd|bat|ps1)$') { return $out }

    # Only launcher-looking names are checked, so ordinary scripts with localized
    # names do not trip this rule.
    if ($name -notmatch 'launch|start|boot|entry|run') { return $out }

    if ($name -match '[^\x00-\x7F]') {
        [void]$out.Add((Get-IronLawDiagnostic -Law 'L5' -Rule 'AvoidNonAsciiLauncherName' `
            -Message "Launcher file name '$name' contains non-ASCII characters. cmd.exe->PowerShell parameter passing corrupts such paths and the launcher silently fails to elevate." `
            -File $Path -Line 1 -Column 1))
    }
    foreach ($item in $out) { $item }
}

function Get-IronLawSuppression {
    <#
    .SYNOPSIS
        Read per-file suppression directives from a source file.

    .DESCRIPTION
        A file may declare exceptions with lines of the form:

            # IronLaw-Suppress: RuleName1, RuleName2 - reason this is intentional
            # IronLaw-Suppress: * - this file documents the forbidden patterns themselves

        Suppression is deliberately explicit and greppable. It exists so that a
        legitimately non-compliant reference file can be committed without weakening the
        gate for every other file, which is what a blanket directory exclusion would do.

    .OUTPUTS
        A list of suppressed rule names; '*' means every rule.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $suppressed = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $suppressed }
    if ((Get-Item -LiteralPath $Path).Length -gt 5MB) { return $suppressed }

    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $suppressed }

    foreach ($m in [regex]::Matches($text, '#\s*IronLaw-Suppress\s*:\s*([^-\r\n]+)')) {
        foreach ($name in ($m.Groups[1].Value -split ',')) {
            $trimmed = $name.Trim()
            if ($trimmed) { [void]$suppressed.Add($trimmed) }
        }
    }
    return $suppressed
}

function Invoke-IronLawCheck {
    <#
    .SYNOPSIS
        Run every Iron Law check over one file or a directory tree.

    .OUTPUTS
        An array of violation records; empty means compliant. The result is returned
        without enumeration, so callers take .Count directly and must NOT wrap it in @(),
        which would nest the array and report 1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Exclude = @()
    )

    $all = New-Object System.Collections.ArrayList
    $files = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $files = @(Get-Item -LiteralPath $Path)
    } else {
        # -Include only matches when the path contains a wildcard, so filter per extension.
        foreach ($ext in @('*.ps1', '*.psm1', '*.psd1')) {
            $files += @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter $ext -ErrorAction SilentlyContinue)
        }
    }

    foreach ($f in $files) {
        $skip = $false
        foreach ($ex in $Exclude) { if ($f.FullName -like $ex) { $skip = $true; break } }
        if ($skip) { continue }

        $suppressed = @(Get-IronLawSuppression -Path $f.FullName)
        $suppressAll = $suppressed -contains '*'
        $keep = {
            param($d)
            return -not $suppressAll -and -not ($suppressed -contains $d.Rule)
        }

        # L4 / L5 work on bytes and names, not the AST.
        foreach ($d in (Test-IronLawUtf8Bom -Path $f.FullName)) { if (& $keep $d) { [void]$all.Add($d) } }
        foreach ($d in (Test-IronLawAsciiLauncher -Path $f.FullName)) { if (& $keep $d) { [void]$all.Add($d) } }

        # Parse once, then run every AST-based law.
        if ($f.Extension -in @('.ps1', '.psm1')) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            if ($null -eq $ast) { continue }

            foreach ($d in (Test-IronLawWhiteList      -Ast $ast -File $f.FullName)) { if (& $keep $d) { [void]$all.Add($d) } }
            foreach ($d in (Test-IronLawProtectedPath  -Ast $ast -File $f.FullName)) { if (& $keep $d) { [void]$all.Add($d) } }
            foreach ($d in (Test-IronLawSilentFailure  -Ast $ast -File $f.FullName)) { if (& $keep $d) { [void]$all.Add($d) } }
            foreach ($d in (Test-IronLawProcessTimeout -Ast $ast -File $f.FullName)) { if (& $keep $d) { [void]$all.Add($d) } }
        }
    }
    Write-Output -NoEnumerate $all.ToArray()
}

Export-ModuleMember -Function @(
    'Invoke-IronLawCheck'
    'Get-IronLawSuppression'
    'Test-IronLawWhiteList'
    'Test-IronLawProtectedPath'
    'Test-IronLawSilentFailure'
    'Test-IronLawProcessTimeout'
    'Test-IronLawUtf8Bom'
    'Test-IronLawAsciiLauncher'
)