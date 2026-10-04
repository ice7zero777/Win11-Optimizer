#Requires -Version 5.1
# IronLaw-Suppress: AvoidForbiddenInlineCommand - this file defines the forbidden patterns
# as string literals, so the checker flags its own rule table. The suppression is scoped to
# this reference copy; the working checker keeps the same literals and is excluded by path
# in ci/Invoke-Analysis.ps1 because it is the tool itself.
<#
.SYNOPSIS
    Custom PSScriptAnalyzer rules enforcing the Win11-Optimizer Iron Laws (PRD section 12).

.DESCRIPTION
    PSScriptAnalyzer's built-in rule set does NOT detect the failure modes that caused real
    incidents in this project (swallowed errors, unbounded blocking calls, protected-path
    writes). These rules close that gap so CI can enforce the Iron Laws mechanically
    instead of relying on reviewer diligence.

    Verified interface contract (PSScriptAnalyzer 1.25.0, Windows PowerShell 5.1):

        interface IRule {
            String       GetName();
            String       GetCommonName();
            String       GetDescription();
            String       GetSourceName();
            SourceType   GetSourceType();     // Builtin | Managed | Module
            RuleSeverity GetSeverity();       // Information | Warning | Error | ParseError
        }
        interface IScriptRule : IRule {
            IEnumerable<DiagnosticRecord> AnalyzeScript(Ast ast, String fileName);
        }

    Rule map:
      L1  AvoidForbiddenCommand            - destructive command families
      L1  AvoidForbiddenPath               - protected user/system paths
      L2  AvoidSilentlyContinueErrorAction - no silent error suppression
      L2  AvoidEmptyCatchBlock             - no bare catch { }
      L3  RequireProcessTimeout            - no unbounded blocking process calls
#>

# ---------------------------------------------------------------------------
# L1 - Forbidden destructive commands
# ---------------------------------------------------------------------------
class AvoidForbiddenCommand : Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.IScriptRule {

    static [string[]] $ForbiddenCmdlets = @(
        'Format-Volume','Clear-Disk','Initialize-Disk','Remove-Partition','Remove-PartitionAccessPath'
    )

    static [string[]] $ForbiddenInline = @(
        'netsh\s+winsock\s+reset',
        'bcdedit[^\r\n]*/delete',
        'net\s+user[^\r\n]*/delete',
        'Set-ExecutionPolicy\s+Unrestricted',
        'vssadmin[^\r\n]*delete\s+shadows'
    )

    [System.Collections.Generic.IEnumerable[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]] AnalyzeScript(
        [System.Management.Automation.Language.Ast]$ast,
        [string]$fileName
    ) {
        $results = New-Object 'System.Collections.Generic.List[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]'
        if ($null -eq $ast) { return $results }

        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmds) {
            $name = $c.GetCommandName()
            if ($null -ne $name -and [AvoidForbiddenCommand]::ForbiddenCmdlets -contains $name) {
                $rec = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
                $rec.Message  = "Iron Law L1: '$name' is a forbidden destructive command. Disk and partition operations are permanently outside this tool's scope."
                $rec.Extent   = $c.Extent
                $rec.RuleName = 'AvoidForbiddenCommand'
                $rec.Severity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error
                $results.Add($rec)
            }
        }

        $strings = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                      $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)
        foreach ($st in $strings) {
            $txt = $st.Extent.Text
            foreach ($pat in [AvoidForbiddenCommand]::ForbiddenInline) {
                if ($txt -match $pat) {
                    $rec = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
                    $rec.Message  = "Iron Law L1: forbidden inline command matched pattern '$pat'. This operation is not permitted by the safety model."
                    $rec.Extent   = $st.Extent
                    $rec.RuleName = 'AvoidForbiddenCommand'
                    $rec.Severity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error
                    $results.Add($rec)
                    break
                }
            }
        }
        return $results
    }

    [string] GetName()        { return 'AvoidForbiddenCommand' }
    [string] GetCommonName()  { return 'Avoid forbidden destructive commands' }
    [string] GetDescription() { return 'Iron Law L1: disk, partition, network-reset and user-deletion command families are permanently out of scope.' }
    [string] GetSourceName()  { return 'Win11Optimizer' }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType] GetSourceType() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType]::Module
    }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity] GetSeverity() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity]::Error
    }
}

# ---------------------------------------------------------------------------
# L1 - Protected user/system paths
# ---------------------------------------------------------------------------
class AvoidForbiddenPath : Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.IScriptRule {

    static [string[]] $Forbidden = @(
        '\$env:USERPROFILE\\Desktop',
        '\$env:USERPROFILE\\Documents',
        '\$env:USERPROFILE\\Downloads',
        '\$env:USERPROFILE\\Pictures',
        '\$env:USERPROFILE\\Videos',
        '\$env:USERPROFILE\\Music',
        'C:\\Windows\\System32',
        'C:\\Windows\\SysWOW64',
        'C:\\Windows\\WinSxS',
        'C:\\Program Files',
        'C:\\Program Files \(x86\)',
        'C:\\Users\\',
        'C:\\System Volume Information',
        'C:\\Recovery'
    )

    [System.Collections.Generic.IEnumerable[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]] AnalyzeScript(
        [System.Management.Automation.Language.Ast]$ast,
        [string]$fileName
    ) {
        $results = New-Object 'System.Collections.Generic.List[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]'
        if ($null -eq $ast) { return $results }

        $strings = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                      $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)

        foreach ($st in $strings) {
            $txt = $st.Extent.Text
            foreach ($pat in [AvoidForbiddenPath]::Forbidden) {
                if ($txt -match $pat) {
                    $rec = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
                    $rec.Message  = "Iron Law L1: protected path matched '$pat'. User data and system directories are never valid optimization targets; use an explicit allow-list of cache paths."
                    $rec.Extent   = $st.Extent
                    $rec.RuleName = 'AvoidForbiddenPath'
                    $rec.Severity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error
                    $results.Add($rec)
                    break
                }
            }
        }
        return $results
    }

    [string] GetName()        { return 'AvoidForbiddenPath' }
    [string] GetCommonName()  { return 'Avoid protected user/system paths' }
    [string] GetDescription() { return 'Iron Law L1: user data directories and system directories must never be deletion or modification targets.' }
    [string] GetSourceName()  { return 'Win11Optimizer' }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType] GetSourceType() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType]::Module
    }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity] GetSeverity() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity]::Error
    }
}

# ---------------------------------------------------------------------------
# L2 - No silent failure
# Source incident: swallowed Remove-Item errors made the tool report success while
# deleting nothing, and an entire iteration was misjudged.
# ---------------------------------------------------------------------------
class AvoidSilentlyContinueErrorAction : Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.IScriptRule {

    [System.Collections.Generic.IEnumerable[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]] AnalyzeScript(
        [System.Management.Automation.Language.Ast]$ast,
        [string]$fileName
    ) {
        $results = New-Object 'System.Collections.Generic.List[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]'
        if ($null -eq $ast) { return $results }

        $predicate = {
            param($node)
            if ($node -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ($node.ParameterName -eq 'ErrorAction' -and $null -ne $node.Argument -and
                    $node.Argument.Extent.Text -match 'SilentlyContinue') { return $true }
            }
            if ($node -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                if ($node.Left.Extent.Text -eq '$ErrorActionPreference' -and
                    $node.Right.Extent.Text -match 'SilentlyContinue') { return $true }
            }
            return $false
        }

        foreach ($node in $ast.FindAll($predicate, $true)) {
            $rec = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
            $rec.Message  = "Iron Law L2: silent failure is forbidden. '-ErrorAction SilentlyContinue' and `$ErrorActionPreference = 'SilentlyContinue' hide errors so failures become invisible. Use try/catch with -ErrorAction Stop and report the failure."
            $rec.Extent   = $node.Extent
            $rec.RuleName = 'AvoidSilentlyContinueErrorAction'
            $rec.Severity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error
            $results.Add($rec)
        }
        return $results
    }

    [string] GetName()        { return 'AvoidSilentlyContinueErrorAction' }
    [string] GetCommonName()  { return 'Avoid silent failure via SilentlyContinue' }
    [string] GetDescription() { return 'Iron Law L2: errors must never be silently discarded; surface them with try/catch and -ErrorAction Stop.' }
    [string] GetSourceName()  { return 'Win11Optimizer' }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType] GetSourceType() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType]::Module
    }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity] GetSeverity() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity]::Error
    }
}

# ---------------------------------------------------------------------------
# L2 - No empty catch block
# ---------------------------------------------------------------------------
class AvoidEmptyCatchBlock : Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.IScriptRule {

    [System.Collections.Generic.IEnumerable[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]] AnalyzeScript(
        [System.Management.Automation.Language.Ast]$ast,
        [string]$fileName
    ) {
        $results = New-Object 'System.Collections.Generic.List[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]'
        if ($null -eq $ast) { return $results }

        $predicate = {
            param($node)
            if ($node -isnot [System.Management.Automation.Language.TryStatementAst]) { return $false }
            if ($null -eq $node.CatchClauses -or $node.CatchClauses.Count -eq 0) { return $false }
            foreach ($c in $node.CatchClauses) {
                if ($null -ne $c.Body -and $null -ne $c.Body.Statements -and $c.Body.Statements.Count -gt 0) {
                    return $false
                }
            }
            return $true
        }

        foreach ($node in $ast.FindAll($predicate, $true)) {
            $rec = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
            $rec.Message  = "Iron Law L2: an empty catch block swallows every exception. Log the error and return a Failed status so the failure stays visible."
            $rec.Extent   = $node.Extent
            $rec.RuleName = 'AvoidEmptyCatchBlock'
            $rec.Severity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error
            $results.Add($rec)
        }
        return $results
    }

    [string] GetName()        { return 'AvoidEmptyCatchBlock' }
    [string] GetCommonName()  { return 'Avoid empty catch block' }
    [string] GetDescription() { return 'Iron Law L2: a catch block must log the failure and surface it, never be empty.' }
    [string] GetSourceName()  { return 'Win11Optimizer' }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType] GetSourceType() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType]::Module
    }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity] GetSeverity() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity]::Error
    }
}

# ---------------------------------------------------------------------------
# L3 - Bounded external process calls
# Source incident: Stop-Service retried forever on a service stuck in Stop Pending,
# flooding the console and hanging the script for 10 minutes.
# ---------------------------------------------------------------------------
class RequireProcessTimeout : Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.IScriptRule {

    [System.Collections.Generic.IEnumerable[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]] AnalyzeScript(
        [System.Management.Automation.Language.Ast]$ast,
        [string]$fileName
    ) {
        $results = New-Object 'System.Collections.Generic.List[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]'
        if ($null -eq $ast) { return $results }

        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmds) {
            $name = $c.GetCommandName()
            if ($null -eq $name) { continue }

            if ($name -match '^(Stop-Service|Restart-Service)$') {
                $rec = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
                $rec.Message  = "Iron Law L3: '$name' can retry indefinitely against a service that is not transitioning (real incident: a service stuck in Stop Pending hung the script for 10 minutes). Use 'sc.exe query' / 'sc.exe delete', or wrap it in a bounded wait."
                $rec.Extent   = $c.Extent
                $rec.RuleName = 'RequireProcessTimeout'
                $rec.Severity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error
                $results.Add($rec)
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
                    $rec = New-Object 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
                    $rec.Message  = "Iron Law L3: 'Start-Process -Wait' is unbounded and can block forever. Use -PassThru plus WaitForExit(<ms>) and force-kill on timeout."
                    $rec.Extent   = $c.Extent
                    $rec.RuleName = 'RequireProcessTimeout'
                    $rec.Severity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error
                    $results.Add($rec)
                }
            }
        }
        return $results
    }

    [string] GetName()        { return 'RequireProcessTimeout' }
    [string] GetCommonName()  { return 'Require a timeout on blocking process calls' }
    [string] GetDescription() { return 'Iron Law L3: every external process call must be bounded; blocking service cmdlets must not target services that may be stuck.' }
    [string] GetSourceName()  { return 'Win11Optimizer' }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType] GetSourceType() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.SourceType]::Module
    }
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity] GetSeverity() {
        return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.RuleSeverity]::Error
    }
}