# 虚拟光标窗口（独立进程）
#
# 作用：在屏幕上画一条看得见的大肥鱼，让用户能看清"模型正在指哪里"。
#       这个窗口置顶、点击穿透、不抢焦点，所以它压在别的窗口上面也不会挡住操作。
# 输入：无。它的位置由桌面助手进程（assistant.ps1）通过 SetWindowPos 直接改写，
#       双方只靠窗口标题认亲，不走管道。
# 输出：屏幕上一张小鱼的窗口。进程一直运行，直到被外部结束。
#
# 之所以单开一个进程：WinForms 窗体要跑消息循环（Application.Run 会一直占住线程），
# 而桌面助手要同步地读管道。两件事塞进一个进程会互相卡住，拆开各自都简单。
#
# 单实例：用系统级命名互斥体把关。已经有一个在跑时，本次启动直接作废，
# 不会出现"一条鱼变两条鱼"、也不会两条鱼抢同一个标题导致助手找错。

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 窗口标题是桌面助手 FindWindow 的唯一线索，改这里必须同步改 assistant.ps1 里的同名常量
$窗口标题 = 'DSH-USE-COMPUTER-CURSOR'
$窗口边长 = 32

# ---- 单实例把关 ----
# 先抢互斥体，抢不到说明已经有一条鱼在屏幕上了，本次什么都不做
$是否新建 = $false
try {
    $单实例锁 = New-Object System.Threading.Mutex($true, 'Local\DSH-USE-COMPUTER-CURSOR-WINDOW', [ref]$是否新建)
} catch {
    # 互斥体都建不出来（极少见），退化成"照常启动"，至少不挡正事
    $是否新建 = $true
}
if (-not $是否新建) {
    Write-Output '已经有一个光标窗在跑了，本次启动作废'
    exit 0
}

Add-Type -Namespace AssistNative -Name CursorWindowApi -ReferencedAssemblies 'System.Drawing' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern int GetWindowLong(System.IntPtr hWnd, int nIndex);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern int SetWindowLong(System.IntPtr hWnd, int nIndex, int dwNewLong);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);

[System.Runtime.InteropServices.DllImport("shcore.dll", SetLastError = true)]
public static extern int SetProcessDpiAwareness(int level);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDPIAware();

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool UpdateLayeredWindow(
    System.IntPtr hwnd, System.IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
    System.IntPtr hdcSrc, ref POINT pptSrc, int crKey,
    ref BLENDFUNCTION pblend, int dwFlags);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetDC(System.IntPtr hWnd);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int ReleaseDC(System.IntPtr hWnd, System.IntPtr hDC);

[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern System.IntPtr CreateCompatibleDC(System.IntPtr hdc);

[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern bool DeleteDC(System.IntPtr hdc);

[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern System.IntPtr SelectObject(System.IntPtr hdc, System.IntPtr h);

[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern bool DeleteObject(System.IntPtr h);

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct SIZE { public int cx; public int cy; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack = 1)]
public struct BLENDFUNCTION {
    public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat;
}

// 把一张带透明通道的位图贴到分层窗口上，同时设定它的屏幕位置。
// 这是"逐像素透明"，比 TransparencyKey 抠色键干净得多：图片边缘的半透明像素会被正确混合，
// 不会出现一圈白边或洋红毛边。GetHbitmap 的背景色必须给全透明，
// 给别的颜色会让整个 alpha 通道被当成不透明——那就是"白框"的由来。
public static bool ApplyBitmap(System.IntPtr hwnd, System.Drawing.Bitmap bmp, int x, int y) {
    System.IntPtr screenDc = GetDC(System.IntPtr.Zero);
    System.IntPtr memDc = CreateCompatibleDC(screenDc);
    System.IntPtr hBitmap = System.IntPtr.Zero;
    System.IntPtr oldBitmap = System.IntPtr.Zero;
    try {
        hBitmap = bmp.GetHbitmap(System.Drawing.Color.FromArgb(0));
        oldBitmap = SelectObject(memDc, hBitmap);

        SIZE size;
        size.cx = bmp.Width;
        size.cy = bmp.Height;
        POINT src;
        src.X = 0; src.Y = 0;
        POINT dst;
        dst.X = x; dst.Y = y;

        BLENDFUNCTION blend;
        blend.BlendOp = 0;                 // AC_SRC_OVER
        blend.BlendFlags = 0;
        blend.SourceConstantAlpha = 255;
        blend.AlphaFormat = 1;             // AC_SRC_ALPHA

        return UpdateLayeredWindow(hwnd, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, 2);
    } finally {
        if (oldBitmap != System.IntPtr.Zero) { SelectObject(memDc, oldBitmap); }
        if (hBitmap != System.IntPtr.Zero) { DeleteObject(hBitmap); }
        DeleteDC(memDc);
        ReleaseDC(System.IntPtr.Zero, screenDc);
    }
}
'@

# 和桌面助手一样要声明 DPI 感知。两边对"屏幕上一个像素"的理解必须一致，
# 否则助手以为挪到了 (800,400)，屏幕上却偏出去一截（本机是 150% 缩放）。
try {
    [void][AssistNative.CursorWindowApi]::SetProcessDpiAwarenessContext([System.IntPtr]::new(-4))
} catch {
    try {
        [void][AssistNative.CursorWindowApi]::SetProcessDpiAwareness(2)
    } catch {
        try { [void][AssistNative.CursorWindowApi]::SetProcessDPIAware() } catch { }
    }
}

<#
 作用：画一条胖乎乎的大肥鱼，头朝左上，鱼嘴尖端贴着 (0,0)。
 输入：边长（正方形像素数）。
 输出：一张 32 位带 alpha 的位图。
 说明：鱼嘴对着左上角，是为了让"窗口左上角 = 指针位置"这条老语义继续成立——
       助手把窗口挪到 (x,y)，鱼嘴就正好压在那一点上。
#>
function 生成大肥鱼位图 {
    param([int]$边长 = 32)

    $位图 = New-Object System.Drawing.Bitmap($边长, $边长, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $画布 = [System.Drawing.Graphics]::FromImage($位图)
    $画布.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $画布.Clear([System.Drawing.Color]::Transparent)

    # 身体：一个偏左上的胖椭圆，右边留出位置给尾巴
    $身体矩形 = New-Object System.Drawing.RectangleF(1, 4, 24, 21)
    $渐变 = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $身体矩形,
        [System.Drawing.Color]::FromArgb(255, 176, 226, 255),
        [System.Drawing.Color]::FromArgb(255, 24, 84, 176),
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)

    # 尾巴先画、身体后盖，根部不会出现缝
    $尾巴 = @(
        (New-Object System.Drawing.PointF(21, 10)),
        (New-Object System.Drawing.PointF(30, 5)),
        (New-Object System.Drawing.PointF(30, 24)),
        (New-Object System.Drawing.PointF(21, 19))
    )
    $尾刷 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 44, 118, 198))
    $画布.FillPolygon($尾刷, $尾巴)
    $画布.FillEllipse($渐变, $身体矩形)

    $描边 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 10, 38, 92), 1.1)
    $画布.DrawPolygon($描边, $尾巴)
    $画布.DrawEllipse($描边, $身体矩形)

    # 肚皮：浅色一块压在下缘，别让整条鱼是一坨蓝
    $肚皮 = New-Object System.Drawing.Drawing2D.GraphicsPath
    $肚皮.AddBezier(3, 17, 8, 26, 18, 26, 24, 18)
    $肚皮.AddBezier(24, 18, 17, 24, 8, 23, 3, 17)
    $肚皮刷 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(170, 226, 242, 255))
    $画布.FillPath($肚皮刷, $肚皮)

    # 眼睛：小一点、靠上偏左。光标只有 32 像素，这只眼睛就是"这是一条鱼"的全部信息量
    $白眼球 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $瞳孔刷 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 12, 28, 60))
    $高光刷 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $画布.FillEllipse($白眼球, 7, 8, 8, 8)
    $画布.FillEllipse($瞳孔刷, 9.5, 10.5, 4, 4)
    $画布.FillEllipse($高光刷, 9.6, 10, 1.8, 1.8)

    # 嘴：左边缘一小道弧
    $嘴笔 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 10, 38, 92), 1)
    $嘴 = New-Object System.Drawing.Drawing2D.GraphicsPath
    $嘴.AddArc(1.5, 15, 5, 5, 200, 120)
    $画布.DrawPath($嘴笔, $嘴)

    # 背鳍：头顶一个小凸起
    $鳍 = New-Object System.Drawing.Drawing2D.GraphicsPath
    $鳍.AddBezier(11, 4.5, 12, 0.5, 17, 1.5, 18, 5)
    $鳍.AddBezier(18, 5, 15, 5, 13, 5, 11, 4.5)
    $鳍刷 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 60, 132, 210))
    $画布.FillPath($鳍刷, $鳍)
    $画布.DrawPath($描边, $鳍)

    $鳍.Dispose(); $鳍刷.Dispose()
    $嘴.Dispose(); $嘴笔.Dispose()
    $白眼球.Dispose(); $瞳孔刷.Dispose(); $高光刷.Dispose()
    $肚皮.Dispose(); $肚皮刷.Dispose()
    $描边.Dispose(); $渐变.Dispose()
    $画布.Dispose()

    return $位图
}

$全局鱼 = 生成大肥鱼位图 -边长 $窗口边长

$窗体 = New-Object System.Windows.Forms.Form
$窗体.Text = $窗口标题
$窗体.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$窗体.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$窗体.ShowInTaskbar = $false
$窗体.TopMost = $true
$窗体.MinimizeBox = $false
$窗体.MaximizeBox = $false
# 关掉自动缩放。本机 150% 缩放下，WinForms 默认按字体自动缩放，会把 32 像素的窗体改成 21 像素，
# 鱼就被裁掉一截；而位图本身是 32×32，两边尺寸对不上
$窗体.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$窗体.Width = $窗口边长
$窗体.Height = $窗口边长
# 先躲到屏幕外，等桌面助手发移动指令才露面，免得开机就闪一下
$窗体.Location = New-Object System.Drawing.Point(-400, -400)

$窗体.add_Load({
    $句柄 = $窗体.Handle
    # GWL_EXSTYLE = -20
    $扩展样式 = [AssistNative.CursorWindowApi]::GetWindowLong($句柄, -20)
    # 0x00080000 分层窗口：逐像素透明的前提
    # 0x00000020 点击穿透：鼠标落在鱼身上时，命中的是它下面的窗口
    # 0x08000000 不激活：点它不会把焦点从用户正在打字的窗口抢走
    # 0x00000080 工具窗口：不出现在 Alt+Tab 里
    $扩展样式 = $扩展样式 -bor 0x00080000 -bor 0x00000020 -bor 0x08000000 -bor 0x00000080
    [void][AssistNative.CursorWindowApi]::SetWindowLong($句柄, -20, $扩展样式)

    # 贴图。位置先沿用窗体当前位置（躲屏幕外），助手随后会用 SetWindowPos 把它挪到目标点
    $位置 = $窗体.Location

    # WinForms 会按当前 DPI 把 32 像素的窗体换算成 21 物理像素，鱼就被裁掉一圈。
    # 这里用 Win32 直接把物理尺寸钉回 32×32，绕开它那一层换算。
    # 0x0004 不改变 Z 序（保持置顶）、0x0010 不激活
    [void][AssistNative.CursorWindowApi]::SetWindowPos(
        $句柄, [System.IntPtr]::Zero, $位置.X, $位置.Y, $窗口边长, $窗口边长, 0x0004 -bor 0x0010)

    [void][AssistNative.CursorWindowApi]::ApplyBitmap($句柄, $全局鱼, $位置.X, $位置.Y)
})

[System.Windows.Forms.Application]::Run($窗体)
