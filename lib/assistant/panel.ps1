# AI 输出浮窗（独立进程）
#
# 作用：AI 开始操控这台电脑时，屏幕上浮一块半透明的板子，实时显示 AI 正在说什么、正在做什么。
#       这样即使用户的对话窗口被 AI 打开的窗口挡住了，也能看清 AI 的意图。
# 输入：定时轮询一个状态文件（由 use-computer 插件写），内容是 JSON：
#         { "visible": true, "action": "正在点击 (1500,600)", "text": "AI 输出的正文" }
# 输出：屏幕右下角一块窗口。进程常驻，直到被外部结束。
#
# 为什么不走命名管道：这个面板只需要"拿到最新一段文本并显示"，
#   用管道要处理并发写、断线重连、以及宿主重启后的残留连接；用文件零风险，
#   面板进程崩了也不会影响正在操作桌面的助手。
#
# 为什么不用逐像素透明的分层窗口（UpdateLayeredWindow）：
#   实测在这台机器上贴上去之后窗口全透明、只剩个别像素可见，查了很久没定位到根因。
#   改用 WinForms 自带的 Opacity 加普通绘制：窗口整体半透明、内容清晰，
#   代价是没有逐像素的圆角过渡，但稳定、可预期。
#
# 窗口特性：置顶、点击穿透、不抢焦点、不出现在 Alt+Tab。
#   点击穿透是硬要求——面板压在 AI 要操作的区域上时，鼠标必须能穿透它点到下面的窗口。

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 窗口标题：插件用它找窗口，改这里要同步改 index.js 里的同名常量
$窗口标题 = 'DSH-USE-COMPUTER-PANEL'
$面板宽 = 480
$面板高 = 340
$屏幕边距 = 24
$透明度 = 0.88

# 插件写状态的约定位置。必须和 index.js 里拼出来的路径一致
$状态文件 = Join-Path $env:TEMP 'dsh-use-computer\panel.json'

Add-Type -Namespace AssistNative -Name PanelApi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern int GetWindowLong(System.IntPtr hWnd, int nIndex);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern int SetWindowLong(System.IntPtr hWnd, int nIndex, int dwNewLong);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetLayeredWindowAttributes(System.IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);

[System.Runtime.InteropServices.DllImport("shcore.dll", SetLastError = true)]
public static extern int SetProcessDpiAwareness(int level);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDPIAware();
'@

# 和助手、光标窗一样声明 DPI 感知。不声明的话，150% 缩放下窗口尺寸和坐标都会错位
try {
    [void][AssistNative.PanelApi]::SetProcessDpiAwarenessContext([System.IntPtr]::new(-4))
} catch {
    try { [void][AssistNative.PanelApi]::SetProcessDpiAwareness(2) } catch {
        try { [void][AssistNative.PanelApi]::SetProcessDPIAware() } catch { }
    }
}

# 配色
$色背景 = [System.Drawing.Color]::FromArgb(24, 26, 33)
$色标题 = [System.Drawing.Color]::FromArgb(240, 246, 255)
$色动作 = [System.Drawing.Color]::FromArgb(120, 210, 255)
$色正文 = [System.Drawing.Color]::FromArgb(226, 233, 244)
$色分隔 = [System.Drawing.Color]::FromArgb(52, 57, 68)
$色底注 = [System.Drawing.Color]::FromArgb(132, 144, 166)

$字体标题 = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$字体动作 = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$字体正文 = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$字体底注 = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)

$刷标题 = New-Object System.Drawing.SolidBrush($色标题)
$刷动作 = New-Object System.Drawing.SolidBrush($色动作)
$刷正文 = New-Object System.Drawing.SolidBrush($色正文)
$刷底注 = New-Object System.Drawing.SolidBrush($色底注)
$刷点 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 200, 255))
$笔分隔 = New-Object System.Drawing.Pen($色分隔, 1)

<#
 作用：把当前状态画到窗口上。
 输入：Graphics、动作文字、正文。
 说明：只显示最后能放下的若干行——面板是看最新进度用的，不是看历史。
#>
function 画面板 {
    param($画布, [string]$动作, [string]$正文)

    $画布.Clear($色背景)
    $画布.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $画布.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    # 标题行
    $画布.FillEllipse($刷点, 16, 16, 9, 9)
    $画布.DrawString('DeepSeek 正在操作这台电脑', $字体标题, $刷标题, 32, 12)

    # 当前动作
    if (-not [string]::IsNullOrWhiteSpace($动作)) {
        $动作格式 = New-Object System.Drawing.StringFormat
        $动作格式.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $动作格式.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $动作矩形 = New-Object System.Drawing.RectangleF(16, 44, ($面板宽 - 32), 22)
        $画布.DrawString($动作, $字体动作, $刷动作, $动作矩形, $动作格式)
        $动作格式.Dispose()
    }

    $画布.DrawLine($笔分隔, 16, 70, $面板宽 - 16, 70)

    # 正文：从尾部往前取，保证最新内容一定可见
    $正文上边 = 78
    $正文高 = $面板高 - $正文上边 - 26
    if ([string]::IsNullOrWhiteSpace($正文)) {
        $画布.DrawString('等待 AI 输出…', $字体正文, $刷底注, 16, $正文上边)
    } else {
        # 按宽度折行。中英混排宽度不一，用固定字数会有偏差，但面板只用于看，够用
        $每行字数 = 24
        # 行距按字号的 1.5 倍算。原来固定写 19，正好等于 9.5pt 在 150% 缩放下的字高，
        # 结果是行距为零、字全贴在一起。用 GetHeight 取实际像素高，换 DPI 也不会错
        $行高 = [int][Math]::Ceiling($字体正文.GetHeight($画布) * 1.5)
        $可显示行数 = [int][Math]::Floor($正文高 / $行高)
        if ($可显示行数 -lt 1) { $可显示行数 = 1 }

        $折好的行 = New-Object System.Collections.ArrayList
        foreach ($段 in ($正文 -split "`n")) {
            $剩余 = $段.TrimEnd()
            if ($剩余.Length -eq 0) { [void]$折好的行.Add(''); continue }
            while ($剩余.Length -gt $每行字数) {
                [void]$折好的行.Add($剩余.Substring(0, $每行字数))
                $剩余 = $剩余.Substring($每行字数)
            }
            [void]$折好的行.Add($剩余)
        }

        $起始 = [Math]::Max(0, $折好的行.Count - $可显示行数)
        $y = $正文上边
        for ($i = $起始; $i -lt $折好的行.Count; $i++) {
            $画布.DrawString($折好的行[$i], $字体正文, $刷正文, 16, $y)
            $y += $行高
        }
    }

    $画布.DrawString('点击穿透，不挡操作', $字体底注, $刷底注, 16, ($面板高 - 22))
}

# ---- 窗体 ----
$窗体 = New-Object System.Windows.Forms.Form
$窗体.Text = $窗口标题
$窗体.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$窗体.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$窗体.ShowInTaskbar = $false
$窗体.TopMost = $true
$窗体.MinimizeBox = $false
$窗体.MaximizeBox = $false
$窗体.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$窗体.BackColor = $色背景
$窗体.Width = $面板宽
$窗体.Height = $面板高
# 整体半透明。这是 WinForms 自带的能力，比自己做逐像素分层可靠得多
# 双缓冲。不开的话每次重绘都先擦背景再画内容，屏幕上就是持续闪烁。
# DoubleBuffered 是 protected 属性，PowerShell 直接赋值会报"找不到属性"，
# 必须走反射调 SetStyle。
try {
    $样式方法 = $窗体.GetType().GetMethod(
        'SetStyle',
        [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
    $样式值 = [int]([System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor
        [System.Windows.Forms.ControlStyles]::UserPaint -bor
        [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer)
    if ($null -ne $样式方法) { [void]$样式方法.Invoke($窗体, @($样式值, $true)) }
} catch { }
# 分层透明由 SetLayeredWindowAttributes 控制，不用 WinForms 的 Opacity
# 先躲到屏幕外，等真有内容再露面
$窗体.Location = New-Object System.Drawing.Point(-2000, -2000)

# 跨事件的状态存在窗体自己的 Tag 里。
# 不能用 $script: 前缀：实测事件处理器里写进去、另一个处理器里读出来是空的。
$窗体.Tag = [pscustomobject]@{
    动作 = ''
    正文 = ''
    可见 = $false
    上次文件时间 = [DateTime]::MinValue
    诊断计数 = 0
    上次签名 = ''
}

$诊断日志 = Join-Path $env:TEMP 'dsh-use-computer\panel-diag.txt'
function 记诊断([string]$消息) {
    try {
        Add-Content -LiteralPath $诊断日志 -Value ((Get-Date -Format 'HH:mm:ss.fff') + ' ' + $消息) -Encoding utf8
    } catch { }
}

$窗体.add_Paint({
    param($发件人, $事件参数)
    画面板 -画布 $事件参数.Graphics -动作 $窗体.Tag.动作 -正文 $窗体.Tag.正文
})

$窗体.add_Load({
    记诊断('Load 触发')
    $句柄 = $窗体.Handle
    $扩展样式 = [AssistNative.PanelApi]::GetWindowLong($句柄, -20)
    # 0x00000020 点击穿透（鼠标落在面板上时，命中的是它下面的窗口）
    # 0x08000000 不激活（点它不抢焦点）
    # 0x00000080 工具窗口（不进 Alt+Tab）
    # 0x00080000 分层窗口：有了它才能设整体透明度，也是 0x20 点击穿透生效的前提。
    # 单独挂 0x20 而不带 0x80000（实测）窗口会完全不绘制，屏幕上什么都没有，
    # 但 IsWindowVisible 仍然返回 True——这个组合是之前面板"看不见"的根因。
    # 0x00000020 点击穿透（鼠标落在面板上时，命中的是它下面的窗口）
    # 0x08000000 不激活（点它不抢焦点）
    # 0x00000080 工具窗口（不进 Alt+Tab）
    $扩展样式 = $扩展样式 -bor 0x00080000 -bor 0x00000020 -bor 0x08000000 -bor 0x00000080
    [void][AssistNative.PanelApi]::SetWindowLong($句柄, -20, $扩展样式)
    # 分层窗口必须显式给出分层属性，否则没有任何内容会被合成到屏幕上。
    # 0x02 = LWA_ALPHA，用整体 alpha 控制半透明；位图内部保持不透明。
    $整体透明度 = [byte][Math]::Round($透明度 * 255)
    [void][AssistNative.PanelApi]::SetLayeredWindowAttributes($句柄, 0, $整体透明度, 0x02)

    # 钉在屏幕右下角，用 Win32 的物理像素
    $屏幕 = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $x = $屏幕.X + $屏幕.Width - $面板宽 - $屏幕边距
    $y = $屏幕.Y + $屏幕.Height - $面板高 - $屏幕边距 - 60
    # 插入位置必须传 HWND_TOPMOST(-1)。传 0（普通顶层）会把 Form.TopMost 设的置顶覆盖掉，
    # 结果面板被别的窗口压在下面，只露出没被挡住的那一截。
    # 标志位只留 SWP_NOACTIVATE(0x10)：不需要 SWP_NOZORDER，否则又改不动 Z 序。
    $定位 = [AssistNative.PanelApi]::SetWindowPos(
        $句柄, [System.IntPtr]::new(-1), $x, $y, $面板宽, $面板高, 0x0010)
    记诊断("SetWindowPos 到 ($x,$y) 屏幕=$($屏幕.Width)x$($屏幕.Height) 结果=$定位")
})

# 轮询状态文件，200 毫秒一次
$定时器 = New-Object System.Windows.Forms.Timer
$定时器.Interval = 200
$定时器.add_Tick({
    $序号 = $窗体.Tag.诊断计数 + 1
    $窗体.Tag.诊断计数 = $序号


    $要显示 = $false
    if (Test-Path -LiteralPath $状态文件) {
        try {
            $信息 = Get-Item -LiteralPath $状态文件
            if ($信息.LastWriteTime -ne $窗体.Tag.上次文件时间) {
                $窗体.Tag.上次文件时间 = $信息.LastWriteTime
                $原文 = [System.IO.File]::ReadAllText($状态文件, [System.Text.Encoding]::UTF8)
                if (-not [string]::IsNullOrWhiteSpace($原文)) {
                    $对象 = $原文 | ConvertFrom-Json
                    if ($null -ne $对象) {
                        $新动作 = ''
                        $新正文 = ''
                        if ($null -ne $对象.action) { $新动作 = [string]$对象.action }
                        if ($null -ne $对象.text) { $新正文 = [string]$对象.text }
                        if ($null -ne $对象.visible) { $要显示 = [bool]$对象.visible }
                        $窗体.Tag.动作 = $新动作
                        $窗体.Tag.正文 = $新正文
                    }
                }
            } else {
                # 文件没变，沿用上一轮的状态
                $要显示 = $窗体.Tag.可见
            }
        } catch {
            # 正在写、读了一半解析失败：这一轮跳过
            return
        }
    }

    if ($要显示 -ne $窗体.Tag.可见) {
        $窗体.Tag.可见 = $要显示
        if ($要显示) {
            [void][AssistNative.PanelApi]::ShowWindow($窗体.Handle, 4)  # SW_SHOWNOACTIVATE
            # 显示之后再钉一次置顶。窗口隐藏/显示会把 TOPMOST 丢掉（实测显示状态下
            # 扩展样式里查不到 WS_EX_TOPMOST），丢了就会被别的窗口压在下面只露出半截。
            $钉屏 = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $钉x = $钉屏.X + $钉屏.Width - $面板宽 - $屏幕边距
            $钉y = $钉屏.Y + $钉屏.Height - $面板高 - $屏幕边距 - 60
            # 先用属性接口重设一次置顶（它内部会调 SetWindowPos 到 HWND_TOPMOST），
            # 再用 SetWindowPos 钉住位置和尺寸
            $窗体.TopMost = $false
            $窗体.TopMost = $true
            [void][AssistNative.PanelApi]::SetWindowPos(
                $窗体.Handle, [System.IntPtr]::new(-1), $钉x, $钉y, $面板宽, $面板高, 0x0010)
            记诊断('显示面板')
        } else {
            [void][AssistNative.PanelApi]::ShowWindow($窗体.Handle, 0)  # SW_HIDE
            记诊断('隐藏面板')
        }
    }

    if ($要显示) {
        # 只在内容真的变了才重绘。原来每 200 毫秒无条件 Invalidate 一次，
        # 就算内容没动也整窗重画，屏幕上就是高频闪烁。
        $签名 = $窗体.Tag.动作 + [char]1 + $窗体.Tag.正文
        if ($签名 -ne $窗体.Tag.上次签名) {
            $窗体.Tag.上次签名 = $签名
            $窗体.Invalidate()
        }
    }
})

$窗体.add_Shown({
    记诊断('Shown 触发，启动定时器')
    $定时器.Start()
})

[System.Windows.Forms.Application]::Run($窗体)
