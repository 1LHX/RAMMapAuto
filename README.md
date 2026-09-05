# RAMMapAuto

Windows 内存自动清理托盘工具，基于 PowerShell 和 Sysinternals RAMMap，支持定时保养、内存阈值监控、手动清理和游戏保护模式。

## 功能

- 定时保养：按设定间隔清理，低于低占用阈值时跳过。
- 内存监控：周期检查物理内存，超过阈值立即清理。
- 手动清理：托盘菜单或双击托盘图标，无条件执行。
- 游戏保护：检测到游戏后逐进程清理，跳过游戏和系统关键进程。
- 托盘控制：开关自动清理、内存监控、开机启动，打开 RAMMap 和日志。
- 路径自愈、单实例保护、日志轮转和清理超时保护。

## 环境要求

- Windows 10/11
- Windows PowerShell 5.1+
- RAMMap 目录中存在 `RAMMap64.exe` 或 `RAMMap.exe`
- 首次运行允许管理员权限

## 使用

双击 `启动RAMMap自动清理.vbs`，或直接运行 `RAMMapTray.ps1`。程序启动后驻留系统托盘，右键图标操作。RAMMap 不在默认目录时，使用“设置 RAMMap 目录”选择目录，程序会验证并保存路径。

## 配置

配置文件为 `rammap_tray_config.json`，由程序自动保存；删除后恢复默认值。

```json
{
  "configVersion": 1,
  "rammapDir": "E:\\Software\\RAMMap\\RAMMap",
  "intervalMinutes": 30,
  "checkIntervalMinutes": 2,
  "memThresholdPercent": 80,
  "skipBelowPercent": 60,
  "autoStartEnabled": true,
  "autoCleanEnabled": true,
  "memWatchEnabled": true,
  "gameProcessNames": ["YuanShen", "GenshinImpact", "GenshinImpact-2", "HYP", "HYPHelper", "StarRail"]
}
```

范围：`intervalMinutes` 为 1-1440；`checkIntervalMinutes` 为 1-60，并作为自动清理冷却时间；`memThresholdPercent` 为 50-95；`skipBelowPercent` 为 0-90。游戏进程名可带 `.exe`，匹配时忽略大小写。

## 清理策略

游戏未运行时调用 `RAMMap -Ew` 全局清理。游戏运行时调用 Win32 `EmptyWorkingSet` 逐进程清理，跳过游戏、系统关键进程和工作集小于 50 MB 的进程。自动触发受冷却时间和低占用阈值限制；手动清理不受限制。RAMMap 执行超过 120 秒会终止并写入日志，非零退出码也会记录。

## 自检

以下命令只检查脚本语法、配置 JSON 和 RAMMap 路径，不启动托盘或执行清理：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-RAMMapTray.ps1
```

## 日志与排查

`rammap_auto.log` 可通过托盘菜单“查看日志”打开。找不到 RAMMap 时检查目录和文件名；开机启动异常时检查 `RAMMapAutoTray` 计划任务；清理异常时查看日志中的退出码、耗时和异常信息。

## 文件

| 文件 | 说明 |
| --- | --- |
| `RAMMapTray.ps1` | 主程序和托盘菜单 |
| `启动RAMMap自动清理.vbs` | 隐藏窗口启动器 |
| `rammap_tray_config.json` | 本地配置 |
| `rammap_auto.log` | 运行日志 |
| `Test-RAMMapTray.ps1` | 无副作用自检 |

## 许可证

[MIT](LICENSE)
