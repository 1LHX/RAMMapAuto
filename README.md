# RAMMapAuto

Windows 内存自动清理托盘常驻工具。基于 PowerShell + [Sysinternals RAMMap](https://learn.microsoft.com/sysinternals/downloads/rammap)，定时清空进程工作集（Working Set），并在游戏运行时自动切换保护模式，防止游戏因内存被换出而卡顿。

## 功能特性

- **常规定时清理**：默认每 30 分钟清空进程工作集（1-1440 分钟可调）
- **内存监控**：定时检查物理内存占用，超过阈值（默认 80%）立即清理
- **低占用跳过**：占用低于阈值时跳过自动清理，避免无谓换页
- **游戏保护模式**：检测到游戏进程时自动改用逐进程清理，跳过游戏与系统关键进程
- **游戏名单可配置**：在配置 JSON 中增删受保护的游戏，无需改脚本
- **托盘常驻**：右键菜单控制一切，双击图标立即清理
- **开机自启**：借道计划任务以最高权限静默启动，全程无 UAC 弹窗
- **参数持久化**：所有设置与开关状态保存到 JSON，重启不丢
- **位置自愈**：文件夹整体移动后自动修复自启任务与桌面快捷方式
- **日志轮转**：运行日志超 512KB 自动截断，不会无限增长

## 依赖

- Windows 10 / 11
- PowerShell 5.1+（系统自带）
- [RAMMap](https://learn.microsoft.com/sysinternals/downloads/rammap)（Sysinternals）——默认路径 `E:\Software\RAMMap\RAMMap`，请按实际位置修改脚本顶部 `$rammapDir`

## 使用方法

1. 下载 `RAMMapTray.ps1` 与 `启动RAMMap自动清理.vbs`，放入同一目录
2. 修改脚本顶部 `$rammapDir` 为你的 RAMMap 所在目录
3. 右键 `RAMMapTray.ps1` →「使用 PowerShell 运行」，首次会请求一次管理员权限（UAC）
4. 程序常驻托盘，右键图标即可操作：

```
立即清理内存
────────────
☑ 自动清理（每 30 分钟）
☑ 内存监控（占用超 80% 立即清理）
☑ 开机自动启动
参数设置 ▸  自动清理间隔 / 内存检查间隔 / 清理阈值 / 低占用跳过
────────────
打开 RAMMap 窗口
查看日志
────────────
退出
```

## 清理策略

| 触发源 | 冷却防抖 | 低占用跳过 | 说明 |
|--------|:---:|:---:|------|
| 手动（菜单/双击） | 豁免 | 豁免 | 用户明确意图，无条件执行 |
| 内存触发 | 受限 | 豁免 | 占用超阈值立即清理 |
| 定时 | 受限 | 受限 | 周期性兜底清理 |
| 启动 | 豁免 | 受限 | 开机后异步清理一次 |

游戏未运行时使用 `RAMMap -Ew` 全局清理（释放量最大）；检测到游戏进程时改用 `EmptyWorkingSet` API 逐进程清理，跳过游戏及约 28 个系统关键进程（dwm / explorer / audiodg 等）。

## 配置文件

`rammap_tray_config.json`（首次从菜单保存参数后生成）：

```json
{
    "intervalMinutes": 30,
    "checkIntervalMinutes": 5,
    "memThresholdPercent": 80,
    "skipBelowPercent": 60,
    "autoStartEnabled": true,
    "autoCleanEnabled": true,
    "memWatchEnabled": true,
    "gameProcessNames": ["YuanShen", "GenshinImpact"]
}
```

- 删除该文件即恢复脚本默认值
- `gameProcessNames` 填游戏进程名（不带 `.exe`），检测到任一在运行即进入保护模式

## 工作原理

1. **无 UAC 常驻**：首次运行注册计划任务（最高权限 + 登录触发），之后 `wscript` 静默启动 PowerShell 脚本，借 `schtasks /run` 触发提权实例，全程无弹窗
2. **单实例接管**：互斥锁保证单实例，重复启动会结束旧实例并接管
3. **清理机制**：`RAMMap -Ew` 或 `EmptyWorkingSet`（等价 `SetProcessWorkingSetSize(-1,-1)`）将工作集页面移出物理内存，逼迫系统释放 standby list 供活跃进程使用

## 文件说明

| 文件 | 说明 |
|------|------|
| `RAMMapTray.ps1` | 主脚本（需 UTF-8 BOM 编码） |
| `启动RAMMap自动清理.vbs` | 无窗口启动器（计划任务与快捷方式入口） |
| `rammap_tray_config.json` | 参数持久化（本地生成，不入库） |
| `rammap_auto.log` | 运行日志（本地生成，不入库） |

## 常见问题

**Q: 为什么手动清理后可用内存很快又降回去了？**
工作集清理只是把不活跃页面换出，进程再次活跃时页面会被调回。本工具的价值在于周期性压缩内存占用峰值，适合物理内存偏小的机器。

**Q: 游戏保护模式能保护其他游戏吗？**
可以，把游戏进程名加入配置文件的 `gameProcessNames` 即可。

**Q: 提示找不到 RAMMap？**
修改脚本顶部 `$rammapDir` 为实际安装目录，确保其中存在 `RAMMap64.exe` 或 `RAMMap.exe`。

## License

[MIT](LICENSE)
