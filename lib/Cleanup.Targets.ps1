#Requires -Version 5.1
<#
.SYNOPSIS
    清理白名单：定义允许"隔离"的缓存目标，并强制校验路径（铁律 L1）。

.DESCRIPTION
    这是整个清理功能的安全地基。三条硬规则：

    1. **白名单，绝不用排除法**：只有本文件 $script:CleanupTargets 里逐条列出的路径
       才可能被触碰。任何不在白名单里的路径一律拒绝执行，不做任何"排除掉重要的、剩下都删"。
    2. **白名单写在代码里，不放在用户可编辑的配置文件里**。用户改不了自己的安全边界。
    3. **保护路径二次拦截**：即使白名单写错，Test-CleanupPathAllowed 也会先把用户数据目录
       与系统目录挡掉（双层保护）。

    所有清理目标都属于"删掉后系统或软件会自动重建"的缓存类，不含任何用户数据。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
#>

Set-StrictMode -Version Latest

# 受保护的路径模式：任何清理目标落在这些位置一律拒绝（双层保护，与 Iron Law L1 一致）。
# 这里只放目录名关键词，配合下方的"白名单命中"双重判断。
$script:ProtectedPathPatterns = @(
    'Desktop'
    'Documents'
    'Downloads'
    'Pictures'
    'Videos'
    'Music'
    'OneDrive'
    'System32'
    'SysWOW64'
    'WinSxS'
    'Program Files'
    'ProgramData\\Microsoft'
    'System Volume Information'
    'Recovery'
    'AppData\\Roaming'
)

function Get-CleanupTarget {
    <#
    .SYNOPSIS
        返回清理白名单。每一项都要给出"删了会怎样"的白话说明。

    .OUTPUTS
        @(
          @{
            Id        = 'temp.user'
            Name      = '当前用户的临时文件'
            Paths     = @(...)          # 允许清理的目录（逐条列出，支持 %ENV% 变量）
            MinBytes  = 1MB             # 小于这个体积就不值得提示，避免打扰
            Safety    = '这些文件是程序运行时的临时产物…'
          }
        )
    #>
    [CmdletBinding()]
    param()

    $localAppData = [System.Environment]::GetFolderPath('LocalApplicationData')
    $tempPath = [System.IO.Path]::GetTempPath()
    $windir = $env:WINDIR

    $targets = New-Object System.Collections.ArrayList

    # --- 1. 当前用户临时目录 -------------------------------------------------
    [void]$targets.Add(@{
        Id       = 'temp.user'
        Name     = '当前用户临时文件'
        Paths    = @($tempPath.TrimEnd('\'))
        MinBytes = 50MB
        Safety   = '程序运行过程中产生的临时文件。正在运行的程序可能会占用其中一部分，因此被占用的文件会被跳过；删掉后不影响任何已安装的软件。'
    })

    # --- 2. 显卡着色器缓存 ---------------------------------------------------
    $shaderPaths = New-Object System.Collections.ArrayList
    foreach ($relative in @(
            'NVIDIA\DXCache'
            'NVIDIA\GLCache'
            'NVIDIA\ComputeCache'
            'AMD\DxCache'
            'AMD\DxcCache'
            'AMD\GLCache'
            'D3DSCache'
        )) {
        [void]$shaderPaths.Add((Join-Path $localAppData $relative))
    }
    [void]$targets.Add(@{
        Id       = 'cache.shader'
        Name     = '显卡着色器缓存'
        Paths    = $shaderPaths.ToArray()
        MinBytes = 100MB
        Safety   = '显卡驱动自动生成的编译缓存。删掉后驱动会在你下次玩游戏时自动重建，首次进入游戏可能慢几秒，之后恢复正常。'
    })

    # --- 3. Windows 更新缓存 ------------------------------------------------
    if ($windir) {
        [void]$targets.Add(@{
            Id       = 'cache.windowsupdate'
            Name     = 'Windows 更新下载缓存'
            Paths    = @((Join-Path $windir 'SoftwareDistribution\Download'))
            MinBytes = 50MB
            Safety   = 'Windows 更新下载完成后残留的安装包。清理它不会影响已安装的更新，只是以后需要重新下载更新。建议在"没有正在进行的更新"时清理。'
        })
    }

    # --- 4. 开发工具包缓存 ---------------------------------------------------
    $devCachePaths = New-Object System.Collections.ArrayList
    foreach ($relative in @('pip\Cache', 'npm-cache')) {
        [void]$devCachePaths.Add((Join-Path $localAppData $relative))
    }
    $userProfile = [System.Environment]::GetFolderPath('UserProfile')
    [void]$devCachePaths.Add((Join-Path $userProfile '.cache\pip'))
    [void]$targets.Add(@{
        Id       = 'cache.devpackages'
        Name     = '开发工具包缓存（pip / npm）'
        Paths    = $devCachePaths.ToArray()
        MinBytes = 50MB
        Safety   = 'Python 与 Node.js 下载过的依赖包副本。清理后下次安装同样的包需要重新联网下载，已安装的环境不受影响。'
    })

    # --- 5. 缩略图缓存 -------------------------------------------------------
    if ($localAppData) {
        $explorerCache = Join-Path $localAppData 'Microsoft\Windows\Explorer'
        [void]$targets.Add(@{
            Id       = 'cache.thumbnail'
            Name     = '资源管理器缩略图缓存'
            Paths    = @($explorerCache)
            MinBytes = 20MB
            Safety   = '资源管理器为图片和视频生成的缩略图缓存。清理后首次浏览文件夹时缩略图会重新生成，可能短暂变慢。'
            Patterns = @('thumbcache_*.db', 'iconcache_*.db')
        })
    }

    return $targets.ToArray()
}

function Get-NormalizedPath {
    <#
    .SYNOPSIS
        把路径规范化为可用于比较的绝对长路径。

    .DESCRIPTION
        三件事：展开环境变量、转绝对路径、把 8.3 短名（例如 ALIENW~1）还原成长名。
        短名还原不能省：实测 [System.IO.Path]::GetTempPath() 返回的是短名形式
        C:\Users\ALIENW~1\AppData\Local\Temp\，而白名单里是长名 C:\Users\ALIENWARE\...，
        直接做字符串比较会把白名单内的路径判成"不在白名单内"。

        短名还原通过 Win32 GetLongPathName 完成。取不到就退回原路径——
        此时比较可能失败，所以宁可判"不在白名单内"（拒绝执行），也不放过。
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    try {
        $full = [System.IO.Path]::GetFullPath($expanded)
    } catch {
        return ''
    }

    try {
        if (-not ('Win32PathHelper' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Win32PathHelper {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetLongPathNameW(string lpszShortPath, StringBuilder lpszLongPath, uint cchBuffer);

    public static string GetLongPath(string shortPath) {
        if (string.IsNullOrEmpty(shortPath)) { return shortPath; }
        StringBuilder buffer = new StringBuilder(1024);
        uint length = GetLongPathNameW(shortPath, buffer, (uint)buffer.Capacity);
        if (length == 0) { return shortPath; }
        if (length > buffer.Capacity) {
            buffer = new StringBuilder((int)length + 1);
            length = GetLongPathNameW(shortPath, buffer, (uint)buffer.Capacity);
            if (length == 0) { return shortPath; }
        }
        return buffer.ToString();
    }
}
'@ -ErrorAction Stop
        }
        $resolved = [Win32PathHelper]::GetLongPath($full)
        if (-not [string]::IsNullOrWhiteSpace($resolved)) { $full = $resolved }
    } catch {
        Write-ScanLog -Level Warn -Message "无法解析路径长名（将按原样比较）：$($_.Exception.Message)"
    }

    $root = [System.IO.Path]::GetPathRoot($full)
    if ($root -and $full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-CleanupPathAllowed {
    <#
    .SYNOPSIS
        判断一个路径是否允许被清理。宁可拒绝，不可放过。

    .OUTPUTS
        @{ Allowed = [bool]; Reason = '...' }
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)

    $result = @{ Allowed = $false; Reason = '' }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.Reason = '路径为空'
        return $result
    }

    # 展开环境变量 + 解析 8.3 短名后再判断（短名会导致字符串比较失败，实测踩到过）
    $full = Get-NormalizedPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($full)) {
        $result.Reason = '路径无法解析'
        return $result
    }

    # 拒绝盘根（C:\ 、D:\ 这种）
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($root -and $full.TrimEnd('\') -eq $root.TrimEnd('\')) {
        $result.Reason = '拒绝操作磁盘根目录'
        return $result
    }

    # 拒绝受保护路径
    foreach ($pattern in $script:ProtectedPathPatterns) {
        if ($full.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $result.Reason = "路径命中受保护目录（$pattern），拒绝清理"
            return $result
        }
    }

    # 必须在白名单内
    $allowed = $false
    foreach ($target in (Get-CleanupTarget)) {
        foreach ($candidate in $target.Paths) {
            $candidateFull = Get-NormalizedPath -Path $candidate
            if ([string]::IsNullOrWhiteSpace($candidateFull)) { continue }
            if ($full.Equals($candidateFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowed = $true
                break
            }
            # 允许白名单目录下的子路径（例如 Explorer 目录下的 thumbcache_*.db）
            if ($full.StartsWith($candidateFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowed = $true
                break
            }
        }
        if ($allowed) { break }
    }

    if (-not $allowed) {
        $result.Reason = '不在清理白名单内'
        return $result
    }

    $result.Allowed = $true
    $result.Reason = '在白名单内'
    return $result
}

function Get-CleanupPathRoot {
    <#
    .SYNOPSIS
        返回一个路径所属的白名单根目录与目标定义，供上层按目标汇总体积。
    .OUTPUTS
        @{ Target = <目标>; Root = '白名单根目录' } 或 $null
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = Get-NormalizedPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($full)) { return $null }

    foreach ($target in (Get-CleanupTarget)) {
        foreach ($candidate in $target.Paths) {
            $candidateFull = Get-NormalizedPath -Path $candidate
            if ([string]::IsNullOrWhiteSpace($candidateFull)) { continue }
            if ($full.Equals($candidateFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                return @{ Target = $target; Root = $candidateFull }
            }
        }
    }
    return $null
}
