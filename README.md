# use-computer：让 DSH 直接操作 Windows 桌面

`use-computer` 是给 DSH（DeepSeek Harness，一个把模型、工具、会话组装起来干活的宿主）写的插件。装上之后，模型可以直接看屏幕、找控件、点按、打字、按键，完成"在记事本里写一段话并保存""在浏览器里点开某个菜单"这类真实的桌面操作。

> **只支持 Windows 10 / 11。** macOS 和 Linux 没有实现，也没有验证，不在承诺范围内。

## 它解决什么问题

桌面操作类工具不少，这个插件把力气花在三个地方。

### 一、坐标不进对话

常规做法是：先用视觉模型算出坐标，把坐标返回给对话，再让对话里的模型拿着坐标去点。问题在于，对话里的模型拿到坐标之后**没有任何办法验证它**，只能照着传。

这里的做法不一样：

- `desktop_locate` 接受一句人话（例如"浏览器工具栏里的刷新按钮"），在插件内部算出位置、把可见光标挪过去、裁一张以目标为中心的近景图；
- 返回给对话的只有那张图，**没有坐标**；
- `desktop_click` 不传坐标时，直接点光标当前所在的位置。

所以对话里的模型只需要看图确认"是不是它"，不需要算、也不需要核对屏幕坐标。坐标只在插件进程和定位模型之间流转。

### 二、先查控件树，查不到才叫专用小模型

定位有两条路，按"快、准、不花模型"排序：

1. **UIA（Windows 无障碍接口）控件树**：按钮、菜单、链接、输入框在 Windows 里都有无障碍名字，命中了就直接拿控件自己声明的矩形中心，100% 准，常见耗时 300~450 毫秒，不花模型。
2. **视觉定位**：目标没有可读名字时（桌面图标、画布里的东西、游戏画面），才截图交给 UGround-V1-2B（一个 2B 参数的专用定位小模型，由本机 llama.cpp 的 llama-server 提供服务），常见耗时 190~800 毫秒。

UIA 那条路设了分数门槛（低于 75 分当没找到）和容器降权，避免"找'新会话'却蹭到名字叫'会话'的整块面板"这种误点。视觉模型有个已知脾气：**它不会说"这里没有"**，所以范围给得越紧越准，`region` 参数就是干这个的。

### 三、一段脚本干一串活，用「停」控制确认点

一个个调工具时，每动一下都要等模型把话说完、再等下一次请求。实测里，本地执行只占几十到几百毫秒，大头全是往返。

`desktop_do` 接受一段文本脚本，一次调用连做十几步。脚本里写不写「停」由模型自己决定：

- 没把握：`找 保存按钮` → `停`，看完图确认了再发下一段；
- 有把握：整段不写停，一口气跑完。

这样往返次数从"动作数"降到"确认次数"，而"点之前先看一眼"这道检查一次都没少。

### 另外两件事

- **`desktop_motion` 看变化**：助手每秒记一帧、滚动保留 40 秒，按"上次把图交给模型"到现在这段时间取帧，拼成一张带时刻的联系表。动画、加载中、进度条、视频画面这些只有看变化才看得懂。
- **图看完就扔**：每张截图只在产生它的那一轮请求里发一次，之后被主动标记卸载，后续请求里只剩一行带路径的占位文字。要重看，用 `read_image` 按路径再读。这一条省的是 token，不影响功能。

## 工具清单

插件在主对话里注册 10 个工具，没有中间子代理：

| 工具 | 作用 | 常用参数 |
| --- | --- | --- |
| `desktop_start` | 显式启动桌面助手进程（幂等，已在跑就直接返回） | 无 |
| `desktop_stop` | 关掉助手和屏幕上的光标；之后其他工具会报错，要恢复必须显式再启动 | 无 |
| `desktop_look` | 截一张全屏图，返回路径、尺寸和坐标换算比例 | `maxWidth` |
| `desktop_motion` | 把最近一段时间的若干帧拼成联系表，用来看变化 | `count`（2~9，默认 4） |
| `desktop_locate` | 一句人话 → 算位置、挪光标、裁近景图；**不返回坐标** | `target`、`region`、`window` |
| `desktop_click` | 点光标当前位置；只有自己算过坐标时才传 `x`/`y` | `x`、`y`、`button`、`count` |
| `desktop_type` | 往当前焦点窗口输入文字，支持中文 | `text`、`x`、`y` |
| `desktop_key` | 发组合键，如 `ctrl+s`、`enter`、`alt+f4` | `keys` |
| `desktop_windows` | 列出顶层窗口的标题、进程号、位置和尺寸 | 无 |
| `desktop_do` | 按脚本一次执行多个动作 | `script` |

常规流程是：`desktop_locate` → 看图确认 → `desktop_click`（不传坐标）。要往某个框里打字，先点进去拿键盘焦点，再 `desktop_type`；光标挪过去不等于焦点过去了。

## 操作脚本

`desktop_do` 的脚本一行一条指令，`#` 开头是注释：

| 指令 | 作用 |
| --- | --- |
| `区域 x y 宽 高` | 限定后面所有「找」「看」的搜索范围（屏幕物理像素），强烈建议写在最前面 |
| `找 <描述>` | 定位一个东西，自动编号 1、2、3…，并截一张它周围的图 |
| `点 [编号] [双击\|右键\|中键]` | 点某个编号的位置；不给编号就点最新找到的那个 |
| `打 <文字>` | 往当前焦点窗口打字 |
| `键 <组合键>` | 例如 `键 enter`、`键 ctrl+s` |
| `等 <毫秒>` | 等界面反应（上限 10 秒） |
| `看 <描述>` | 定位并截图，不点 |
| `停` | 执行到这里停下，把这一段的图交回来让人判断 |

一个例子：

```
区域 0 0 800 600
找 顶部搜索框
停
点
打 今天的天气
键 enter
```

第 1 行限定范围，第 3 行「停」把图交回来；确认光标确实在搜索框上之后，才有第 4~6 行。

## 安装

### 1. 放好插件

把仓库克隆到本机一个固定的目录，例如：

```
git clone https://github.com/sxwsc667/dsh-use-computer.git E:\projects\dsh-use-computer
```

### 2. 下载定位要用的文件（可选，但强烈建议）

不装这些文件时，插件仍能操作**有 UIA 名字的控件**（保存、确定、关闭这类）；遇到图标、画布、游戏画面会报错，因为视觉那条路没有可用的服务。

**插件不会自己下载任何东西。** 文件加起来 2.3 GB，下不下、下到哪由你决定，所以下面把地址和位置都写清楚，照着放就行。

#### 放在哪

全部放在 DSH 数据目录下的固定路径（默认 `%USERPROFILE%\.dsh\models\use-computer`）：

```
%USERPROFILE%\.dsh\models\use-computer\
├── UGround-V1-2B-gguf\
│   ├── UGround-V1-2B.Q4_K_M.gguf      940 MB
│   └── mmproj-UGround-V1-2B.f16.gguf  1270 MB
└── llama.cpp\
    └── bin\
        └── llama-server.exe
```

#### 准备两个模型文件（没有现成下载地址）

这两个 GGUF 是从魔搭（ModelScope）上的原始权重 `osunlp/UGround-V1-2B` 自己转出来的，官方没有发布 GGUF，仓库也不托管（2.2 GB，不适合进 git，也不适合放 Release——本机实测上传只有 240 KB/s，2.2 GB 要两个多小时）。

转换步骤在 [DESIGN.md](DESIGN.md) 第七节「数据从哪来」，概括是三步：

1. `convert_hf_to_gguf.py` 不带 `--mmproj` 转语言部分（约 2.9 GB f16）；
2. 带 `--mmproj` 单独转视觉塔（约 1.3 GB）——一次只出一样，别指望一条命令全出；
3. 用 `llama-quantize` 把语言部分压到 Q4_K_M。

也可以从别处拿同名同哈希的文件，核对下面这两个值就说明是同一份：

```
8536bb397371006d06afa5047453e6a8e224d2ace299be68533453f7b3c7a849  UGround-V1-2B.Q4_K_M.gguf      986,046,624 字节
dfcf96e6a1b3b19e89480388f5edc8e49a1ac7bef3533cf17245c5fd92124a54  mmproj-UGround-V1-2B.f16.gguf  1,331,655,712 字节
```

```powershell
$d = "$env:USERPROFILE\.dsh\models\use-computer\UGround-V1-2B-gguf"
New-Item -ItemType Directory -Force -Path $d | Out-Null
# 把两个文件放进 $d 之后核对：
Get-FileHash "$d\UGround-V1-2B.Q4_K_M.gguf" -Algorithm SHA256
Get-FileHash "$d\mmproj-UGround-V1-2B.f16.gguf" -Algorithm SHA256
```

#### 下载推理程序

用 llama.cpp 官方的 Windows 预编译包（`b11838` 的 CPU 版，约 23 MB）：

```
https://github.com/ggml-org/llama.cpp/releases/download/b11838/llama-b11838-bin-win-cpu-x64.zip
```

```powershell
$root = "$env:USERPROFILE\.dsh\models\use-computer"
curl.exe -L -o "$root\llama.zip" "https://github.com/ggml-org/llama.cpp/releases/download/b11838/llama-b11838-bin-win-cpu-x64.zip"
Expand-Archive "$root\llama.zip" -DestinationPath "$root\llama.cpp" -Force
Get-ChildItem "$root\llama.cpp" -Recurse -Filter llama-server.exe
```

命令会打印出实际路径；**只要解压出来的 `llama-server.exe` 不在 `$root\llama.cpp\bin\` 下，就把 `bin` 这一层补上或者整目录挪过去**，让最终路径是 `$root\llama.cpp\bin\llama-server.exe`。

有 N 卡想更快的话，可以换同一版本的 CUDA 或 Vulkan 包（`llama-b11838-bin-win-cuda-12.4-x64.zip` 约 260 MB，还要再下一个 `cudart` 运行库包），解压到同一个位置；速度提升明显，但显存不够时会退回 CPU，效果因机器而异。

#### 检查放对了没有

```
use-computer model
```

它会逐个报每个文件在不在、缺了该下哪个地址。不想放默认位置也没关系，用环境变量指过去，见下一节。

> 为什么不自动下载：模型 2.3 GB，自动下会在没网、限速、公司代理的环境里静默卡住，而且用户根本不知道硬盘上多了什么。插件只负责说清楚"放哪、去哪拿、怎么核对"。

### 3. 挂进 DSH

最省事的方式是从 npm 装进 profile：

```
dsh plugin --profile web add dsh-use-computer
```

装完重启 DSH。插件的 `cordis.patch.yml` 会自动把它挂进宿主根层，不需要手写工具注册。

要改代码、想让自己本地的源码生效时，用 `link:` 挂源码目录（这也是开发时的做法）：

```json
{
  "dependencies": {
    "dsh-use-computer": "link:E:/projects/dsh-use-computer"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "dsh-use-computer"
      ]
    }
  }
}
```

然后在 profile 目录执行 `pnpm install`，重启 DSH。

**两种方式互斥**：`link:` 指向源码目录时，profile 里的插件就是那个目录，升级、重装都不会覆盖它；用 npm 装则是 `node_modules` 里的真实副本，改源码不影响运行中的那份。推荐"源码一份、运行一份"：源码留在自己的目录里改，运行用 npm 装。插件目录里不再放模型和推理程序，所以换哪种方式都不需要重下 2.3 GB。

如果 profile 开了热重载（`hmr`），可以把插件目录加进监听列表：

```yaml
- id: hmr
  config:
    root:
      - E:/projects/dsh-use-computer
```

注意：热重载只盯着 `index.js`。改 `lib/` 下的文件不会触发重载，要么重启宿主，要么随便改一下 `index.js`（哪怕是注释）让它重新加载。

### 4. 命令行（可选）

插件带一个命令行入口，用来手工调试，和模型调的是同一个助手进程：

```
use-computer status
use-computer move 800 400
use-computer look --max-width 1600
use-computer windows --json
use-computer model
```

`use-computer model` 只报现状：每个模型文件在哪、在不在、缺了去哪里下。它不会替你下载。

## 配置

| 环境变量 | 默认值 | 作用 |
| --- | --- | --- |
| `DSH_USE_COMPUTER_HOME` | `%USERPROFILE%\.dsh\models\use-computer` | 下面三个相对它定位的数据目录 |
| `DSH_GROUNDING_SERVER` | `<数据目录>\llama.cpp\bin\llama-server.exe` | llama-server 可执行文件路径 |
| `DSH_GROUNDING_MODEL` | `<数据目录>\UGround-V1-2B-gguf\UGround-V1-2B.Q4_K_M.gguf` | 模型权重路径 |
| `DSH_GROUNDING_MMPROJ` | `<数据目录>\UGround-V1-2B-gguf\mmproj-UGround-V1-2B.f16.gguf` | 视觉投影（mmproj）路径 |
| `DSH_GROUNDING_PORT` | `8080` | 定位服务端口 |
| `DSH_GROUNDING_HOST` | `127.0.0.1` | 定位服务地址 |

模型和推理程序放在数据目录、而不是插件目录，是因为插件从 npm 装下来以后，重装、升级都会覆盖插件目录；数据目录不动，2.3 GB 就不用每升一次版本重下一遍。

模型服务由插件按需拉起，加载完成后跨调用复用；助手进程常驻，只由 `desktop_start` / `desktop_stop` 开关。

## 安全边界（请先读）

这个插件**直接在用户真实桌面上动手，没有沙箱**。它能做的事和用户自己用鼠标键盘能做的事一样多。

目前只有一道闸：

- **连按三次 ESC 急停**：1 秒内按三次 ESC，切换暂停 / 恢复。暂停时，点击、移动、打字、按键、滚动全部拒绝并报错；截图、列窗口、查询类操作放行，方便人看看屏幕上到底发生了什么。
- 暂停**只能由真人按 ESC 解除**：暂停期间连工具自己发的 ESC 也会被拒，所以调用方不可能自己解锁。

**以下三样目前都没做**，不要指望它们：

- 密码框保护（输入前判断目标是不是密码框）；
- 危险词审批（例如删除、格式化这类操作前的二次确认）；
- 应用白名单（限定只能操作哪些程序）。

也就是说，**唯一的人为控制手段就是那三次 ESC**。在让它长时间自动操作之前，请自己评估风险。

## 平台与依赖

| 项目 | 要求 / 状态 |
| --- | --- |
| Windows 10 / 11 | ✅ 本机实测（Windows 10/11 的 `powershell.exe` 5.1） |
| macOS / Linux | ❌ 没有实现 |
| Node.js | ≥ 22 |
| PowerShell | 5.1（系统自带） |
| GPU | 视觉定位需要能跑 llama.cpp 的环境。本机用 NVIDIA CUDA 实测；纯 CPU 未验证 |

插件本体不依赖任何第三方原生驱动或外部二进制。桌面能力用 PowerShell 加 .NET 现成组件实现，截图、控件树、点击、输入都不需要额外安装。

## 已知限制

- **只做 Windows**，不写"理论上支持"。
- **多显示器按虚拟屏幕整体处理**，不能按显示器分别寻址。
- **视觉模型不会说"这里没有"**：目标不在你给的 `region` 里时，它照样会挑区域内最像的东西返回一个点。所以范围要给准。
- **帧环只有 1 fps**：看"界面在怎么动"够用，看 24 fps 的视频只能看到每 24 帧取 1 帧。真要看视频内容，先用 ffmpeg 抽关键帧。
- **历史图不能回看**：主动卸载之后，模型只能按路径重读或重新定位。
- 没有录制回放、没有操作视频导出。

## 排错

| 现象 | 可能原因 | 怎么办 |
| --- | --- | --- |
| 提示「桌面助手已经被 desktop_stop 关掉了」 | 之前显式关过 | 先调 `desktop_start` |
| 提示「用户连按三次 ESC，已暂停鼠标操作」 | 人按了急停 | 由真人再按三次 ESC 恢复；调用方重试无效 |
| 报错找不到视觉定位所需的文件 | 模型或 llama-server 没放对位置 | 跑 `use-computer model` 看缺哪个、去哪下；或按报错里的目录放好，或用 `DSH_GROUNDING_*` 环境变量指定 |
| UIA 找不到，视觉也定位失败 | 目标不在 `region` 里，或描述太模糊 | 给一个更紧的 `region`，或换一种说法 |
| 助手起不来 | 看日志 | `%TEMP%\dsh-use-computer\assistant.log` |
| 视觉定位起不来 | 看日志 | `%TEMP%\dsh-use-computer\grounding.log` |
| 点了但界面没反应 | 有可能被其他窗口挡住，或需要先聚焦 | 先 `desktop_click` 把窗口点活，再操作；必要时用 `desktop_windows` 确认窗口位置 |

## 目录结构

```
use-computer/
├── index.js                 # 工具注册和主流程
├── cordis.patch.yml         # bundle patch：把插件插进宿主
├── lib/
│   ├── assistant-client.js  # 拉起/关闭桌面助手、发请求
│   ├── grounding-client.js  # 视觉定位客户端（llama-server）
│   ├── model-store.js       # 模型文件在哪、齐不齐、缺了去哪下（不下载）
│   ├── panel-client.js      # 桌面浮窗控制端
│   ├── pipe-protocol.js     # 命名管道协议
│   └── assistant/
│       ├── assistant.ps1    # 桌面助手（截图、UIA、点击、输入、帧环、急停）
│       ├── cursor.ps1       # 可见的虚拟光标窗
│       └── panel.ps1        # 浮窗
├── bin/
│   └── use-computer.js      # 命令行入口
├── DESIGN.md                # 设计决策和踩坑记录（很长，按时间分节）
└── CHANGELOG.md
```

模型和推理程序**不在这个目录里**，见上面"2. 下载定位要用的文件"。

`lib/` 和 `bin/` 是源码，不是构建产物，要提交。

## 开发注意

- `lib/assistant/*.ps1` 由 `powershell.exe` 5.1 用 `-File` 启动，**必须带 UTF-8 BOM**。没有 BOM 的中文会被按本地编码解码，脚本直接语法崩溃。改完确认前三个字节还是 `EF BB BF`。
- 热重载只盯 `index.js`，改 `lib/` 要重启或戳一下 `index.js`。
- 工具描述里的每一条"坑"都对应一次真实误操作，别随手删。

## 许可证

MIT。工程决策、实测数据和踩坑记录都在 [DESIGN.md](DESIGN.md)。
