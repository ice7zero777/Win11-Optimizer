# 故意违反铁律的样例 —— 自定义规则必须全部检出
$ErrorActionPreference = 'SilentlyContinue'                    # L2

function Remove-CacheBad {
    param([string]$Path)
    Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue   # L2
    try { Remove-Item $Path -Force } catch { }                        # L2 空catch
    Start-Process 'cmd.exe' -ArgumentList '/c','echo hi' -Wait        # L3
    Stop-Service -Name 'SomeService' -Force                           # L3
}

# L1 危险命令
Format-Volume -DriveLetter D
Clear-Disk -Number 1

# L1 禁止路径
$danger = "$env:USERPROFILE\Desktop\重要文件"
$danger2 = 'C:\Windows\System32\config'
Get-ChildItem 'C:\Users' | Remove-Item -Recurse -Force

# L1 内联危险命令
$inline = 'netsh winsock reset'
$inline2 = 'bcdedit /delete {current}'