@{
    RootModule        = 'Win11OptimizerRules.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a7c3e9f1-2b4d-4e8a-9c1f-6d5b3a2e8f47'
    Author            = 'Win11-Optimizer Project'
    CompanyName       = 'community'
    Copyright         = '(c) Win11-Optimizer contributors. MIT License.'
    Description       = 'Custom PSScriptAnalyzer rules enforcing the Win11-Optimizer Iron Laws (PRD section 12).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @()
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('PSScriptAnalyzer','Rule','Lint','Safety','Windows')
            ReleaseNotes = 'Initial rule set: L1 path/command guard, L2 silent-failure guard, L3 process timeout guard.'
        }
    }
}