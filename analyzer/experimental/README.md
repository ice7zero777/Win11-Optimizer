# Experimental: PSScriptAnalyzer custom-rule route (NOT WORKING)

**Status: non-functional in the development environment. Kept for reference and future work.**

## What this was

An attempt to express the Iron Laws as PSScriptAnalyzer custom rules (classes implementing
`IScriptRule`), so that `Invoke-ScriptAnalyzer -CustomRulePath` would report them alongside the
75 built-in rules.

## The verified interface contract

The contract was reverse-engineered from the installed PSScriptAnalyzer 1.25.0 assemblies
rather than from documentation:

```csharp
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
```

Note two traps that cost real time:

1. `IScriptRule` inherits `IRule`, so `GetSourceType()` and `GetSeverity()` are mandatory even
   though a first look at `IScriptRule.GetMethods()` shows only `AnalyzeScript`.
2. `GetSeverity()` returns `RuleSeverity`, **not** `DiagnosticSeverity`. `DiagnosticRecord.Severity`
   does take `DiagnosticSeverity`; the rule's own `GetSeverity()` does not.

Implementing both correctly is not sufficient in this environment, however:

```
创建类型"AvoidForbiddenCommand"的过程中出错。
方法"GetSourceType"没有实现。        <- before the fix
```
```
Import-Module : AuthorizationManager 检查失败。   <- after the fix
```

The remaining failure is a Windows PowerShell 5.1 class-loading interaction: the module defines
`IScriptRule` implementations whose base types live in `Microsoft.Windows.PowerShell.ScriptAnalyzer.dll`,
and PowerShell compiles the module's class definitions before that assembly is resolvable in the
loading session. `Get-ScriptAnalyzerRule -CustomRulePath` consequently reports
`Cannot find ScriptAnalyzer rules in the specified path` while the 75 built-in rules keep working.

## What replaced it

`analyzer/IronLaw/IronLaw.Checker.psm1` implements the same Iron Law analysis directly over the
PowerShell AST with ordinary functions. It has no external type dependency, loads reliably on
PowerShell 5.1, and is covered by 21 Pester tests (see `analyzer/tests/`).

## If you want to revive this route

Things worth trying, in order:

1. Test on **PowerShell 7.x**, where class-based custom rules are the supported path.
2. Add `RequiredAssemblies = 'Microsoft.Windows.PowerShell.ScriptAnalyzer.dll'` to the module manifest
   so the assembly loads before class compilation.
3. Ship the rules as a compiled .NET assembly (the built-in rules already are one).
4. Confirm on a machine where the module path is short and the files carry no `Zone.Identifier`
   marker; both were confounding variables during diagnosis.