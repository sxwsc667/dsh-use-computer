# 变更记录

## 0.2.0（2026-10-23）

- **模型和推理程序挪到 DSH 数据目录**：默认 `%USERPROFILE%\.dsh\models\use-computer`，不再放在插件目录里。插件以后从 npm 安装、升级会覆盖插件目录，模型放在那等于每升一版重下 2.3 GB。
- 新增环境变量 `DSH_USE_COMPUTER_HOME` 作为数据目录总开关；`DSH_GROUNDING_SERVER` / `DSH_GROUNDING_MODEL` / `DSH_GROUNDING_MMPROJ` 仍可单独覆盖。
- 新增 `use-computer model` 命令：报每个文件在哪、在不在，缺了给出确切下载地址和校验值。
- 缺文件时的报错改成自带下载指引（地址、目标目录、SHA-256），不再只说"找不到文件"。
- 两个模型文件放到 GitHub Release `models-v1` 托管，README 写清下载地址、PowerShell 断点续传命令和 SHA-256 核对方法。
- 不做自动下载：文件 2.3 GB，静默下载会在限速、代理环境下卡住且用户不知情。

需要同步调整的地方：模型路径变了，原来的 `<插件>/models/` 和 `<插件>/llama.cpp/bin/` 不再被使用。升级时把这两个文件/目录挪到上面说的数据目录，或者用环境变量指回原位。

## 0.1.0（2026-10-23）

- 首个公开版本。
- 10 个桌面工具：`desktop_start`、`desktop_stop`、`desktop_look`、`desktop_motion`、`desktop_locate`、`desktop_click`、`desktop_type`、`desktop_key`、`desktop_windows`、`desktop_do`。
- 定位两条路：先查 UIA（Windows 无障碍接口）控件树，找不到再用 UGround-V1-2B 视觉定位模型；坐标只在插件内部流转，不写进对话。
- `desktop_do` 操作脚本：一段文本脚本一次调用跑多步，用「停」控制需要人确认的位置。
- `desktop_motion` 帧环看变化，自动卸载历史截图省 token。
- 虚拟光标可见、点击穿透、单实例；助手显式开关；连按三次 ESC 急停（暂停后只有真人能恢复）。
- 命令行入口 `use-computer`，用于手工调试。

已知限制：只支持 Windows；密码框保护、危险词审批、应用白名单尚未实现。
