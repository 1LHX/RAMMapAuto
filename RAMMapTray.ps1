# ============================================================================
#  RAMMap 自动清理 —— 托盘常驻程序
# ----------------------------------------------------------------------------
#  功能一览：
#    · 定时保养：默认每 30 分钟清理一次，仅在占用 60%-80% 区间生效
#      （低于低占用线跳过；超阈值时由内存监控接管）
#    · 内存监控：默认每 5 分钟检查占用，超过阈值（默认 80%）立即清理
#    · 手动清理：菜单/双击托盘，无条件执行，不受任何阈值限制
#    · 游戏保护模式：检测到游戏运行时，自动改为逐进程清理，
#      绝不动游戏与系统关键进程，防止游戏因内存被换出而卡死
#    · 参数设置：托盘菜单中可随时调整 间隔 / 检查频率 / 阈值，持久化保存
#    · 开机自启：借道计划任务以最高权限静默启动，全程无 UAC 弹窗
#    · 无窗口常驻：右下角托盘图标 + 右键菜单控制一切
#    · 单实例保护：已有实例运行时重复启动仅弹气泡提醒，不打扰旧实例
#    · 托盘重启：菜单一键重启，新实例直接以管理员身份无缝接管
#
#  文件说明（均与本脚本同目录）：
#    RAMMapTray.ps1            本脚本（需 UTF-8 BOM 编码）
#    启动RAMMap自动清理.vbs     无窗口启动器（计划任务与快捷方式的入口）
#    rammap_tray_config.json   用户参数持久化（删除即恢复脚本默认值）
#    rammap_auto.log           运行日志（右键菜单"查看日志"可打开）
#
#  依赖：RAMMap（Sysinternals），路径见下方配置区 $rammapDir
# ============================================================================

$ErrorActionPreference = 'Continue'

# ============================================================================
# 一、默认配置（菜单"参数设置"中的修改会保存到 json 并覆盖这里的默认值）
# ============================================================================
$script:intervalMinutes      = 30    # 常规自动清理间隔（分钟），范围 1-1440
$script:checkIntervalMinutes = 5     # 内存占用检查间隔（分钟），范围 1-60
                                      #   注：该值同时是两次清理的最小冷却时间（防抖）
$script:memThresholdPercent  = 80    # 内存占用阈值（%），超过则立即清理，范围 50-95
$script:skipBelowPercent     = 60    # 占用低于此值（%）时跳过定时保养/启动清理（内存充裕，换页得不偿失），范围 0-90
                                      #   注：仅跳过"定时/手动"类触发；内存监控超阈值触发与启动清理不受限
$script:minWorkingSetMB      = 50    # 逐进程清理时，工作集小于此值（MB）的进程跳过
$script:autoStartEnabled     = $true # 开机自启偏好（菜单切换后持久化；配置无此键时默认开启）
$script:autoCleanEnabled     = $true # 自动清理开关（重启不丢，持久化）
$script:memWatchEnabled      = $true # 内存监控开关（重启不丢，持久化）

# 游戏进程名：检测到任一在运行时，清理自动切换"游戏保护模式"（跳过游戏进程）
# 含游戏启动器：HYP/HYPHelper 为米哈游启动器，启动期工作集被清空会导致游戏
#   等待启动器响应超时而挂起（AppHangXProcB1），必须一并保护
# 名单可在 rammap_tray_config.json 的 "gameProcessNames" 中增删（无此键则用下面的默认值）
$script:gameProcessNames = @('YuanShen', 'GenshinImpact', 'GenshinImpact-2', 'HYP', 'HYPHelper', 'StarRail')

# 系统关键进程：游戏保护模式下同样跳过，避免桌面/声音/安全组件出现卡顿
$script:systemProtectedNames = @(
    'wininit','csrss','smss','services','lsass','winlogon','svchost','dwm',
    'explorer','LogonUI','fontdrvhost','sihost','taskhostw','ctfmon','dllhost',
    'RuntimeBroker','SearchHost','ShellExperienceHost','StartMenuExperienceHost',
    'System','Idle','Registry','Memory Compression','audiodg','WudfHost',
    'MsMpEng','NisSrv','SecurityHealthService','SecurityHealthSystray','spoolsv'
)

# 路径与常量
$script:rammapDir = 'E:\Software\RAMMap\RAMMap'                        # RAMMap 所在目录
$script:configVersion = 1
$script:logFile   = Join-Path $PSScriptRoot 'rammap_auto.log'          # 日志文件
$script:configFile = Join-Path $PSScriptRoot 'rammap_tray_config.json' # 参数持久化文件
$script:vbsPath   = Join-Path $PSScriptRoot '启动RAMMap自动清理.vbs'    # 无窗口启动器
$script:taskName  = 'RAMMapAutoTray'                                   # 开机自启计划任务名
$script:mutexName = 'RAMMapAutoTray'                                   # 单实例互斥锁名（加 _ping 后缀为跨实例通知事件名）

# 运行时状态（无需改动）
$script:lastCleanup = Get-Date   # 上次清理时间，用于清理防抖

# ============================================================================
# 二、参数持久化：从 json 读取用户设置，覆盖默认值（带范围校验）
# ============================================================================
$script:configRanges = @{   # 各参数的合法范围（与菜单输入校验保持一致）
    intervalMinutes      = @(1, 1440)
    checkIntervalMinutes = @(1, 60)
    memThresholdPercent  = @(50, 95)
    skipBelowPercent     = @(0, 90)
}

if (Test-Path $script:configFile) {
    try {
        $saved = Get-Content $script:configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.rammapDir -and -not [string]::IsNullOrWhiteSpace([string]$saved.rammapDir)) {
            $candidateDir = [Environment]::ExpandEnvironmentVariables(([string]$saved.rammapDir).Trim())
            if (Test-Path $candidateDir -PathType Container) { $script:rammapDir = $candidateDir }
        }
        foreach ($key in @('intervalMinutes', 'checkIntervalMinutes', 'memThresholdPercent', 'skipBelowPercent')) {
            $n = 0
            if ($saved.$key -ne $null -and [int]::TryParse("$($saved.$key)", [ref]$n)) {
                $range = $script:configRanges[$key]
                if ($n -ge $range[0] -and $n -le $range[1]) {
                    Set-Variable -Name $key -Scope Script -Value $n
                }
            }
        }
        # 布尔/列表项（无范围校验）
        if ($saved.autoStartEnabled -ne $null) { $script:autoStartEnabled = [bool]$saved.autoStartEnabled }
        if ($saved.autoCleanEnabled  -ne $null) { $script:autoCleanEnabled  = [bool]$saved.autoCleanEnabled }
        if ($saved.memWatchEnabled   -ne $null) { $script:memWatchEnabled   = [bool]$saved.memWatchEnabled }
        if ($saved.gameProcessNames) {            # 游戏名单：json 数组覆盖默认值（空数组视为未配置）
            $names = @($saved.gameProcessNames | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace([string]$_)) {
                    ([string]$_).Trim() -replace '(?i)\.exe$',''
                }
            } | Where-Object { $_ })
            if ($names.Count -gt 0) { $script:gameProcessNames = $names }
        }
    } catch { }   # 配置文件损坏时静默使用默认值
}

# 保存当前参数到 json（菜单"参数设置"修改后调用）
function Save-Config {
    try {
        @{ configVersion        = $script:configVersion
           rammapDir             = $script:rammapDir
           intervalMinutes      = $script:intervalMinutes
           checkIntervalMinutes = $script:checkIntervalMinutes
           memThresholdPercent  = $script:memThresholdPercent
           skipBelowPercent     = $script:skipBelowPercent
           autoStartEnabled     = $script:autoStartEnabled
           autoCleanEnabled     = $script:autoCleanEnabled
           memWatchEnabled      = $script:memWatchEnabled
           gameProcessNames     = $script:gameProcessNames
        } | ConvertTo-Json | Set-Content -Path $script:configFile -Encoding UTF8
    } catch {
        Write-Log "参数保存失败: $($_.Exception.Message)"
    }
}

# ============================================================================
# 三、日志
# ============================================================================
function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    # 显式 UTF8 写入，避免中文乱码（注意必须是 System.Text.Encoding）
    [System.IO.File]::AppendAllText($script:logFile, $line + "`r`n", [System.Text.Encoding]::UTF8)
    # 日志轮转：超过 512KB 保留后半段，防止无限增长
    try {
        $fi = Get-Item $script:logFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 512KB) {
            $keep = 256KB
            $fs = [System.IO.File]::Open($script:logFile, 'Open', 'Read', 'ReadWrite')
            try {
                $len = $fs.Length
                $fs.Seek(-$keep, 'End') | Out-Null
                $buf = New-Object byte[] $keep
                [void]$fs.Read($buf, 0, $keep)
                $text = [System.Text.Encoding]::UTF8.GetString($buf)
                # 从第一个完整行开始保留（丢掉被截断的半行）
                $nl = $text.IndexOf("`n")
                if ($nl -ge 0 -and $nl -lt $keep - 1) { $text = $text.Substring($nl + 1) }
                $head = "[{0}] ==== 日志已轮转（超 512KB，保留最近记录） ====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                [System.IO.File]::WriteAllText($script:logFile, $head + "`r`n" + $text, [System.Text.Encoding]::UTF8)
            } finally { $fs.Dispose() }
        }
    } catch { }   # 轮转失败不影响主流程
}

# ============================================================================
# 四、引导阶段：提权 + 单实例（非管理员实例到此为止，不进入托盘）
# ============================================================================

# --- 4.1 提权 ---
# 已注册开机自启计划任务且指向当前路径 -> 借道任务以最高权限静默启动（无 UAC）；
# 未注册 / 注册时指向旧路径（文件夹被移动过）-> 自我提权（仅这一次可能需要确认 UAC），
#   提权成功后由 Repair-Locations 按新位置重注册任务，完成位置自愈
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    $existingTask = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
    $taskPointsToMe = $false
    if ($existingTask) {
        # 任务是否仍指向本脚本所在目录的 VBS（文件夹整体移动后会指向旧路径）
        $arg = ($existingTask.Actions | Select-Object -First 1).Arguments
        $vbsNow = Join-Path $PSScriptRoot '启动RAMMap自动清理.vbs'
        if ($arg -and $arg.Contains($vbsNow)) { $taskPointsToMe = $true }
    }
    if ($existingTask -and $taskPointsToMe) {
        # 已有实例常驻时任务处于 Running：先 ping 旧实例弹气泡（是否真有实例由旧实例回应）；
        # 若任务触发被并发策略吞掉，用户至少能得到"已在运行"的反馈
        try {
            $evt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:mutexName + '_ping')
            $evt.Set(); $evt.Dispose()
        } catch { }
        # 任务本身以最高权限运行，schtasks 只是触发器
        Start-Process schtasks.exe -ArgumentList @('/run', '/tn', $script:taskName) -WindowStyle Hidden
    } else {
        try {
            Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta',
                '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`""
            )
        } catch {
            Write-Log "提权被取消，程序未启动: $($_.Exception.Message)"
        }
    }
    exit
}

# --- 4.2 单实例（保护模式）---
# 若互斥锁被占用，说明已有实例在运行：通知对方（弹气泡提醒"已在运行"）后自己退出，
# 绝不结束旧实例——避免误杀导致的清理中断/状态丢失。
# 跨进程通知用命名 EventWaitHandle：新实例 Set 信号，旧实例轮询收到后弹提示。
function New-TrayMutex {
    # 返回 $true = 成功持有锁（$script:mutex 保留句柄，进程生命周期内持有）
    #       $false = 锁被占用或创建失败（句柄立即释放并置空，防止句柄泄漏）
    # 注：Mutex 构造在锁被占时仍会成功创建对象（只是没抢到），不能靠对象判空！
    $created = $false
    $m = $null
    try { $m = New-Object System.Threading.Mutex($true, $script:mutexName, [ref]$created) } catch { }
    if ($created) { $script:mutex = $m; return $true }
    if ($m) { $m.Dispose() }
    $script:mutex = $null
    return $false
}
if (-not (New-TrayMutex)) {
    # 通知已运行的实例露个脸，让用户知道"刚才那次双击其实被保护了"
    try {
        $evt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:mutexName + '_ping')
        $evt.Set(); $evt.Dispose()
    } catch { }
    # 重试窗口：仅服务于"旧实例正在退出"的场景（如用户点了重启菜单，等它放锁），
    # 每秒试一次共 15 秒；超时仍拿不到说明旧实例健在 -> 静默退出，绝不抢跑
    $acquired = $false
    for ($i = 0; $i -lt 15 -and -not $acquired; $i++) {
        Start-Sleep -Seconds 1
        if (New-TrayMutex) { $acquired = $true }
    }
    if (-not $acquired) { exit }
}

# ============================================================================
# 五、.NET 程序集与 Win32 API
# ============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic    # 参数设置用 InputBox 输入框

# 注：Win32 API（EmptyWorkingSet 等）的封装见下方 Add-Win32Api，改为按需编译——
#     游戏未运行时永远不会编译，不再占用每次启动的时间（C# 内存编译约 1-2 秒）

# ============================================================================
# 六、RAMMap 定位（优先 64 位）
# ============================================================================
$script:rammapPath = @(
    (Join-Path $script:rammapDir 'RAMMap64.exe'),
    (Join-Path $script:rammapDir 'RAMMap.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $script:rammapPath) {
    [System.Windows.Forms.MessageBox]::Show(
        "未找到 RAMMap64.exe / RAMMap.exe：`n$script:rammapDir`n`n请修改本脚本顶部的 `$rammapDir",
        'RAMMap 自动清理', 'OK', 'Error') | Out-Null
    exit 1
}

Write-Log "==== 托盘程序启动（管理员）: $script:rammapPath ===="
Write-Log ("环境: PowerShell {0}, OS {1}, 脚本目录 {2}, 配置版本 {3}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.Version, $PSScriptRoot, $script:configVersion)
Write-Log ("配置: 定时保养每 {0} 分钟(仅占用 {3}%-{2}% 区间); 内存监控每 {1} 分钟检查, 占用超过 {2}% 立即清理; 占用低于 {3}% 时定时保养/启动清理自动跳过" -f `
    $script:intervalMinutes, $script:checkIntervalMinutes, $script:memThresholdPercent, $script:skipBelowPercent)

# ============================================================================
# 七、内存查询
# ============================================================================
# GlobalMemoryStatusEx 内核 API 封装：WMI 失效时的兜底数据源（按需编译）
# 背景：WMI 服务/仓库损坏时 Get-CimInstance 会抛错或返回空，导致监控读数恒为 0%
#       完全失明（曾因此漏掉原神启动期间的内存清理触发）；内核 API 不依赖 WMI
$script:k32Compiled      = $false
$script:wmiFallbackLogged = $false

function Add-K32Api {
    if ($script:k32Compiled) { return }
    Add-Type -Namespace Win32 -Name K32Ex -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct MEMORYSTATUSEX { public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys; public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual; }
[DllImport("kernel32.dll")] public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buf);
'@
    $script:k32Compiled = $true
}

function Get-MemoryStatus {
    # 返回 @{ TotalGB / FreeGB }：优先 WMI；WMI 失败或返回无效值时退回内核 API
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    if ($os -and $os.TotalVisibleMemorySize -gt 0) {
        return @{ TotalGB = [double]$os.TotalVisibleMemorySize * 1KB / 1GB
                  FreeGB  = [double]$os.FreePhysicalMemory  * 1KB / 1GB }
    }
    if (-not $script:wmiFallbackLogged) {   # 只记一次，避免日志刷屏
        Write-Log "[警告] WMI 内存查询失败，已切换内核 API 兜底（建议检查 WMI 服务）"
        $script:wmiFallbackLogged = $true
    }
    Add-K32Api
    $m = New-Object 'Win32.K32Ex+MEMORYSTATUSEX'
    $m.dwLength = 64
    [void][Win32.K32Ex]::GlobalMemoryStatusEx([ref]$m)
    return @{ TotalGB = $m.ullTotalPhys / 1GB; FreeGB = $m.ullAvailPhys / 1GB }
}

function Get-FreeGB {
    # 当前可用物理内存（GB）
    [math]::Round((Get-MemoryStatus).FreeGB, 2)
}

function Get-UsagePct {
    # 当前物理内存占用率（%）
    $s = Get-MemoryStatus
    if ($s.TotalGB -le 0) { return 0 }
    [math]::Round((($s.TotalGB - $s.FreeGB) / $s.TotalGB) * 100, 1)
}

# ============================================================================
# 八、游戏检测
# ============================================================================
function Test-GameRunning {
    foreach ($n in $script:gameProcessNames) {
        $normalized = ([string]$n).Trim() -replace '(?i)\.exe$',''
        if (Get-Process -Name $normalized -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# ============================================================================
# 九、清理执行（核心）
# ============================================================================
# 两种模式：
#   全局清理     —— RAMMap -Ew 一键清空所有进程工作集，释放量最大；
#                   仅在游戏未运行时使用（会把游戏内存整个换出导致游戏卡死）
#   游戏保护清理 —— EmptyWorkingSet API 逐进程清理，跳过游戏与系统关键进程，
#                   释放量略小但零风险

# EmptyWorkingSet = SetProcessWorkingSetSize(-1,-1)：
# 把指定进程的工作集页面全部移出物理内存（游戏保护模式的逐进程清理用）
# 按需编译：仅首次进入游戏保护清理时才执行，日常启动不再为此多花 1-2 秒
$script:win32Compiled = $false
function Add-Win32Api {
    if ($script:win32Compiled) { return }
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("psapi.dll")]    public static extern int    EmptyWorkingSet(IntPtr hProcess);
[DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll")] public static extern bool   CloseHandle(IntPtr h);
'@
    $script:win32Compiled = $true
}

# 模式 A：全局清理（游戏未运行时）
function Invoke-GlobalCleanup {
    $proc = Start-Process -FilePath $script:rammapPath -ArgumentList '-Ew' -PassThru -WindowStyle Hidden
    if (-not $proc.WaitForExit(120000)) {
        try { $proc.Kill() } catch { }
        throw "RAMMap 清理超时（超过 120 秒）"
    }
    if ($proc.ExitCode -ne 0) { throw "RAMMap 清理失败，退出码: $($proc.ExitCode)" }
    Start-Sleep -Milliseconds 1500   # 等待内存计数器稳定后再统计释放量
}

# 模式 B：游戏保护清理（游戏运行时），返回成功清理的进程数
function Invoke-ProtectedCleanup {
    Add-Win32Api   # 首次调用时才编译 Win32 封装（见上方说明）
    $cleaned = 0
    Get-Process | ForEach-Object {
        $p = $_
        if ($script:gameProcessNames | Where-Object { $_ -ieq $p.Name })     { return }  # 绝不动游戏
        if ($script:systemProtectedNames | Where-Object { $_ -ieq $p.Name }) { return }  # 不动系统关键进程
        if ($p.WorkingSet64 -lt ($script:minWorkingSetMB * 1MB)) { return } # 太小无意义
        try {
            # PROCESS_SET_QUOTA(0x0100) | PROCESS_QUERY_INFORMATION(0x0400)，
            # EmptyWorkingSet 只需这两项，无需 PROCESS_ALL_ACCESS
            $h = [Win32.NativeMethods]::OpenProcess(0x0500, $false, $p.Id)
            if ($h -ne [IntPtr]::Zero) {
                if ([Win32.NativeMethods]::EmptyWorkingSet($h) -ne 0) { $cleaned++ }
                [Win32.NativeMethods]::CloseHandle($h) | Out-Null
            }
        } catch {}
    }
    return $cleaned
}

# 清理调度入口：按游戏是否运行自动选模式，统一负责 防抖 / 低占用跳过 / 日志 / 托盘提示
#   防抖（冷却）：距上次清理不足 checkIntervalMinutes 时跳过。仅约束自动触发源
#     （定时 / 内存触发），防止两个自动源在短时间内重复清理；
#     手动与启动豁免——手动是用户明确意图必须执行，启动需保证开机必清。
#   低占用跳过：同样仅限定时/启动（见函数内注释）。
# 冷却时间随"内存检查间隔"联动更新（修改该参数时刷新）
$script:cooldownMinutes = $script:checkIntervalMinutes
function Invoke-Cleanup($trigger) {
    try {
        $startedAt = Get-Date
        # --- 冷却防抖：仅约束自动触发源（定时/内存触发），手动与启动豁免 ---
        $elapsed = [int]((Get-Date) - $script:lastCleanup).TotalMinutes
        if (($trigger -eq '定时' -or $trigger -eq '内存触发') -and $elapsed -lt $script:cooldownMinutes) {
            return
        }

        # --- 低占用跳过：内存充裕时清理收益小于换页代价（定时/启动受限；手动/内存触发不受限） ---
        # 手动点击"立即清理"是用户明确意图，无条件执行；
        # 启动清理受门槛约束：刚开机占用通常不高，跳过可避免最耗时的驱动冷加载挡住启动
        $usage = Get-UsagePct
        if (($trigger -eq '定时' -or $trigger -eq '启动') -and $usage -lt $script:skipBelowPercent) {
            Write-Log ("[{0}] 占用 {1}% 低于 {2}%，跳过清理" -f $trigger, $usage, $script:skipBelowPercent)
            Update-Tip ("占用{0}% 可用{1}GB（低于阈值未清理）" -f $usage, (Get-FreeGB))
            return
        }

        $before = Get-FreeGB
        if (Test-GameRunning) {
            $count = Invoke-ProtectedCleanup
            $label = "游戏保护模式（跳过游戏，清理 ${count} 个进程）"
        } else {
            Invoke-GlobalCleanup | Out-Null
            $label = '全局清理'
        }
        $after = Get-FreeGB
        $freed = [math]::Round($after - $before, 2)
        $script:lastCleanup = Get-Date
        $duration = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
        Write-Log ("[{0}] {1}: 可用物理内存 {2}GB -> {3}GB (释放 {4}GB, 耗时 {5}秒)" -f $trigger, $label, $before, $after, $freed, $duration)
        Update-Tip ("{0} 释放{1}GB 可用{2}GB" -f (Get-Date -Format 'HH:mm'), $freed, $after)
    } catch {
        Write-Log "执行失败: $($_.Exception.Message)"
        Update-Tip '上次执行失败，详见日志'
    }
}

# ============================================================================
# 十、开机自启（计划任务：最高权限 + 登录触发，全程无 UAC 提示框）
# ============================================================================
function Test-AutoStart {
    [bool](Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue)
}

function Set-AutoStart($enable) {
    try {
        if ($enable) {
            $user      = "$env:USERDOMAIN\$env:USERNAME"
            $action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$script:vbsPath`"" -WorkingDirectory $PSScriptRoot
            $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
            try {
                # ExecutionTimeLimit 为 0 = 不限时（默认 72 小时后任务会被强制停止）
                # MultipleInstances = Parallel：旧实例常驻时任务处于 Running，默认 IgnoreNew
                #   会把后续 /run 触发静默吞掉（这正是"重复启动无任何反应"的原因）
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
            } catch {
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 365)
            }
            Register-ScheduledTask -TaskName $script:taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            Write-Log '开机自启: 已开启（计划任务静默启动，无 UAC 提示框）'
        } else {
            Unregister-ScheduledTask -TaskName $script:taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log '开机自启: 已关闭'
        }
        return $true
    } catch {
        Write-Log "开机自启设置失败: $($_.Exception.Message)"
        return $false
    }
}

# --- 位置自愈：文件夹被整体移动后，自启任务/快捷方式仍指向旧路径 ---
# 比对计划任务登记的 VBS 路径与当前实际路径，不一致则按新位置重注册，
# 并同步重建桌面快捷方式。这样"移动后从新位置启动一次"即可完成自愈。
# 返回值：本次查询到的计划任务对象（$null = 任务不存在）——
#   供启动流程的 Test-AutoStart 判定复用，避免同一启动周期内重复查询
function Repair-Locations {
    try {
        $needFix = $true
        $task = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
        if ($task) {
            $arg = ($task.Actions | Select-Object -First 1).Arguments
            if ($arg -and $arg.Contains($script:vbsPath)) { $needFix = $false }
        }
        if ($needFix) {
            if ($script:autoStartEnabled) {
                Set-AutoStart $true | Out-Null        # 按新位置重新注册计划任务
            } else {
                Unregister-ScheduledTask -TaskName $script:taskName -Confirm:$false -ErrorAction SilentlyContinue
            }
            Write-Log "位置自愈: 检测到路径变化，已按新位置 [$PSScriptRoot] 修复自启设置"
        }

        # 桌面快捷方式：存在但指向别处 -> 重建指向当前 VBS
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RAMMap 自动清理.lnk'
        if (Test-Path $lnk) {
            $sh  = New-Object -ComObject WScript.Shell
            $cur = $sh.CreateShortcut($lnk).TargetPath + ' ' + $sh.CreateShortcut($lnk).Arguments
            if ($cur -notmatch [regex]::Escape($script:vbsPath)) {
                $s = $sh.CreateShortcut($lnk)
                $s.TargetPath  = 'wscript.exe'
                $s.Arguments   = "`"$script:vbsPath`""
                $s.WorkingDirectory = $PSScriptRoot
                $s.IconLocation = "$script:rammapPath,0"
                $s.Save()
                Write-Log '位置自愈: 已重建桌面快捷方式指向新位置'
            }
        }
    } catch {
        Write-Log "位置自愈失败: $($_.Exception.Message)"
    }
    return $task
}

# ============================================================================
# 十一、托盘图标
# ============================================================================
# 注意：NotifyIcon 默认 Visible=false，必须显式设为 true 才会出现在托盘
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$trayIcon = $null
try { $trayIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:rammapPath) } catch {
    Write-Log "图标提取失败，使用系统默认图标: $($_.Exception.Message)"
}
if (-not $trayIcon) { $trayIcon = [System.Drawing.SystemIcons]::Application }   # 兜底图标
$script:notify.Icon = $trayIcon
$script:notify.Text = 'RAMMap 自动清理'

# 更新托盘悬停提示（NotifyIcon.Text 上限 63 字符，超限会抛异常）
# 注：换行需用 "`r"（Windows tooltip 识别 CR 而非 LF，原 "-replace '\s+'" 会把换行折叠成空格）
function Update-Tip($extra) {
    $auto = if ($script:timer.Enabled) { "保养${script:intervalMinutes}分" } else { '保养关' }
    $mem  = if ($script:miMem -and $script:miMem.Checked) { "监控${script:memThresholdPercent}%" } else { '监控关' }
    $game = if (Test-GameRunning) { '游戏保护中' } else { '' }
    $line1 = "RAMMap $auto $mem $game".Trim() -replace '\s+', ' '
    $line2 = "$extra".Trim() -replace '\s+', ' '
    $maxLen1 = 62   # 第一行预算，剩余留给第二行
    if ($line1.Length -gt $maxLen1) { $line1 = $line1.Substring(0, $maxLen1) }
    $budget2 = 61 - $line1.Length   # 62 - 1("\r") - line1
    if ($line2.Length -gt $budget2) { $line2 = $line2.Substring(0, [math]::Max(0, $budget2)) }
    $script:notify.Text = $line1 + "`r" + $line2
}

# 确保 RAMMap 主程序在运行（菜单"打开 RAMMap 窗口"共用）
function Confirm-RAMMapRunning {
    if (-not (Get-Process -Name 'RAMMap', 'RAMMap64' -ErrorAction SilentlyContinue)) {
        try {
            Start-Process -FilePath $script:rammapPath | Out-Null
            Start-Sleep -Seconds 3
            Write-Log 'RAMMap 未运行，已启动'
        } catch {
            Write-Log "启动 RAMMap 失败: $($_.Exception.Message)"
        }
    }
}

function Select-RAMMapDirectory {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择 RAMMap 所在目录（需包含 RAMMap64.exe 或 RAMMap.exe）'
    $dialog.SelectedPath = $script:rammapDir
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $newDir = $dialog.SelectedPath
    $candidate = @((Join-Path $newDir 'RAMMap64.exe'), (Join-Path $newDir 'RAMMap.exe')) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $candidate) {
        [System.Windows.Forms.MessageBox]::Show('所选目录中未找到 RAMMap64.exe 或 RAMMap.exe。', 'RAMMap 自动清理', 'OK', 'Error') | Out-Null
        return
    }
    $script:rammapDir = $newDir
    $script:rammapPath = $candidate
    Save-Config
    Write-Log "RAMMap 路径已修改: $script:rammapPath"
    [System.Windows.Forms.MessageBox]::Show('路径已保存。请重启托盘程序使新路径和图标完全生效。', 'RAMMap 自动清理', 'OK', 'Information') | Out-Null
}

# ============================================================================
# 十二、定时器
# ============================================================================
# 定时器 A：常规清理（间隔 = intervalMinutes）
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $script:intervalMinutes * 60 * 1000
$script:timer.Add_Tick({ Invoke-Cleanup '定时' })

# 定时器 B：内存监控（间隔 = checkIntervalMinutes）
#   占用超阈值 且 距上次清理 ≥ checkIntervalMinutes（防抖）才触发清理
$script:checkTimer = New-Object System.Windows.Forms.Timer
$script:checkTimer.Interval = $script:checkIntervalMinutes * 60 * 1000
$script:checkTimer.Add_Tick({
    if (-not ($script:miMem -and $script:miMem.Checked)) { return }   # 监控已关则跳过
    $usage = Get-UsagePct
    # 冷却防抖已在 Invoke-Cleanup 入口统一执行（原此处的 $mins 判断已移除）
    if ($usage -gt $script:memThresholdPercent) {
        Write-Log "[监控] 内存占用 ${usage}% 超过 ${script:memThresholdPercent}%，立即清理"
        Invoke-Cleanup '内存触发'
    } else {
        Update-Tip ("占用{0}% 可用{1}GB" -f $usage, (Get-FreeGB))   # 未达标也刷新提示
    }
})

# 定时器 C：单实例 ping 监听（500ms 轮询）
#   用户在已有实例运行时再次双击快捷方式，新实例会 Set 命名事件后退出；
#   旧实例在此收到信号，弹气泡告知"已在运行"（替代旧版"杀掉接管"的粗暴方式）
$script:pingEvent = $null
try {
    $script:pingEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:mutexName + '_ping')
} catch { }
if ($script:pingEvent) {
    $script:lastPingBalloon = [datetime]::MinValue   # 气泡防抖：启动链路可能连发两次 ping
    $script:pingTimer = New-Object System.Windows.Forms.Timer
    $script:pingTimer.Interval = 500
    $script:pingTimer.Add_Tick({
        if ($script:pingEvent.WaitOne(0)) {
            # 5 秒内的重复 ping 只弹一次（快捷方式链路与 4.2 处各 ping 一次属正常双发）
            if (((Get-Date) - $script:lastPingBalloon).TotalSeconds -ge 5) {
                $script:notify.BalloonTipTitle = 'RAMMap 自动清理已在运行'
                $script:notify.BalloonTipText  = '无需重复启动，右键托盘图标可操作或退出'
                $script:notify.ShowBalloonTip(3000)
                $script:lastPingBalloon = Get-Date
            }
        }
    })
    $script:pingTimer.Start()
}

# ============================================================================
# 十三、右键菜单
# ============================================================================
$menu = New-Object System.Windows.Forms.ContextMenuStrip

# 菜单文字统一在此刷新（参数修改后联动更新，各处实时显示当前值）
# 文案区分两条自动清理链路：
#   · 定时保养：低占用线(默认60%)与清理阈值(默认80%)之间的周期性清理
#   · 内存监控：占用超清理阈值(默认80%)时的高频快速响应
function Refresh-MenuTexts {
    $script:miAuto.Text         = "定时保养（每 $($script:intervalMinutes) 分钟，占用 ${script:skipBelowPercent}%-${script:memThresholdPercent}% 之间）"
    $script:miMem.Text          = "内存监控（每 $($script:checkIntervalMinutes) 分钟检查，超 $($script:memThresholdPercent)% 立即清理）"
    $script:miSetInterval.Text  = "定时保养间隔…… $($script:intervalMinutes) 分钟"
    $script:miSetCheck.Text     = "内存检查间隔…… $($script:checkIntervalMinutes) 分钟"
    $script:miSetThreshold.Text = "清理阈值……超过 $($script:memThresholdPercent)% 立即清理"
    $script:miSetSkip.Text      = "低占用跳过……低于 $($script:skipBelowPercent)% 不自动清理"
}

# 参数输入框：弹 InputBox 并校验范围，返回新值；取消/非法输入返回 $null
function Show-ParamInput($title, $prompt, $current, $min, $max) {
    $raw = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $title, "$current")
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $n = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$n)) { return $null }
    if ($n -lt $min -or $n -gt $max) { return $null }
    return $n
}

# --- [操作] 立即清理 ---
$miNow = $menu.Items.Add('立即清理内存')
$miNow.Add_Click({ Invoke-Cleanup '手动' })

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# --- [开关] 自动清理（定时器 A） ---
$script:miAuto = New-Object System.Windows.Forms.ToolStripMenuItem("定时保养（每 $script:intervalMinutes 分钟，占用 $script:skipBelowPercent%-$script:memThresholdPercent% 之间）")
$script:miAuto.CheckOnClick = $true
$script:miAuto.Checked = $script:autoCleanEnabled   # 从持久化配置恢复
$script:miAuto.Add_Click({
    if ($script:miAuto.Checked) {
        $script:timer.Start()
        Write-Log "定时保养: 已开启（每 $script:intervalMinutes 分钟, 占用 ${script:skipBelowPercent}%-${script:memThresholdPercent}% 区间）"
    } else {
        $script:timer.Stop()
        Write-Log '定时保养: 已暂停'
    }
    $script:autoCleanEnabled = $script:miAuto.Checked   # 偏好持久化，重启不丢
    Save-Config
    Update-Tip ''
})
$menu.Items.Add($script:miAuto) | Out-Null

# --- [开关] 内存监控（定时器 B） ---
$script:miMem = New-Object System.Windows.Forms.ToolStripMenuItem("内存监控（占用超 $script:memThresholdPercent% 立即清理）")
$script:miMem.CheckOnClick = $true
$script:miMem.Checked = $script:memWatchEnabled   # 从持久化配置恢复
$script:miMem.Add_Click({
    if ($script:miMem.Checked) {
        $script:checkTimer.Start()
        Write-Log "内存监控: 已开启（每 $($script:checkIntervalMinutes) 分钟检查, 占用超过 $($script:memThresholdPercent)% 立即清理）"
    } else {
        $script:checkTimer.Stop()
        Write-Log '内存监控: 已关闭'
    }
    $script:memWatchEnabled = $script:miMem.Checked   # 偏好持久化，重启不丢
    Save-Config
    Update-Tip ''
})
$menu.Items.Add($script:miMem) | Out-Null

# --- [开关] 开机自动启动 ---
$script:miAutoStart = New-Object System.Windows.Forms.ToolStripMenuItem('开机自动启动')
$script:miAutoStart.CheckOnClick = $true
# 先按持久化偏好初始化（省一次计划任务查询，让气泡更快弹出）；
# 真实任务状态由启动流程第 2 步用 Repair-Locations 的返回值校正
$script:miAutoStart.Checked = $script:autoStartEnabled
$script:miAutoStart.Add_Click({
    $ok = Set-AutoStart $script:miAutoStart.Checked
    if ($ok) {
        $script:autoStartEnabled = $script:miAutoStart.Checked   # 偏好持久化，重启不丢
        Save-Config
    } else {
        $script:miAutoStart.Checked = -not $script:miAutoStart.Checked   # 失败则回滚勾选
    }
})
$menu.Items.Add($script:miAutoStart) | Out-Null

# --- [设置] 参数子菜单：三项参数即时生效 + 持久化 ---
$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem('参数设置')

$script:miSetInterval = $miSettings.DropDownItems.Add('自动清理间隔')
$script:miSetInterval.Add_Click({
    $n = Show-ParamInput '自动清理间隔' "常规清理间隔（分钟，1-1440）：" $script:intervalMinutes 1 1440
    if ($n) {
        $script:intervalMinutes = $n
        $script:timer.Stop(); $script:timer.Interval = $n * 60 * 1000   # 周期立即按新值生效
        if ($script:miAuto.Checked) { $script:timer.Start() }
        Save-Config; Refresh-MenuTexts
        Write-Log "参数调整: 自动清理间隔 -> $n 分钟"
    }
})

$script:miSetCheck = $miSettings.DropDownItems.Add('内存检查间隔')
$script:miSetCheck.Add_Click({
    $n = Show-ParamInput '内存检查间隔' "内存占用检查间隔（分钟，1-60）：" $script:checkIntervalMinutes 1 60
    if ($n) {
        $script:checkIntervalMinutes = $n
        $script:cooldownMinutes = $n   # 冷却时间联动
        $script:checkTimer.Stop(); $script:checkTimer.Interval = $n * 60 * 1000
        if ($script:miMem.Checked) { $script:checkTimer.Start() }
        Save-Config; Refresh-MenuTexts
        Write-Log "参数调整: 内存检查间隔 -> $n 分钟"
    }
})

$script:miSetThreshold = $miSettings.DropDownItems.Add('清理阈值')
$script:miSetThreshold.Add_Click({
    $n = Show-ParamInput '清理阈值' "内存占用超过多少百分比立即清理（50-95）：" $script:memThresholdPercent 50 95
    if ($n) {
        $script:memThresholdPercent = $n
        Save-Config; Refresh-MenuTexts
        Write-Log "参数调整: 清理阈值 -> $n%"
    }
})

$script:miSetSkip = $miSettings.DropDownItems.Add('低占用跳过')
$script:miSetSkip.Add_Click({
    $n = Show-ParamInput '低占用跳过' "占用低于多少百分比时跳过自动清理（定时保养与启动清理受此限制）（0-90，0=不跳过）：" $script:skipBelowPercent 0 90
    if ($n -ne $null) {
        $script:skipBelowPercent = $n
        Save-Config; Refresh-MenuTexts
        Write-Log "参数调整: 低占用跳过阈值 -> $n%"
    }
})

$menu.Items.Add($miSettings) | Out-Null
Refresh-MenuTexts   # 菜单文字带上当前参数值

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# --- [工具] 打开 RAMMap / 查看日志 ---
$miPath = $menu.Items.Add('设置 RAMMap 目录')
$miPath.Add_Click({ Select-RAMMapDirectory })

$miOpen = $menu.Items.Add('打开 RAMMap 窗口')
$miOpen.Add_Click({ Confirm-RAMMapRunning })

$miLog = $menu.Items.Add('查看日志')
$miLog.Add_Click({
    if (Test-Path $script:logFile) { Start-Process notepad.exe $script:logFile }
})

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# --- [退出] / [重启] ---
# 共用收尾：停定时器 -> 收托盘 -> 记日志 -> 结束消息循环（进程随后落到末尾释放锁）
function Stop-Tray($reason) {
    $script:timer.Stop()
    $script:checkTimer.Stop()
    if ($script:pingTimer)  { $script:pingTimer.Stop() }
    if ($script:startupTimer) { $script:startupTimer.Stop() }   # 启动清理尚未触发时一并停掉
    Write-Log "==== 托盘程序${reason} ===="
    $script:notify.Visible = $false
    $script:notify.Dispose()
    if ($script:pingEvent) { $script:pingEvent.Dispose() }
    $script:ctx.ExitThread()
}

$miRestart = $menu.Items.Add('重启托盘程序')
$miRestart.Add_Click({
    # 以当前管理员身份直接拉起新实例（不走 VBS→schtasks 链路，无 UAC 且更快）；
    # 新实例启动时会先等本实例释放互斥锁（最长 15 秒），随后接管托盘
    try {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta',
            '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`""
        )
        Stop-Tray '重启（新实例接管中）'
    } catch {
        Write-Log "重启失败: $($_.Exception.Message)"
    }
})

$miExit = $menu.Items.Add('退出')
$miExit.Add_Click({ Stop-Tray '退出' })

# 挂载菜单与双击行为（双击托盘图标 = 立即清理）
$script:notify.ContextMenuStrip = $menu
$script:notify.Add_DoubleClick({ Invoke-Cleanup '手动' })

# ============================================================================
# 十四、启动流程（顺序为提速专门设计：图标/气泡先行，耗时操作全部后置）
# ============================================================================
# 注：不再开机自动拉起 RAMMap 主窗口，需要时通过托盘菜单"打开 RAMMap 窗口"启动

# 1) 托盘图标 + 气泡立即显示（先给用户反馈，再做耗时工作；
#    内存查询 CIM 调用较慢，初始提示先省略，异步清理完成后会刷新）
$script:notify.BalloonTipTitle = 'RAMMap 自动清理已在后台运行'
$script:notify.BalloonTipText  = "定时保养：每 $script:intervalMinutes 分钟（占用 ${script:skipBelowPercent}%-${script:memThresholdPercent}% 之间）`n内存监控：每 $script:checkIntervalMinutes 分钟检查，超 $script:memThresholdPercent% 立即清理`n右键托盘图标可调整或退出"
$script:notify.Visible = $true
$script:notify.ShowBalloonTip(4000)

# 2) 位置自愈 + 自启对齐（耗时的计划任务操作；返回任务对象供复用，省一次重复查询）
$taskInfo = Repair-Locations   # 位置自愈：文件夹移动过则按新位置修复自启任务与快捷方式
if ($script:autoStartEnabled -and -not $taskInfo) {
    if (Set-AutoStart $true) { $script:miAutoStart.Checked = $true }
} elseif (-not $script:autoStartEnabled -and $taskInfo) {
    Set-AutoStart $false | Out-Null
    $script:miAutoStart.Checked = $false   # 勾选与真实任务状态对齐
}

# 3) 启动清理异步化：一次性 Timer 延迟 300ms 后在 UI 线程触发，
#    不阻塞上面的气泡显示；冷却豁免（'启动' 不受 lastCleanup 限制）
$script:startupTimer = New-Object System.Windows.Forms.Timer
$script:startupTimer.Interval = 300
$script:startupTimer.Add_Tick({
    $script:startupTimer.Stop()
    $script:startupTimer.Dispose()
    Invoke-Cleanup '启动'
    Update-Tip ("占用{0}% 可用{1}GB" -f (Get-UsagePct), (Get-FreeGB))
})
$script:startupTimer.Start()

# 4) 常规定时器按开关状态启动（从此刻起算下次周期）
if ($script:miAuto.Checked) { $script:timer.Start() }
if ($script:miMem.Checked)  { $script:checkTimer.Start() }

# ============================================================================
# 十五、消息循环（无窗口常驻；退出菜单触发 ExitThread 后落到此处收尾）
# ============================================================================
$script:ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($script:ctx)

$script:mutex.ReleaseMutex()
$script:mutex.Dispose()
