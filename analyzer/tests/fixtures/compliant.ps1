# 符合铁律的样例 —— 自定义规则应当零违规
$ErrorActionPreference = 'Stop'

function Remove-CacheGood {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Error "delete failed: $($_.Exception.Message)"
        return
    }
    $proc = Start-Process 'cmd.exe' -ArgumentList '/c','echo hi' -PassThru
    if (-not $proc.WaitForExit(60000)) {
        taskkill /F /PID $proc.Id /T
    }
    $svc = Get-Service -Name 'SomeService'
    if ($svc) { sc.exe delete SomeService }
}