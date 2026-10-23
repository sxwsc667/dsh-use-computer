# 变更记录

## 0.1.0（2026-10-23）

- 首个公开版本。
- 10 个桌面工具：`desktop_start`、`desktop_stop`、`desktop_look`、`desktop_motion`、`desktop_locate`、`desktop_click`、`desktop_type`、`desktop_key`、`desktop_windows`、`desktop_do`。
- 定位两条路：先查 UIA（Windows 无障碍接口）控件树，找不到再用 UGround-V1-2B 视觉定位模型；坐标只在插件内部流转，不写进对话。
- `desktop_do` 操作脚本：一段文本脚本一次调用跑多步，用「停」控制需要人确认的位置。
- `desktop_motion` 帧环看变化，自动卸载历史截图省 token。
- 虚拟光标可见、点击穿透、单实例；助手显式开关；连按三次 ESC 急停（暂停后只有真人能恢复）。
- 命令行入口 `use-computer`，用于手工调试。

已知限制：只支持 Windows；密码框保护、危险词审批、应用白名单尚未实现。
