#Requires -Version 5.1
<#
.SYNOPSIS
    Win11-Optimizer v1.1 图形界面的主窗口：用 XAML 描述界面结构，构造并返回 Window 对象。

.DESCRIPTION
    本文件只负责"画窗口"：把窗口结构、控件命名与中文文案固定下来，交给外部编排代码
    （Gui.Core.ps1 / Win11Optimizer.Gui.ps1）取用。它自己严格不做下面这些事：

      · 不 Show / 不 ShowDialog —— 什么时候显示、以什么模式显示，由外部决定；
      · 不设置 DataContext、不做数据绑定、不读任何业务数据；
      · 不调用任何扫描、清理、还原或删除逻辑（本文件里没有这类命令）。

    控件命名是**对外契约**，外部代码用 $window.FindName('<名字>') 取用：

      标题与状态  SubtitleText / StatusText / ProgressBar
      按钮        ScanButton / CleanButton / RestoreButton / QuarantineText
      本机情况    ProfileMachine / ProfileOS / ProfileCpu / ProfileMemory
                  / ProfileAdmin / ProfilePowerShell
      诊断结果    FindingsGrid（4 列：级别 / 问题 / 说明 / 建议）
      可清理缓存  CleanupSummary / CleanupGrid（5 列：清理 / 项目 / 可隔离 / 文件数 / 说明）
      运行日志    LogBox —— 外部编排代码把扫描过程输出追加到这里
      底部状态    PathText —— 显示报告路径与日志路径

    关于 CleanupGrid 的只读设置：整表 IsReadOnly="True"，但"清理"复选框列单独设
    IsReadOnly="False"。WPF 里列级设置会覆盖表级设置，这样其余列都不可编辑，而复选框
    仍然点得动——否则"勾选后才清理"这条流程在界面上就走不通了。

.NOTES
    编码：本文件必须 UTF-8 with BOM（铁律 L4）。
    依赖：零第三方依赖，只用 .NET Framework 内置 WPF（PresentationFramework /
          PresentationCore / WindowsBase），加载 XAML 前先 Add-Type。
    错误处理：不允许静默失败（铁律 L2）——拿不到控件、XAML 有语法错都直接 throw 说清原因。
#>

Set-StrictMode -Version Latest

# 清理目标的中文名沿用命令行版与 Cleanup.Ui.ps1 的说法（隔离区 / 一键还原 / 开始扫描），
# 窗口里的文案不要另造一套。

function Initialize-GuiAssemblies {
    <#
    .SYNOPSIS
        加载 WPF 需要的 .NET Framework 内置程序集（零第三方依赖）。

    .NOTES
        只加载 PresentationFramework / PresentationCore / WindowsBase。任何一个都加载不到
        （例如不是 Windows 或 .NET Framework 缺失）时直接抛错，而不是让后面的 XAML 解析
        抛一句看不懂的异常。
    #>
    [CmdletBinding()]
    param()

    foreach ($assemblyName in @('PresentationFramework', 'PresentationCore', 'WindowsBase')) {
        try {
            Add-Type -AssemblyName $assemblyName -ErrorAction Stop
        } catch {
            throw ("无法加载 WPF 程序集 {0}：{1}。本界面需要 Windows PowerShell 5.1 与 .NET Framework 4.8。" -f `
                    $assemblyName, $_.Exception.Message)
        }
    }
}

function Get-MainWindowXaml {
    <#
    .SYNOPSIS
        返回主窗口的 XAML 文本（单一根元素 Window）。

    .NOTES
        用单引号 here-string 保存，避免 $ 被 PowerShell 插值。XAML 里不放任何业务数据、
        路径或命令字面量——数据一律由外部代码写进控件。
    #>
    [CmdletBinding()]
    param()

    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Win11 一键优化"
        Height="680" Width="960" MinHeight="560" MinWidth="820"
        WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="13"
        Background="#FFF6F6F6">
    <Grid Margin="18,14,18,12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- 1. 顶部标题区 -->
        <StackPanel Grid.Row="0">
            <TextBlock Text="Win11 一键优化" FontSize="22" FontWeight="Bold"/>
            <TextBlock x:Name="SubtitleText"
                       Text="纯 PowerShell 只读诊断与安全清理 · 清理 = 移动到隔离区，可一键还原"
                       FontSize="12" Foreground="Gray" Margin="0,4,0,0" TextWrapping="Wrap"/>
        </StackPanel>

        <!-- 2. 状态区 -->
        <StackPanel Grid.Row="1" Margin="0,12,0,0">
            <TextBlock x:Name="StatusText" Text="就绪。点击「开始扫描」检查本机情况。" TextWrapping="Wrap"/>
            <ProgressBar x:Name="ProgressBar" Height="4" IsIndeterminate="False" Value="0" Margin="0,6,0,0"/>
        </StackPanel>

        <!-- 3. 按钮区 -->
        <Grid Grid.Row="2" Margin="0,12,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
                <Button x:Name="ScanButton" Content="开始扫描" Padding="18,6" MinWidth="110"/>
                <Button x:Name="CleanButton" Content="清理选中项" Padding="18,6" MinWidth="110"
                        Margin="8,0,0,0" IsEnabled="False"/>
                <Button x:Name="RestoreButton" Content="一键还原" Padding="18,6" MinWidth="110"
                        Margin="8,0,0,0"/>
            </StackPanel>
            <TextBlock x:Name="QuarantineText" Grid.Column="1" Text="隔离区：无"
                       Foreground="Gray" FontSize="12"
                       HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>

        <!-- 4. 本机信息区 -->
        <GroupBox Grid.Row="3" Header="本机情况" Margin="0,12,0,0" Padding="10,6">
            <UniformGrid Columns="2" Rows="3">
                <TextBlock x:Name="ProfileMachine" Text="—" Margin="0,3" TextWrapping="Wrap"/>
                <TextBlock x:Name="ProfileOS" Text="—" Margin="0,3" TextWrapping="Wrap"/>
                <TextBlock x:Name="ProfileCpu" Text="—" Margin="0,3" TextWrapping="Wrap"/>
                <TextBlock x:Name="ProfileMemory" Text="—" Margin="0,3" TextWrapping="Wrap"/>
                <TextBlock x:Name="ProfileAdmin" Text="—" Margin="0,3" TextWrapping="Wrap"/>
                <TextBlock x:Name="ProfilePowerShell" Text="—" Margin="0,3" TextWrapping="Wrap"/>
            </UniformGrid>
        </GroupBox>

        <!-- 5. 结果区 -->
        <TabControl Grid.Row="4" Margin="0,8,0,0">
            <TabItem Header="诊断结果">
                <DataGrid x:Name="FindingsGrid" Margin="6"
                          AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                          GridLinesVisibility="Horizontal" HeadersVisibility="Column">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="级别" Binding="{Binding Severity}" Width="70"/>
                        <DataGridTextColumn Header="问题" Binding="{Binding Title}" Width="280"/>
                        <DataGridTextColumn Header="说明" Binding="{Binding Detail}" Width="*"/>
                        <DataGridTextColumn Header="建议" Binding="{Binding Advice}" Width="260"/>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
            <TabItem Header="可清理缓存">
                <DockPanel Margin="6">
                    <TextBlock x:Name="CleanupSummary" DockPanel.Dock="Top"
                               Text="点击「开始扫描」后列出可清理项。"
                               TextWrapping="Wrap" Margin="2,2,2,6"/>
                    <DataGrid x:Name="CleanupGrid"
                              AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                              GridLinesVisibility="Horizontal" HeadersVisibility="Column"
                              SelectionMode="Single">
                        <DataGrid.Columns>
                            <DataGridCheckBoxColumn Header="清理" Width="56" IsReadOnly="False"
                                Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"/>
                            <DataGridTextColumn Header="项目" Binding="{Binding Name}" Width="240"/>
                            <!-- 可隔离：显示走 SizeText（中文易读），排序走 SortMemberPath=Bytes（按真实字节数排，
                                 不会出现 9 MB 排在 3 GB 前面）。绑 Bytes 直接显示会是一串裸字节数。 -->
                            <DataGridTemplateColumn Header="可隔离" Width="110"
                                                    SortMemberPath="Bytes" IsReadOnly="True">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding SizeText}" Margin="4,0" VerticalAlignment="Center"/>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTextColumn Header="文件数" Binding="{Binding FileCount}" Width="80"/>
                            <DataGridTextColumn Header="说明" Binding="{Binding Note}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>
            <TabItem Header="运行日志">
                <TextBox x:Name="LogBox" Margin="6"
                         IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                         FontFamily="Consolas" FontSize="12"/>
            </TabItem>
        </TabControl>

        <!-- 6. 底部状态栏 -->
        <TextBlock x:Name="PathText" Grid.Row="5" Text=""
                   Foreground="Gray" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"/>
    </Grid>
</Window>
'@
}

function Assert-MainWindowControls {
    <#
    .SYNOPSIS
        确认窗口里所有约定命名的控件都真的存在，缺一个就抛错说清是哪个。

    .NOTES
        XAML 少写一个 x:Name 不会报错，只会在外部代码 FindName 时静默拿到 $null。这里在
        构造窗口的同一刻就把它变成明确的失败（铁律 L2：不允许静默失败）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Windows.Window]$Window)

    $required = @(
        'SubtitleText', 'StatusText', 'ProgressBar',
        'ScanButton', 'CleanButton', 'RestoreButton', 'QuarantineText',
        'ProfileMachine', 'ProfileOS', 'ProfileCpu', 'ProfileMemory', 'ProfileAdmin', 'ProfilePowerShell',
        'FindingsGrid', 'CleanupGrid', 'CleanupSummary', 'LogBox', 'PathText'
    )

    $missing = New-Object System.Collections.ArrayList
    foreach ($name in $required) {
        if ($null -eq $Window.FindName($name)) { [void]$missing.Add($name) }
    }
    if ($missing.Count -gt 0) {
        throw ("窗口 XAML 缺少控件：{0}。请对照控件契约补齐 x:Name。" -f ($missing -join '、'))
    }

    foreach ($gridName in @('FindingsGrid', 'CleanupGrid')) {
        $grid = $Window.FindName($gridName)
        if ($grid.Columns.Count -eq 0) {
            throw ("{0} 没有任何列，界面会是一片空白。" -f $gridName)
        }
    }
}

function New-MainWindow {
    <#
    .SYNOPSIS
        构造主窗口并返回 Window 对象。不 Show、不 ShowDialog、不读业务数据。

    .DESCRIPTION
        用 here-string 里的 XAML 经 [System.Windows.Markup.XamlReader]::Load() 创建窗口，
        校验约定的控件都在之后返回。窗口显示、事件绑定、数据填充都由外部编排代码负责。

    .OUTPUTS
        System.Windows.Window —— 尚未显示的窗口对象。
    #>
    [CmdletBinding()]
    param()

    Initialize-GuiAssemblies

    $xaml = Get-MainWindowXaml

    $window = $null
    try {
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    } catch {
        throw ("主窗口 XAML 解析失败：{0}。请检查 XAML 是否有拼写错误或未知属性。" -f $_.Exception.Message)
    }

    if ($null -eq $window) {
        throw '主窗口 XAML 解析后没有返回任何对象，界面无法创建。'
    }
    if ($window -isnot [System.Windows.Window]) {
        throw ("主窗口 XAML 的根元素不是 Window，而是 {0}。" -f $window.GetType().FullName)
    }

    Assert-MainWindowControls -Window $window
    return $window
}
