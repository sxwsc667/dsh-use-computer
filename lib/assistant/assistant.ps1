# 桌面助手（常驻进程）
#
# 作用：守着一根命名管道，按"一行一条 JSON"的协议操作 Windows 桌面——
#       移动那个看得见的虚拟光标、截屏、枚举顶层窗口、点坐标、打字。
#       全部用本机现成的 .NET 组件实现，不依赖任何第三方二进制。
# 输入：命名管道上的一行一条 JSON 请求，字段见 lib/pipe-protocol.js 的注释。
# 输出：管道上的一行一条 JSON 响应；截图写成临时目录里的 PNG；
#       进程一直运行到收到 op=shutdown，或发现启动它的父进程已经退出。
#
# 落盘位置：截图在 $env:TEMP\dsh-use-computer\shots\，只留最近 20 张。

param(
    # 命名管道名。默认值和 lib/pipe-protocol.js 里的常量必须一致
    [string]$PipeName = 'dsh-use-computer',

    # 是否在本次启动时拉起光标窗进程。光标窗已存在时会自动跳过
    [switch]$WithCursor,

    # 日志文件。助手是由 WMI 拉起的独立进程，没有可重定向的标准输出，
    # 出问题时只能翻这个文件
    [string]$LogPath = (Join-Path $env:TEMP 'dsh-use-computer\assistant.log'),

    # 多久没人用就自己退出（毫秒）。0 表示永不退出，这也是现在的默认。
    #
    # 原来默认 120 秒，实测下来这个设计有害：进程自己走掉之后，
    # 调用方只能看到"连不上"，分不清是崩了、是关了、还是它自己溜了，
    # 于是会出现"模型以为还开着、其实早没了"这类糊涂账。
    # 现在改成常驻：什么时候停，由 desktop_stop 明确决定。
    [int]$IdleTimeoutMs = 0
)

$ErrorActionPreference = 'Stop'

<#
 作用：往日志文件追加一行。
 输入：要记的内容。
 输出：无返回值。写日志本身失败时静默跳过——它不能反过来把主流程搞挂。
#>
function 写日志([string]$内容) {
    try {
        $目录 = Split-Path -Parent $LogPath
        if ($目录 -and -not (Test-Path -LiteralPath $目录)) {
            New-Item -ItemType Directory -Path $目录 -Force | Out-Null
        }
        $行 = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $内容
        Add-Content -LiteralPath $LogPath -Value $行 -Encoding UTF8
    } catch {
        # 日志写不进去就算了
    }
}

# ---- 单实例把关 ----
# 两个助手会抢同一根管道和同一个光标窗，表现是"时好时坏"，极难查。
# 用系统命名互斥体把这件事挡在最前面：抢不到锁的那个直接走人，什么都不建。
try {
    $是否新建 = $false
    $单实例锁 = New-Object System.Threading.Mutex($true, 'Local\DSH-USE-COMPUTER-ASSISTANT', [ref]$是否新建)
    if (-not $是否新建) {
        写日志 "已经有一个助手在跑，本次启动作废：pid=$PID"
        exit 0
    }
} catch {
    # 互斥体都建不出来（极少见），仍继续启动，至少不耽误正事
    写日志 "建单实例互斥体失败，继续启动：$($_.Exception.Message)"
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
# System.Windows.Point 在 WindowsBase 里。UIAutomationClient 的 FromPoint 要这个类型做入参，
# 不加载它就会报 "Cannot find type [System.Windows.Point]"，语义点击整条路线直接失效
Add-Type -AssemblyName WindowsBase

Add-Type -Namespace AssistNative -Name DesktopApi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern System.IntPtr GetDC(System.IntPtr hWnd);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern int ReleaseDC(System.IntPtr hWnd, System.IntPtr hDC);

// 屏幕抓取用。rop 里要带 CAPTUREBLT(0x40000000)，否则分层窗口（我们的浮窗、光标鱼）截不到
[System.Runtime.InteropServices.DllImport("gdi32.dll", SetLastError = true)]
public static extern bool BitBlt(System.IntPtr hdcDest, int x, int y, int cx, int cy, System.IntPtr hdcSrc, int xSrc, int ySrc, int rop);

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);

[System.Runtime.InteropServices.DllImport("shcore.dll", SetLastError = true)]
public static extern int SetProcessDpiAwareness(int level);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDPIAware();
'@

# 输入能力：真实鼠标点击、Unicode 打字、组合键、滚轮、后台消息点击。
# 单独开一个类型名，不往 DesktopApi 里塞——同名类型重复定义会让整条命令直接崩。
# 这里大量是底层的 SendInput 结构体，写起来只有 C# 顺手，所以整段放在 C# 里，PowerShell 只调一个方法。
if (-not ('AssistNative.InputApi' -as [type])) {
    Add-Type -Namespace AssistNative -Name InputApi -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time;
    public System.IntPtr dwExtraInfo;
}

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan; public uint dwFlags; public uint time;
    public System.IntPtr dwExtraInfo;
}

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }

// 三个输入结构在 C# 里是 union，必须用显式布局把偏移量写死。
// 关键点：64 位下 union 的起始偏移是 8 不是 4——它含有 ULONG_PTR，要按 8 字节对齐。
// 写成 FieldOffset(4) 时 cbSize 仍是 40，SendInput 也照样返回 2（"发了两个事件"），
// 但系统在 offset 8 读到的是垃圾，输入被静默丢弃：不报错，只是什么都没打出来。
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
public struct INPUT {
    [System.Runtime.InteropServices.FieldOffset(0)] public uint type;
    [System.Runtime.InteropServices.FieldOffset(8)] public MOUSEINPUT mi;
    [System.Runtime.InteropServices.FieldOffset(8)] public KEYBDINPUT ki;
    [System.Runtime.InteropServices.FieldOffset(8)] public HARDWAREINPUT hi;
}

[DllImport("user32.dll", SetLastError = true)]
public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetCursorPos(int X, int Y);

[DllImport("user32.dll", SetLastError = true)]
public static extern bool GetCursorPos(out POINT p);

// 看某个键当前按没按。
// 返回值最低位（0x0001）表示"自上次调用以来这个键按过没有"，调用后自动清掉。
// 高位（0x8000）表示"现在正按着"。急停只关心低位——按一次算一次，不用管它按住多久。
[DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);

[DllImport("user32.dll")]
public static extern System.IntPtr WindowFromPoint(POINT p);

[DllImport("user32.dll", SetLastError = true)]
public static extern bool ScreenToClient(System.IntPtr hWnd, ref POINT p);

[DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);

[DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();

[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);

[DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder sb, int max);

// SendInput 要的大小，按本进程的位数算（本机 x64 下 INPUT 是 40 字节）
static int InputSize { get { return System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)); } }

public static bool ClickScreen(int x, int y, int button, int count) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(40);
    uint down; uint up;
    if (button == 2) { down = 0x0008; up = 0x0010; }
    else if (button == 3) { down = 0x0020; up = 0x0040; }
    else { down = 0x0002; up = 0x0004; }
    for (int i = 0; i < count; i++) {
        INPUT[] ins = new INPUT[2];
        ins[0].type = 0; ins[0].mi.dwFlags = down;
        ins[1].type = 0; ins[1].mi.dwFlags = up;
        if (SendInput(2, ins, InputSize) != 2) { return false; }
        System.Threading.Thread.Sleep(60);
    }
    return true;
}

// 逐字符发 KEYEVENTF_UNICODE：中文、标点、emoji 都按字符码直接送进焦点窗口，不依赖键盘布局
public static int TypeUnicode(string text) {
    if (text == null) { return 0; }
    int sent = 0;
    for (int i = 0; i < text.Length; i++) {
        char c = text[i];
        if (c == (char)13) { continue; }
        if (c == (char)10) {
            INPUT[] enterKeys = new INPUT[2];
            enterKeys[0].type = 1; enterKeys[0].ki.wVk = 0x0D; enterKeys[0].ki.wScan = 0x1C; enterKeys[0].ki.dwFlags = 0;
            enterKeys[1].type = 1; enterKeys[1].ki.wVk = 0x0D; enterKeys[1].ki.wScan = 0x1C; enterKeys[1].ki.dwFlags = 0x0002;
            if (SendInput(2, enterKeys, InputSize) == 2) { sent++; }
            System.Threading.Thread.Sleep(25);
            continue;
        }
        INPUT[] charKeys = new INPUT[2];
        charKeys[0].type = 1; charKeys[0].ki.wScan = (ushort)c; charKeys[0].ki.dwFlags = 0x0004;
        charKeys[1].type = 1; charKeys[1].ki.wScan = (ushort)c; charKeys[1].ki.dwFlags = 0x0004 | 0x0002;
        if (SendInput(2, charKeys, InputSize) == 2) { sent++; }
        System.Threading.Thread.Sleep(8);
    }
    return sent;
}

// 组合键：按给定顺序全部按下，停一小会，再倒序抬起（先松普通键再松修饰键，应用才不会吃到怪状态）
public static bool PressChord(int[] keys, int holdMs) {
    if (keys == null || keys.Length == 0) { return false; }
    INPUT[] downs = new INPUT[keys.Length];
    for (int i = 0; i < keys.Length; i++) {
        downs[i].type = 1; downs[i].ki.wVk = (ushort)keys[i]; downs[i].ki.dwFlags = 0;
    }
    if (SendInput((uint)keys.Length, downs, InputSize) != (uint)keys.Length) { return false; }
    System.Threading.Thread.Sleep(holdMs < 0 ? 30 : holdMs);
    INPUT[] ups = new INPUT[keys.Length];
    for (int i = 0; i < keys.Length; i++) {
        int src = keys.Length - 1 - i;
        ups[i].type = 1; ups[i].ki.wVk = (ushort)keys[src]; ups[i].ki.dwFlags = 0x0002;
    }
    if (SendInput((uint)keys.Length, ups, InputSize) != (uint)keys.Length) { return false; }
    return true;
}

// 滚轮。notches 正数向上滚（看更早的内容），负数向下滚，一格算 120
public static bool ScrollWheel(int x, int y, int notches) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(30);
    INPUT[] ins = new INPUT[1];
    ins[0].type = 0;
    ins[0].mi.mouseData = (uint)(notches * 120);
    ins[0].mi.dwFlags = 0x0800;
    return SendInput(1, ins, InputSize) == 1;
}

// 后台点击：不移动真实鼠标、不抢焦点，直接往目标窗口投消息。
// 对传统 Win32 控件有效，对 Chromium/Electron 这类自绘窗口经常无效——所以它只是备选项，不是默认路线
public static bool PostClickScreen(System.IntPtr hWnd, int screenX, int screenY, int button) {
    POINT pt;
    pt.X = screenX; pt.Y = screenY;
    if (!ScreenToClient(hWnd, ref pt)) { return false; }
    uint downMsg; uint upMsg; System.IntPtr wParam;
    if (button == 2) { downMsg = 0x0204; upMsg = 0x0205; wParam = (System.IntPtr)2; }
    else if (button == 3) { downMsg = 0x0207; upMsg = 0x0208; wParam = (System.IntPtr)16; }
    else { downMsg = 0x0201; upMsg = 0x0202; wParam = (System.IntPtr)1; }
    System.IntPtr lParam = (System.IntPtr)((pt.Y << 16) | (pt.X & 0xFFFF));
    bool first = PostMessage(hWnd, downMsg, wParam, lParam);
    System.Threading.Thread.Sleep(30);
    bool second = PostMessage(hWnd, upMsg, System.IntPtr.Zero, lParam);
    return first && second;
}

// 查坐标下面是哪个窗口，回一句 "句柄|进程号|类名"，PowerShell 侧按竖线拆
public static string DescribeWindowAt(int x, int y) {
    POINT pt;
    pt.X = x; pt.Y = y;
    System.IntPtr hwnd = WindowFromPoint(pt);
    if (hwnd == System.IntPtr.Zero) { return ""; }
    uint pid;
    GetWindowThreadProcessId(hwnd, out pid);
    System.Text.StringBuilder buf = new System.Text.StringBuilder(256);
    GetClassName(hwnd, buf, 256);
    return hwnd.ToInt64().ToString() + "|" + pid.ToString() + "|" + buf.ToString();
}
'@
}

# ---- 帧环：连续记录屏幕上发生的变化 ----
#
# 为什么需要它：模型看完一张图、想清楚、发出指令，再到拿到下一份信息，
# 中间隔好几秒。这几秒里屏幕一直在变，只给"此刻"一帧，等于把变化全丢掉。
# 要还原这段时间，就必须在模型不吭声的时候也有人一直在截——所以是后台定时截。
#
# 为什么用 C# 而不是 PowerShell 定时器：PowerShell 的事件回调要自己的 runspace，
# 和助手主循环抢线程很麻烦。编译成 .NET 类之后，Timer 线程和主循环互不干扰。
#
# 为什么每帧存成 JPEG 字节而不是 Bitmap：40 帧 640×360 的 Bitmap 要 30 多 MB，
# JPEG 只要 2 MB 左右。反正拼图时还要解码，不如省着。
$帧环可用 = $false
try {
if (-not ('FrameRing' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
public class FrameRing {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern System.IntPtr GetDC(System.IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern int ReleaseDC(System.IntPtr hWnd, System.IntPtr hDC);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    static extern bool StretchBlt(System.IntPtr hdcDst, int xDst, int yDst, int wDst, int hDst,
        System.IntPtr hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc, int rop);

    public class Frame { public System.DateTime Time; public byte[] Jpeg; }
    public class Mosaic {
        public byte[] Jpeg;
        public string[] Times;
        public double SpanSeconds;
        public int Count;
    }

    readonly object _lock = new object();
    readonly System.Collections.Generic.List<Frame> _frames = new System.Collections.Generic.List<Frame>();
    System.Threading.Timer _timer;
    int _width = 640, _height = 360, _max = 40, _intervalMs = 1000;

    public int Width { get { return _width; } }
    public int Height { get { return _height; } }
    public int IntervalMs { get { return _intervalMs; } }
    public int Count { get { lock (_lock) return _frames.Count; } }

    public void Start(int width, int height, int intervalMs, int maxFrames) {
        _width = width; _height = height; _intervalMs = intervalMs; _max = maxFrames;
        if (_timer != null) { _timer.Dispose(); _timer = null; }
        _timer = new System.Threading.Timer(delegate { Capture(); }, null, 0, intervalMs);
    }

    public void Stop() {
        if (_timer != null) { _timer.Dispose(); _timer = null; }
    }

    public void Capture() {
        try {
            int sw = System.Windows.Forms.SystemInformation.VirtualScreen.Width;
            int sh = System.Windows.Forms.SystemInformation.VirtualScreen.Height;
            if (sw < 8 || sh < 8) return;
            using (var bmp = new System.Drawing.Bitmap(_width, _height, System.Drawing.Imaging.PixelFormat.Format24bppRgb)) {
                using (var g = System.Drawing.Graphics.FromImage(bmp)) {
                    System.IntPtr dst = g.GetHdc();
                    System.IntPtr src = GetDC(System.IntPtr.Zero);
                    try {
                        // 0x00CC0020 = SRCCOPY，0x40000000 = CAPTUREBLT。
                        // 不带 CAPTUREBLT 时，分层窗口和硬件叠加层（视频、游戏画面）会截成黑的
                        StretchBlt(dst, 0, 0, _width, _height, src, 0, 0, sw, sh, unchecked((int)0x00CC0020) | 0x40000000);
                    } finally {
                        if (src != System.IntPtr.Zero) ReleaseDC(System.IntPtr.Zero, src);
                        g.ReleaseHdc(dst);
                    }
                }
                using (var ms = new System.IO.MemoryStream()) {
                    bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Jpeg);
                    var f = new Frame();
                    f.Time = System.DateTime.Now;
                    f.Jpeg = ms.ToArray();
                    lock (_lock) {
                        _frames.Add(f);
                        while (_frames.Count > _max) _frames.RemoveAt(0);
                    }
                }
            }
        } catch {
            // 截失败就跳过这一帧：偶尔丢一帧不影响"看变化"，但不能让定时器线程挂掉
        }
    }

    // 从缓冲里均匀取 count 帧。取的是"最近这一段"，不是最新的 count 帧——
    // 最新的几帧挤在最后几秒，看不出整段时间里的变化。
    public Frame[] Take(int count) {
        lock (_lock) {
            if (_frames.Count == 0) return new Frame[0];
            if (count < 1) count = 1;
            if (_frames.Count <= count) return _frames.ToArray();
            var result = new Frame[count];
            double step = (double)(_frames.Count - 1) / (count - 1);
            for (int i = 0; i < count; i++) result[i] = _frames[(int)System.Math.Round(i * step)];
            return result;
        }
    }

    // 取帧并拼成一张联系表：左上角标出每帧的时间，方便模型对上"第几格是什么时候"。
    // 拼成一张而不是分开发，是因为一张 2×2 的图大约等于 1 张图的钱，分开发是 4 张。
    // 取 [from, 现在] 这段窗口里的帧，均匀挑 count 张。
    // from 早于缓冲起点时，自然退化成"缓冲里最早的那些"。
    // 这个窗口就是模型的一次感知间隔：它上次拿到信息之后，一直到现在。
    public Frame[] TakeSince(System.DateTime from, int count) {
        lock (_lock) {
            if (_frames.Count == 0) return new Frame[0];
            if (count < 1) count = 1;
            var list = _frames.FindAll(delegate(Frame f) { return f.Time >= from; });
            if (list.Count == 0) list = new System.Collections.Generic.List<Frame>(_frames);
            if (list.Count <= count) return list.ToArray();
            var result = new Frame[count];
            double step = (double)(list.Count - 1) / (count - 1);
            for (int i = 0; i < count; i++) result[i] = list[(int)System.Math.Round(i * step)];
            return result;
        }
    }

    public Mosaic Compose(int count, System.DateTime from) {
        Frame[] frames = TakeSince(from, count);
        if (frames.Length == 0) return null;
        int cols = frames.Length <= 2 ? frames.Length : 2;
        int rows = (frames.Length + cols - 1) / cols;
        var result = new Mosaic();
        result.Count = frames.Length;
        result.Times = new string[frames.Length];
        for (int i = 0; i < frames.Length; i++) result.Times[i] = frames[i].Time.ToString("HH:mm:ss.fff");
        result.SpanSeconds = frames.Length > 1
            ? (frames[frames.Length - 1].Time - frames[0].Time).TotalSeconds
            : 0;

        using (var canvas = new System.Drawing.Bitmap(cols * _width, rows * _height, System.Drawing.Imaging.PixelFormat.Format24bppRgb)) {
            using (var g = System.Drawing.Graphics.FromImage(canvas)) {
                g.Clear(System.Drawing.Color.Black);
                for (int i = 0; i < frames.Length; i++) {
                    using (var ms = new System.IO.MemoryStream(frames[i].Jpeg))
                    using (var img = System.Drawing.Image.FromStream(ms)) {
                        g.DrawImage(img, (i % cols) * _width, (i / cols) * _height, _width, _height);
                    }
                }
                using (var font = new System.Drawing.Font("Consolas", 13, System.Drawing.FontStyle.Bold))
                using (var brush = new System.Drawing.SolidBrush(System.Drawing.Color.Yellow))
                using (var back = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(170, 0, 0, 0)))
                using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(120, 255, 255, 255), 1)) {
                    for (int i = 0; i < frames.Length; i++) {
                        int x = (i % cols) * _width;
                        int y = (i / cols) * _height;
                        string label = (i + 1).ToString() + "  " + result.Times[i];
                        var size = g.MeasureString(label, font);
                        g.FillRectangle(back, x + 3, y + 3, size.Width + 4, size.Height + 2);
                        g.DrawString(label, font, brush, x + 5, y + 4);
                        g.DrawRectangle(pen, x, y, _width - 1, _height - 1);
                    }
                }
                using (var ms = new System.IO.MemoryStream()) {
                    canvas.Save(ms, System.Drawing.Imaging.ImageFormat.Jpeg);
                    result.Jpeg = ms.ToArray();
                }
            }
        }
        return result;
    }
}
'@
}
$帧环可用 = $true
} catch {
    $帧环可用 = $false
}

# 声明进程 DPI 感知。
# 不声明时的后果（本机实测）：SystemInformation.VirtualScreen 报 1707×960，
# 而 UIA 报的窗口矩形是 2582×1390——两套坐标系，截图上量的位置和点击用的位置对不上，必点偏。
# 三级退让：先要 per-monitor-v2（Win10 1703+），再要 per-monitor（Win8.1+），最后 system（Vista+）。
# 必须赶在任何窗口、GDI 调用之前执行，晚了不生效。
$已声明DPI = 'none'
try {
    [void][AssistNative.DesktopApi]::SetProcessDpiAwarenessContext([System.IntPtr]::new(-4))
    $已声明DPI = 'per-monitor-v2'
} catch {
    try {
        [void][AssistNative.DesktopApi]::SetProcessDpiAwareness(2)
        $已声明DPI = 'per-monitor'
    } catch {
        try {
            [void][AssistNative.DesktopApi]::SetProcessDPIAware()
            $已声明DPI = 'system'
        } catch { }
    }
}

# ---- 常量 ----

# 光标窗标题。和 cursor.ps1 里的 $窗口标题 是同一个字符串，两处必须一起改
$光标窗标题 = 'DSH-USE-COMPUTER-CURSOR'

# 给 FindWindow 的类名参数传"真正的 NULL"。
# 这里有个坑：PowerShell 把 $null 绑定到 .NET 的 string 参数时会转成空字符串，
# 而 FindWindow 拿空串当类名就一个窗口都找不到（实测返回 0）。必须用 NullString.Value。
$空类名 = [System.Management.Automation.Language.NullString]::Value
# HWND_TOPMOST
$窗口置顶 = [System.IntPtr]::new(-1)
# SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW
$移动并置顶 = 0x0001 -bor 0x0010 -bor 0x0040
# SW_HIDE / SW_SHOWNOACTIVATE
$窗口隐藏 = 0
$窗口显示不激活 = 4
# 截图落盘目录
$截图目录 = Join-Path $env:TEMP 'dsh-use-computer\shots'
# 截图最多留几张，超了删最旧的
$截图保留张数 = 20

# 光标窗句柄缓存。零值表示"还没查过"，取光标窗句柄 会自己去查
$script:光标窗句柄 = [System.IntPtr]::Zero

# 本进程自己的状态，供 status 回报
$当前状态 = @{
    'startedAt' = (Get-Date).ToString('o')
    'shots'     = 0
    'lastShot'  = $null
}

# 帧环实例。真正启动放在主循环之前——太早启动会赶在 DPI 声明前面截屏，
# 抓到的画面和后面的坐标系对不上。
$script:帧环 = $null

# ---- 虚拟光标 ----

<#
 作用：拿光标窗的窗口句柄。第一次调用会顺手确保光标窗进程活着。
 输入：无。
 输出：窗口句柄（IntPtr）。拿不到就抛异常——没有光标窗等于"看不见模型在点什么"，
       宁可报错，也不静默降级成无光标操作。
#>
function 取光标窗句柄 {
    if ($script:光标窗句柄 -ne [System.IntPtr]::Zero) {
        # 句柄可能因为用户手动关掉了光标窗而失效，验一下再用缓存
        $探针 = [AssistNative.DesktopApi+RECT]::new()
        $还在 = [AssistNative.DesktopApi]::GetWindowRect($script:光标窗句柄, [ref]$探针)
        if ($还在) { return $script:光标窗句柄 }
        $script:光标窗句柄 = [System.IntPtr]::Zero
    }

    $句柄 = [AssistNative.DesktopApi]::FindWindow($空类名, $光标窗标题)
    if ($句柄 -eq [System.IntPtr]::Zero) {
        throw '光标窗不见了：屏幕上没有标题为 DSH-USE-COMPUTER-CURSOR 的窗口。可执行 use-computer cursor 重新拉起'
    }
    $script:光标窗句柄 = $句柄
    return $句柄
}

<#
 作用：确保光标窗进程在跑。已有窗口就直接返回，不重复拉起。
 输入：无。
 输出：无返回值；效果是屏幕上存在光标窗。8 秒内等不到就抛异常。
#>
function 确保光标窗进程 {
    $已有 = [AssistNative.DesktopApi]::FindWindow($空类名, $光标窗标题)
    if ($已有 -ne [System.IntPtr]::Zero) { return }

    $光标脚本 = Join-Path $PSScriptRoot 'cursor.ps1'
    if (-not (Test-Path -LiteralPath $光标脚本)) {
        throw "光标窗脚本不存在：$光标脚本"
    }

    # 最多试两轮。光标窗自己也有单实例锁：如果刚好处在"上一个正在启动、窗口还没建出来"的窗口期，
    # 这次拉起来的那个会自己退出，屏幕上就一直没有鱼。第二轮是给这种竞态留的补救
    for ($轮 = 1; $轮 -le 2; $轮++) {
        # 必须是 Windows PowerShell 5.1（powershell.exe）且带 -STA：WinForms 窗体要求单线程单元
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$光标脚本`"") `
            -WindowStyle Hidden | Out-Null

        for ($尝试 = 0; $尝试 -lt 80; $尝试++) {
            Start-Sleep -Milliseconds 100
            if ([AssistNative.DesktopApi]::FindWindow($空类名, $光标窗标题) -ne [System.IntPtr]::Zero) {
                $script:光标窗句柄 = [System.IntPtr]::Zero
                return
            }
        }
    }
    throw '光标窗进程启动失败：连续两轮、每轮 8 秒，屏幕上都没有出现光标窗口'
}

<#
 作用：读光标窗当前左上角坐标。
 输入：无。
 输出：@{x, y} 两个整数。读不到时返回 @{x=0; y=0}。
#>
function 取光标窗位置 {
    $矩形 = [AssistNative.DesktopApi+RECT]::new()
    $读到了 = $false
    try {
        $句柄 = 取光标窗句柄
        $读到了 = [AssistNative.DesktopApi]::GetWindowRect($句柄, [ref]$矩形)
    } catch {
        $读到了 = $false
    }
    if (-not $读到了) { return @{ 'x' = 0; 'y' = 0 } }
    return @{ 'x' = $矩形.Left; 'y' = $矩形.Top }
}

<#
 作用：把光标窗左上角直接挪到指定坐标（尖端正对目标点）。
 输入：x、y：屏幕像素坐标，相对虚拟屏幕左上角。
 输出：无返回值；效果是窗口瞬移到那儿，且保持置顶、不抢焦点。
#>
function 移动光标到([int]$x, [int]$y) {
    $句柄 = 取光标窗句柄
    $成功 = [AssistNative.DesktopApi]::SetWindowPos($句柄, $窗口置顶, $x, $y, 0, 0, $移动并置顶)
    if (-not $成功) {
        throw "移动光标失败：SetWindowPos 返回 false，目标 ($x, $y)"
    }
}

<#
 作用：把光标从当前位置分帧滑到目标点，让用户看得清它往哪儿去。
 输入：终点x、终点y、帧数（默认 12 帧，每帧 12 毫秒，整段约 0.15 秒）。
 输出：无返回值；效果是光标在屏幕上滑过去，最后停在终点。
#>
function 平滑移动光标到([int]$终点x, [int]$终点y, [int]$帧数 = 12) {
    $起点 = 取光标窗位置
    if ($帧数 -lt 1) { $帧数 = 1 }
    for ($帧 = 1; $帧 -le $帧数; $帧++) {
        $比例 = $帧 / $帧数
        $本帧x = [int][Math]::Round($起点.x + ($终点x - $起点.x) * $比例)
        $本帧y = [int][Math]::Round($起点.y + ($终点y - $起点.y) * $比例)
        移动光标到 $本帧x $本帧y
        Start-Sleep -Milliseconds 12
    }
}

<#
 作用：把光标窗进程彻底结束掉，不留一个箭头在屏幕上、也不留一个进程占内存。
 输入：无。
 输出：无返回值。
 说明：先按窗口标题找到窗口，再从窗口句柄反查它属于哪个进程——这是唯一可靠的凭据。
       千万不能按"最近启动的 powershell"去杀，那会误伤别人。
#>
function 收掉光标窗 {
    try {
        $句柄 = [AssistNative.DesktopApi]::FindWindow($空类名, $光标窗标题)
        if ($句柄 -eq [System.IntPtr]::Zero) { return }
        [void][AssistNative.DesktopApi]::ShowWindow($句柄, $窗口隐藏)

        [uint32]$进程号 = 0
        [void][AssistNative.InputApi]::GetWindowThreadProcessId($句柄, [ref]$进程号)
        if ($进程号 -gt 0 -and $进程号 -ne $PID) {
            Stop-Process -Id $进程号 -Force -ErrorAction SilentlyContinue
            写日志 "已结束光标窗进程：pid=$进程号"
        }
    } catch {
        写日志 "收掉光标窗失败：$($_.Exception.Message)"
    }
}

# ---- 截图 ----

<#
 作用：取整个虚拟屏幕的范围（多显示器时是它们的并集）。
 输入：无。
 输出：一个矩形对象，含 X、Y、Width、Height。
#>
function 取屏幕矩形 {
    return [System.Windows.Forms.SystemInformation]::VirtualScreen
}

<#
 作用：抓一张屏幕位图。
 输入：选项哈希表，可含：
       'hideCursor'   是否先把虚拟光标藏起来再截（默认 $true，让画面干净、便于比对变化）
       'maxWidth'     最大宽度，超过就等比缩小（默认 1280）
 输出：一张 GDI+ 位图，调用方负责 Dispose。
#>
function 抓屏幕位图 {
    param([hashtable]$选项 = @{})

    $要藏光标 = $true
    if ($选项.ContainsKey('hideCursor')) { $要藏光标 = [bool]$选项['hideCursor'] }
    $最大宽度 = 1280
    if ($选项.ContainsKey('maxWidth') -and [int]$选项['maxWidth'] -gt 0) { $最大宽度 = [int]$选项['maxWidth'] }

    $光标句柄 = [System.IntPtr]::Zero
    if ($要藏光标) {
        try {
            $光标句柄 = 取光标窗句柄
            [void][AssistNative.DesktopApi]::ShowWindow($光标句柄, $窗口隐藏)
            Start-Sleep -Milliseconds 40
        } catch {
            $光标句柄 = [System.IntPtr]::Zero
        }
    }

    try {
        $矩形 = 取屏幕矩形
        $原图 = New-Object System.Drawing.Bitmap($矩形.Width, $矩形.Height)
        $画布 = [System.Drawing.Graphics]::FromImage($原图)
        # 用 BitBlt 并带上 CAPTUREBLT(0x40000000)，不用 Graphics.CopyFromScreen。
        # CopyFromScreen 内部不带这个标志，实测会漏掉分层窗口：我们自己的输出浮窗、
        # 以及「鱼」光标窗都截不到。截图必须和用户看到的一致，
        # 否则模型是在拿一张缺了内容的画面做判断。
        $目标DC = $画布.GetHdc()
        $来源DC = [AssistNative.DesktopApi]::GetDC([System.IntPtr]::Zero)
        try {
            if ($来源DC -eq [System.IntPtr]::Zero) { throw '取不到屏幕设备上下文，无法截屏' }
            $成败 = [AssistNative.DesktopApi]::BitBlt(
                $目标DC, 0, 0, $矩形.Width, $矩形.Height, $来源DC, $矩形.X, $矩形.Y, (0x00CC0020 -bor 0x40000000))
            if (-not $成败) { throw "BitBlt 截屏失败，错误码 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        } finally {
            if ($来源DC -ne [System.IntPtr]::Zero) { [void][AssistNative.DesktopApi]::ReleaseDC([System.IntPtr]::Zero, $来源DC) }
            $画布.ReleaseHdc($目标DC)
            $画布.Dispose()
        }
    } finally {
        if ($光标句柄 -ne [System.IntPtr]::Zero) {
            [void][AssistNative.DesktopApi]::ShowWindow($光标句柄, $窗口显示不激活)
        }
    }

    # 裁剪：只留请求指定的那块屏幕区域。
    # 坐标为屏幕坐标（和 click 用同一套），转成截图内的相对位置再裁。
    if ($选项.ContainsKey('crop') -and $null -ne $选项['crop']) {
        $要裁 = $选项['crop']
        $裁宽 = [int]$要裁.width
        $裁高 = [int]$要裁.height
        # 请求区域和屏幕的交集（屏幕坐标）。交集为空说明这块根本不在屏幕上
        $交集左 = [Math]::Max($矩形.X, [int]$要裁.x)
        $交集上 = [Math]::Max($矩形.Y, [int]$要裁.y)
        $交集右 = [Math]::Min($矩形.X + $原图.Width, [int]$要裁.x + $裁宽)
        $交集下 = [Math]::Min($矩形.Y + $原图.Height, [int]$要裁.y + $裁高)
        if (($交集右 - $交集左) -lt 1 -or ($交集下 - $交集上) -lt 1) {
            throw "裁剪区域完全在屏幕外：x=$($要裁.x) y=$($要裁.y) w=$裁宽 h=$裁高"
        }
        # 关键：图的尺寸严格按请求来，越界部分涂黑。
        # 不把请求区域夹回屏幕，因为夹过一次之后，
        # 调用方算出来的"目标在图里的位置"就和它以为的对不上了。
        $裁剪图 = [System.Drawing.Bitmap]::new($裁宽, $裁高)
        $裁剪画布 = [System.Drawing.Graphics]::FromImage($裁剪图)
        try {
            $裁剪画布.Clear([System.Drawing.Color]::Black)
            $交集宽 = $交集右 - $交集左
            $交集高 = $交集下 - $交集上
            # 目标矩形：交集在裁剪图里的落点；源矩形：交集在整屏截图里的落点
            $目标矩形 = [System.Drawing.Rectangle]::new(($交集左 - [int]$要裁.x), ($交集上 - [int]$要裁.y), $交集宽, $交集高)
            $源矩形 = [System.Drawing.Rectangle]::new(($交集左 - $矩形.X), ($交集上 - $矩形.Y), $交集宽, $交集高)
            $裁剪画布.DrawImage($原图, $目标矩形, $源矩形, [System.Drawing.GraphicsUnit]::Pixel)
        } finally {
            $裁剪画布.Dispose()
        }
        $原图.Dispose()
        $原图 = $裁剪图
    }

    if ($原图.Width -le $最大宽度) { return $原图 }

    $缩放后宽 = $最大宽度
    $缩放后高 = [int][Math]::Round($原图.Height * ($最大宽度 / $原图.Width))
    $缩小图 = New-Object System.Drawing.Bitmap($缩放后宽, $缩放后高)
    $缩放画布 = [System.Drawing.Graphics]::FromImage($缩小图)
    $缩放画布.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $缩放画布.DrawImage($原图, 0, 0, $缩放后宽, $缩放后高)
    $缩放画布.Dispose()
    $原图.Dispose()
    return $缩小图
}

<#
 作用：把位图存成 PNG 文件，并清掉过旧的那些。
 输入：位图对象。
 输出：文件的绝对路径。
#>
function 保存截图 {
    param($位图)

    if (-not (Test-Path -LiteralPath $截图目录)) {
        New-Item -ItemType Directory -Path $截图目录 -Force | Out-Null
    }
    $文件名 = 'shot-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.png'
    $路径 = Join-Path $截图目录 $文件名
    $位图.Save($路径, [System.Drawing.Imaging.ImageFormat]::Png)

    Get-ChildItem -LiteralPath $截图目录 -Filter '*.png' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $截图保留张数 |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    return $路径
}

# ---- 控件树 ----

<#
 作用：把 UIA 的矩形换成普通哈希表，方便转 JSON。空矩形统一给 null。
 输入：UIA 的 Rect 结构。
 输出：@{x, y, width, height} 或 $null。
#>
function 转矩形 {
    param($矩形)
    if ($null -eq $矩形 -or $矩形.IsEmpty) { return $null }
    return @{
        'x'      = [int]$矩形.X
        'y'      = [int]$矩形.Y
        'width'  = [int]$矩形.Width
        'height' = [int]$矩形.Height
    }
}

<#
 作用：枚举屏幕上所有可见顶层窗口，给出标题、进程号、类名和矩形。
       子代理靠这份清单位置"该操作哪个窗口"，不必自己算坐标。
 输入：无。
 输出：窗口对象数组，按 Z 序（靠前的先出现）。属性取不到的窗口直接跳过，不报错。
#>
function 列出顶层窗口 {
    $根 = [System.Windows.Automation.AutomationElement]::RootElement
    $条件 = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Window
    )
    $窗口们 = $根.FindAll([System.Windows.Automation.TreeScope]::Children, $条件)

    $结果 = New-Object System.Collections.ArrayList
    foreach ($元素 in $窗口们) {
        try {
            if ($元素.Current.IsOffscreen) { continue }
            $标题 = $元素.Current.Name
            if ([string]::IsNullOrWhiteSpace($标题)) { continue }
            $进程号 = $元素.Current.ProcessId
            if ($进程号 -le 0) { continue }
            [void]$结果.Add(@{
                    'title'  = $标题
                    'pid'    = $进程号
                    'class'  = $元素.Current.ClassName
                    'rect'   = (转矩形 $元素.Current.BoundingRectangle)
                })
        } catch {
            # 窗口在枚举途中关掉了，UIA 会抛异常，跳过它继续
        }
    }
    return $结果.ToArray()
}

<#
 作用：在 UIA 控件树里按名字找元素，给定位工具当"第一优先"用。
       能按名字命中的控件（按钮、菜单、链接、输入框）根本不需要图像模型，直接拿它自己的矩形最准。
 输入：描述（要匹配的名字，模糊匹配）、窗口标题（可选，空则用当前活动窗口）、最多返回几个。
 输出：数组，每项 @{name, role, rect, score, enabled}，按分数从高到低。找不到就是空数组。
#>
function 在控件树里找 {
    param([string]$描述, [string]$窗口标题 = '', [int]$最多 = 8)

    $根 = $null
    if (-not [string]::IsNullOrWhiteSpace($窗口标题)) {
        $桌面根 = [System.Windows.Automation.AutomationElement]::RootElement
        $窗口们 = $桌面根.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition
        )
        foreach ($窗口 in $窗口们) {
            try {
                if ($窗口.Current.Name -like "*$窗口标题*") { $根 = $窗口; break }
            } catch {
                # 枚举途中窗口关掉了，跳过
            }
        }
    }
    if ($null -eq $根) {
        $句柄 = [AssistNative.InputApi]::GetForegroundWindow()
        if ($句柄 -ne [System.IntPtr]::Zero) {
            try { $根 = [System.Windows.Automation.AutomationElement]::FromHandle($句柄) } catch { $根 = $null }
        }
    }
    if ($null -eq $根) { $根 = [System.Windows.Automation.AutomationElement]::RootElement }

    $小描述 = $描述.Trim().ToLowerInvariant()
    $候选 = New-Object System.Collections.ArrayList
    $屏幕 = 取屏幕矩形

    $元素们 = $根.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    foreach ($元素 in $元素们) {
        try {
            if ($元素.Current.IsOffscreen) { continue }
            $名字 = $元素.Current.Name
            if ([string]::IsNullOrWhiteSpace($名字)) { continue }
            $小名字 = $名字.Trim().ToLowerInvariant()

            $分 = 0
            if ($小名字 -eq $小描述) {
                $分 = 100
            } elseif ($小名字.Contains($小描述)) {
                $分 = 80 - [Math]::Min(30, $小名字.Length - $小描述.Length)
            } elseif ($小描述.Contains($小名字)) {
                $分 = 70 - [Math]::Min(30, $小描述.Length - $小名字.Length)
            } else {
                continue
            }

            $矩形 = 转矩形 $元素.Current.BoundingRectangle
            if ($null -eq $矩形) { continue }
            if ($矩形.width -lt 4 -or $矩形.height -lt 4) { continue }

            $类型 = ($元素.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '')
            # 本来就是拿来点的控件类型，优先
            if ($类型 -in @('Button', 'MenuItem', 'Hyperlink', 'TabItem', 'ListItem', 'CheckBox', 'RadioButton', 'Edit', 'ComboBox')) {
                $分 += 10
            }
            # 容器类元素不是点击目标，降权：找"某按钮"时不该被"整个面板"用自己的名字抢走
            # （实测：找"新会话"会被一个 Tree 用名字"会话"截胡）
            if ($类型 -in @('Tree', 'Pane', 'Group', 'Document', 'Window', 'Custom', 'Text', 'Paragraph', 'Image')) {
                $分 -= 20
            }
            # 占屏超过 20% 的大块再降一次
            $面积 = [long]$矩形.width * [long]$矩形.height
            $屏幕面积 = [long]$屏幕.Width * [long]$屏幕.Height
            if ($屏幕面积 -gt 0 -and $面积 -gt $屏幕面积 * 0.2) {
                $分 -= 15
            }

            [void]$候选.Add(@{
                    'name'    = $名字
                    'role'    = $类型
                    'rect'    = $矩形
                    'score'   = $分
                    'enabled' = $元素.Current.IsEnabled
                })
        } catch {
            # 单个元素读失败不影响整体
        }
    }

    $排好 = $候选 | Sort-Object -Property @{ Expression = { $_.score }; Descending = $true } | Select-Object -First $最多
    if ($null -eq $排好) { return @() }
    return @($排好)
}

# ---- 点击与输入 ----

<#
 作用：把一个按键名字换成 Windows 的虚拟键码。
 输入：名字，如 ctrl、shift、enter、f5、a、7。
 输出：整数虚拟键码。认不出来就抛异常——宁可报错，也不猜一个键按下去。
#>
function 键名转虚拟键码([string]$名字) {
    $小写 = $名字.Trim().ToLowerInvariant()
    switch ($小写) {
        'ctrl' { return 17 }
        'control' { return 17 }
        'alt' { return 18 }
        'shift' { return 16 }
        'win' { return 91 }
        'enter' { return 13 }
        'return' { return 13 }
        'tab' { return 9 }
        'esc' { return 27 }
        'escape' { return 27 }
        'space' { return 32 }
        'backspace' { return 8 }
        'delete' { return 46 }
        'del' { return 46 }
        'insert' { return 45 }
        'home' { return 36 }
        'end' { return 35 }
        'pageup' { return 33 }
        'pagedown' { return 34 }
        'up' { return 38 }
        'down' { return 40 }
        'left' { return 37 }
        'right' { return 39 }
    }
    if ($小写.Length -eq 1) {
        $码 = [int][char]$小写[0]
        if ($码 -ge 97 -and $码 -le 122) { return $码 - 32 }
        if ($码 -ge 48 -and $码 -le 57) { return $码 }
    }
    try {
        return [int][System.Enum]::Parse([System.Windows.Forms.Keys], $名字.Trim(), $true)
    } catch {
        throw "不认识的按键名：$名字"
    }
}

<#
 作用：把 "ctrl+shift+s" 这样的描述拆成一串虚拟键码。
 输入：描述字符串，用加号连接各键。
 输出：整数数组，顺序就是按下的顺序（抬起时自动倒序）。
#>
function 解析组合键([string]$描述) {
    $结果 = New-Object System.Collections.Generic.List[int]
    foreach ($段 in ($描述 -split '\+')) {
        $名字 = $段.Trim()
        if ([string]::IsNullOrEmpty($名字)) { continue }
        [void]$结果.Add((键名转虚拟键码 $名字))
    }
    # 前置逗号让调用方拿到完整数组，不会被 PowerShell 展开成单个数字
    return , $结果.ToArray()
}

<#
 作用：试着用 UIA（界面自动化接口）的语义模式去点坐标下的控件。
       这条路不移动真实鼠标、不抢焦点，是对用户干扰最小的那条。
 输入：屏幕坐标 x、y。
 输出：@{ok, reason, element, type, pattern}。ok 为假时 reason 说明为什么不行。
 注意：这条路靠不住。实测 WinForms 的控件常被报成 Pane、不支持 InvokePattern，
       所以它只能当优化路径，调用方必须保留坐标点击兜底。
#>
function 尝试语义点击([int]$x, [int]$y) {
    $未成 = @{ 'ok' = $false; 'reason' = ''; 'element' = $null; 'type' = $null; 'pattern' = $null }

    $元素 = $null
    try {
        $点 = New-Object System.Windows.Point([double]$x, [double]$y)
        $元素 = [System.Windows.Automation.AutomationElement]::FromPoint($点)
    } catch {
        $未成.reason = "取坐标处的 UIA 元素失败：$($_.Exception.Message)"
        return $未成
    }
    if ($null -eq $元素) {
        $未成.reason = '坐标处没有 UIA 元素'
        return $未成
    }

    $名字 = ''
    $类型名 = ''
    try {
        $名字 = [string]$元素.Current.Name
        $类型名 = [string]$元素.Current.ControlType.ProgrammaticName
    } catch {
        # 元素在取属性时消失了，后面按无名元素处理
    }

    $候选 = @(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [System.Windows.Automation.TogglePattern]::Pattern,
        [System.Windows.Automation.SelectionItemPattern]::Pattern,
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern
    )

    foreach ($模式 in $候选) {
        $对象 = $null
        $支持 = $false
        try { $支持 = $元素.TryGetCurrentPattern($模式, [ref]$对象) } catch { $支持 = $false }
        if (-not $支持) { continue }
        try {
            if ($模式 -eq [System.Windows.Automation.InvokePattern]::Pattern) { $对象.Invoke() }
            elseif ($模式 -eq [System.Windows.Automation.TogglePattern]::Pattern) { $对象.Toggle() }
            elseif ($模式 -eq [System.Windows.Automation.SelectionItemPattern]::Pattern) { $对象.Select() }
            else { $对象.Expand() }
            # 语义调用只保证"控件的默认动作发生了"，不保证键盘焦点跟过来。
            # 接下来还要打字的话焦点必须落在这个元素上，所以补一次 SetFocus，并给它一点时间生效
            try { $元素.SetFocus() } catch { }
            Start-Sleep -Milliseconds 100
            return @{
                'ok'      = $true
                'reason'  = ''
                'element' = $名字
                'type'    = $类型名
                'pattern' = [string]$模式.ProgrammaticName
            }
        } catch {
            # 声明支持但实际调用失败，换下一个模式试
        }
    }

    $未成.reason = "元素「$名字」（$类型名）不支持任何语义点击模式"
    $未成.element = $名字
    $未成.type = $类型名
    return $未成
}

<#
 作用：在指定坐标点一下，自动挑干扰最小的可行路线。
 输入：x、y 屏幕坐标；按键（1 左 / 2 右 / 3 中，默认 1）；次数（默认 1，双击给 2）；
       路线 auto（默认，语义优先、不行转真实鼠标）、uia、post（后台消息，不抢焦点）、input（强制真实鼠标）。
 输出：@{via, element, type, pattern, note}，via 说明实际走了哪条路。
#>
function 点击坐标 {
    param(
        [int]$x,
        [int]$y,
        [int]$按键 = 1,
        [int]$次数 = 1,
        [string]$路线 = 'auto'
    )

    # 虚拟光标先滑过去，让用户看得见模型要点哪里。它只是个看得见的箭头，不抢焦点
    平滑移动光标到 $x $y

    $记录 = @{ 'via' = $null; 'element' = $null; 'type' = $null; 'pattern' = $null; 'note' = $null }

    if ($路线 -eq 'uia' -or $路线 -eq 'auto') {
        $语义 = 尝试语义点击 $x $y
        if ($语义.ok) {
            $记录.via = 'uia'
            $记录.element = $语义.element
            $记录.type = $语义.type
            $记录.pattern = $语义.pattern
            return $记录
        }
        $记录.note = $语义.reason
        if ($路线 -eq 'uia') { throw "语义点击失败：$($语义.reason)" }
    }

    if ($路线 -eq 'post') {
        $窗口 = [AssistNative.InputApi]::DescribeWindowAt($x, $y)
        if ([string]::IsNullOrEmpty($窗口)) { throw "坐标 ($x, $y) 处没有窗口，无法后台点击" }
        $部分 = $窗口 -split '\|'
        if ($部分.Count -lt 3) { throw "读窗口信息失败：$窗口" }
        $句柄 = [System.IntPtr]::new([long]$部分[0])
        $成功 = [AssistNative.InputApi]::PostClickScreen($句柄, $x, $y, $按键)
        if (-not $成功) { throw "后台点击失败：坐标 ($x, $y)，窗口 $($部分[2])" }
        $记录.via = 'post'
        $记录.element = "窗口类名 $($部分[2])，进程 $($部分[1])"
        return $记录
    }

    $成功 = [AssistNative.InputApi]::ClickScreen($x, $y, $按键, $次数)
    if (-not $成功) { throw "真实鼠标点击失败：坐标 ($x, $y)" }
    $记录.via = 'input'
    return $记录
}

<#
 作用：往当前焦点处输入文字，可选先点一下某个坐标把焦点抢过来。
 输入：文字；可选的 x、y（给了就先点这里再打字）。没给坐标就别传这两个参数。
 输出：成功发出的字符数。
 说明：走 KEYEVENTF_UNICODE 逐字符发送，中文和标点直接按字符码送进去，不依赖键盘布局。
#>
function 输入文字 {
    param([string]$文字, $x = $null, $y = $null)

    if ($null -ne $x -and $null -ne $y) {
        $目标x = [int]$x
        $目标y = [int]$y
        平滑移动光标到 $目标x $目标y
        if (-not [AssistNative.InputApi]::ClickScreen($目标x, $目标y, 1, 1)) {
            throw "输入前点击焦点失败：坐标 ($目标x, $目标y)"
        }
        Start-Sleep -Milliseconds 150
    }
    return [AssistNative.InputApi]::TypeUnicode($文字)
}

# ---- 急停：连按三次 ESC ----

# 用户连按三次 ESC 就立刻暂停鼠标操作。这是给"AI 点到不该点的地方"准备的闸刀：
# 脚本一次能连着做十几步，光靠事前确认不够，得有一个当场能掐断的开关。
# 状态放在脚本作用域，进程活着就一直有效。
# 助手进程重启会清空——这是有意的，重启意味着重新开始，不该继承上次的暂停。
$script:已暂停 = $false

# 最近几次 ESC 按下的时刻。只有 1 秒内连按三次才触发，
# 免得用户随手按两下 ESC 就把操作锁死。
$script:ESC按下时刻 = @()
$script:ESC判定窗口毫秒 = 1000

<#
 作用：检查用户有没有连按三次 ESC，有就切换暂停状态。
 输入：无。
 输出：无。副作用是改 $script:已暂停，并响一声提示音。
 说明：靠轮询而不是键盘钩子——钩子需要消息循环，而助手是个没有窗口的管道进程，
       起消息循环会和主循环打架。轮询一次只读一个键的状态，开销可以忽略。
       读的是 GetAsyncKeyState 的最低位（"自上次调用以来按过没有"），不是高位，
       因为高位只反映"此刻正按住"，快速连按三下时中间那两下早就抬起来了，会漏掉。
#>
function 检查急停 {
    $按过 = ([AssistNative.InputApi]::GetAsyncKeyState(0x1B) -band 0x0001) -ne 0
    if (-not $按过) { return }

    $现在 = Get-Date
    $最近 = @($script:ESC按下时刻 | Where-Object { ($现在 - $_).TotalMilliseconds -lt $script:ESC判定窗口毫秒 })
    $script:ESC按下时刻 = @($最近 + $现在)
    if ($script:ESC按下时刻.Count -lt 3) { return }

    $script:ESC按下时刻 = @()
    $script:已暂停 = -not $script:已暂停
    if ($script:已暂停) {
        写日志 '急停：用户连按三次 ESC，暂停鼠标操作'
        try { [System.Media.SystemSounds]::Hand.Play() } catch { }
    } else {
        写日志 '解除：用户又连按三次 ESC，恢复鼠标操作'
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
    }
}

<#
 作用：判断一条请求是不是会动鼠标或键盘。
 输入：操作名。
 输出：布尔值。
 说明：暂停时这些一律拒绝执行。查询类（status / look / windows）仍然放行，
       因为用户按下暂停之后，往往还想看看屏幕上到底发生了什么。
#>
function 是动鼠标键盘的操作([string]$操作) {
    return @('click', 'move', 'type', 'key', 'scroll') -contains $操作
}

# ---- 请求处理 ----

<#
 作用：处理一条请求，返回一条响应。
 输入：一行 JSON 文本。
 输出：响应哈希表。含 id、ok、data、error；另用私有键 interrupt 表示"本条处理完就退出"。
#>
function 处理一行请求([string]$原文) {
    # 有人来找我办事，空闲计时重新开始
    $script:最后活动时刻 = Get-Date
    # 每条请求进来先看一次急停：脚本是连着发好几条的，
    # 用户在这中间按了 ESC，也能在下一步之前被拦住
    检查急停
    $响应 = @{ 'id' = $null; 'ok' = $false; 'data' = $null; 'error' = $null }

    if ([string]::IsNullOrWhiteSpace($原文)) {
        $响应.error = '空请求'
        return $响应
    }

    try {
        $请求 = $原文 | ConvertFrom-Json
    } catch {
        $响应.error = "请求不是合法 JSON：$($_.Exception.Message)"
        return $响应
    }
    $响应.id = $请求.id
    $操作 = [string]$请求.op

    # 急停期间，凡是会动鼠标或键盘的一律拒绝。
    # 这里必须报"失败"而不是静默忽略：调用方要知道这是被人掐断的，
    # 否则它会当成偶发故障，一遍遍重试，反而更难收拾。
    if ($script:已暂停 -and (是动鼠标键盘的操作 $操作)) {
        $响应.error = '用户连按三次 ESC，已暂停鼠标操作。这是人工干预，需要用户本人再连按三次 ESC 才能解除。'
        return $响应
    }

    try {
        switch ($操作) {

            'status' {
                $屏幕 = 取屏幕矩形
                $光标 = 取光标窗位置
                $响应.data = @{
                    'pid'       = $PID
                    'pipe'      = $PipeName
                    'screen'    = @{ 'x' = $屏幕.X; 'y' = $屏幕.Y; 'width' = $屏幕.Width; 'height' = $屏幕.Height }
                    'cursor'    = @{ 'x' = $光标.x; 'y' = $光标.y; 'visible' = $true }
                    'shots'     = $当前状态.shots
                    'lastShot'  = $当前状态.lastShot
                    'startedAt' = $当前状态.startedAt
                    'dpi'       = $已声明DPI
                    'paused'    = $script:已暂停
                }
                $响应.ok = $true
            }

            'cursor' {
                确保光标窗进程
                $光标 = 取光标窗位置
                $响应.data = @{ 'x' = $光标.x; 'y' = $光标.y }
                $响应.ok = $true
            }

            'move' {
                $目标x = [int]$请求.x
                $目标y = [int]$请求.y
                $要平滑 = $true
                if ($null -ne $请求.smooth) { $要平滑 = [bool]$请求.smooth }
                if ($要平滑) { 平滑移动光标到 $目标x $目标y } else { 移动光标到 $目标x $目标y }
                $光标 = 取光标窗位置
                $响应.data = @{ 'x' = $光标.x; 'y' = $光标.y }
                $响应.ok = $true
            }

            'look' {
                $选项 = @{}
                if ($null -ne $请求.hideCursor) { $选项['hideCursor'] = [bool]$请求.hideCursor }
                if ($null -ne $请求.maxWidth) { $选项['maxWidth'] = [int]$请求.maxWidth }
                # 裁剪：把请求的屏幕区域收进屏幕边界，记下实际生效的那一块，
                # 调用方要拿它把"裁剪图里的坐标"换回屏幕坐标
                $实际裁剪 = $null
                if ($null -ne $请求.crop) {
                    $屏幕 = 取屏幕矩形
                    $裁宽 = [int]$请求.crop.width
                    $裁高 = [int]$请求.crop.height
                    if ($裁宽 -lt 8 -or $裁高 -lt 8) { throw "裁剪区域太小：w=$裁宽 h=$裁高" }
                    # 只检查"和屏幕还有没有交集"，不再把区域夹回屏幕内：
                    # 裁剪图的尺寸永远等于请求的尺寸，越界部分由抓屏幕位图补黑边，
                    # 这样请求里的每个坐标在图里的位置都是精确的，可以放心反算
                    $交集宽 = [Math]::Min($屏幕.X + $屏幕.Width, [int]$请求.crop.x + $裁宽) - [Math]::Max($屏幕.X, [int]$请求.crop.x)
                    $交集高 = [Math]::Min($屏幕.Y + $屏幕.Height, [int]$请求.crop.y + $裁高) - [Math]::Max($屏幕.Y, [int]$请求.crop.y)
                    if ($交集宽 -lt 8 -or $交集高 -lt 8) { throw "裁剪区域几乎完全在屏幕外：x=$($请求.crop.x) y=$($请求.crop.y) w=$裁宽 h=$裁高" }
                    $实际裁剪 = @{ 'x' = [int]$请求.crop.x; 'y' = [int]$请求.crop.y; 'width' = $裁宽; 'height' = $裁高 }
                    $选项['crop'] = $实际裁剪
                }
                $位图 = 抓屏幕位图 -选项 $选项
                try {
                    $路径 = 保存截图 -位图 $位图
                    $宽 = $位图.Width
                    $高 = $位图.Height
                } finally {
                    $位图.Dispose()
                }
                $字节数 = (Get-Item -LiteralPath $路径).Length
                $当前状态.shots = $当前状态.shots + 1
                $当前状态.lastShot = $路径
                $响应.data = @{
                    'path'   = $路径
                    'width'  = $宽
                    'height' = $高
                    'bytes'  = $字节数
                }
                if ($null -ne $实际裁剪) { $响应.data['crop'] = $实际裁剪 }
                $响应.ok = $true
            }

            'windows' {
                $响应.data = @{ 'windows' = @(列出顶层窗口) }
                $响应.ok = $true
            }

            'active' {
                # 当前前台窗口的标题和矩形。给定位工具当默认搜索范围用：
                # 只在一个窗口里找目标，命中率比全屏找高得多
                $句柄 = [AssistNative.InputApi]::GetForegroundWindow()
                $数据 = @{}
                if ($句柄 -ne [System.IntPtr]::Zero) {
                    $矩形 = [AssistNative.DesktopApi+RECT]::new()
                    if ([AssistNative.DesktopApi]::GetWindowRect($句柄, [ref]$矩形)) {
                        $数据['rect'] = @{
                            'x'      = [int]$矩形.Left
                            'y'      = [int]$矩形.Top
                            'width'  = [int]($矩形.Right - $矩形.Left)
                            'height' = [int]($矩形.Bottom - $矩形.Top)
                        }
                    }
                    try {
                        $元素 = [System.Windows.Automation.AutomationElement]::FromHandle($句柄)
                        $数据['title'] = $元素.Current.Name
                        $数据['class'] = $元素.Current.ClassName
                    } catch {
                        # 读不到标题不算失败，矩形才是主要的
                    }
                    $进程号 = [uint32]0
                    [void][AssistNative.InputApi]::GetWindowThreadProcessId($句柄, [ref]$进程号)
                    $数据['pid'] = [int]$进程号
                }
                $响应.data = $数据
                $响应.ok = $true
            }

            'motion' {
                # 把帧环里最近这一段的变化拼成一张图交出去。
                # 和 look 的区别：look 是"此刻"，motion 是"刚才这一段时间"。
                if ($null -eq $script:帧环) { throw '帧环没有启动，看变化的功能不可用' }
                $几张 = 4
                if ($null -ne $请求.count) { $几张 = [int]$请求.count }
                if ($几张 -lt 2) { $几张 = 2 }
                if ($几张 -gt 9) { $几张 = 9 }
                if ($script:帧环.Count -eq 0) { throw '帧环里还没有帧：它每秒截一张，等一秒再来要' }

                # since 是调用方上次拿到图的时刻（Unix 毫秒）。有它才能只取
                # "上一次交付到现在"这一段——那正是模型的感知间隔。
                # 没给就取缓冲里最老的那些，等价于"尽可能长的一段"。
                $起点 = [DateTime]::MinValue
                if ($null -ne $请求.since) {
                    try {
                        $起点 = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$请求.since).LocalDateTime
                    } catch {
                        $起点 = [DateTime]::MinValue
                    }
                }
                $拼图 = $script:帧环.Compose($几张, $起点)
                if ($null -eq $拼图) { throw '拼接没有拿到帧' }

                if (-not (Test-Path -LiteralPath $截图目录)) {
                    New-Item -ItemType Directory -Path $截图目录 -Force | Out-Null
                }
                $文件名 = 'motion-{0}.jpg' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
                $路径 = Join-Path $截图目录 $文件名
                [System.IO.File]::WriteAllBytes($路径, $拼图.Jpeg)

                $当前状态.shots = $当前状态.shots + 1
                $当前状态.lastShot = $路径

                $列 = if ($拼图.Count -le 2) { $拼图.Count } else { 2 }
                $行 = [int][Math]::Ceiling($拼图.Count / $列)
                $响应.data = @{
                    'path'   = $路径
                    'count'  = $拼图.Count
                    'span'   = [Math]::Round($拼图.SpanSeconds, 2)
                    'times'  = $拼图.Times
                    'width'  = $script:帧环.Width * $列
                    'height' = $script:帧环.Height * $行
                }
                $响应.ok = $true
            }

            'find' {
                $描述 = [string]$请求.text
                if ([string]::IsNullOrWhiteSpace($描述)) { throw 'find 需要一个 text 描述' }
                $窗口标题 = ''
                if ($null -ne $请求.window) { $窗口标题 = [string]$请求.window }
                $最多 = 8
                if ($null -ne $请求.limit) { $最多 = [int]$请求.limit }
                $匹配 = @(在控件树里找 -描述 $描述 -窗口标题 $窗口标题 -最多 $最多)
                $响应.data = @{ 'matches' = $匹配 }
                $响应.ok = $true
            }

            'click' {
                # 坐标可以不给：desktop_locate 已经把光标窗挪到目标上了，
                # 光标窗左上角的尖端正对目标点，所以直接点它所在的位置就行。
                # 这条路径是有意设计的——上游不需要把坐标传来传去，
                # 也就不会出现"算出来的坐标"和"实际看到的位置"对不上的问题。
                if ($null -ne $请求.x -and $null -ne $请求.y) {
                    $目标x = [int]$请求.x
                    $目标y = [int]$请求.y
                } else {
                    $光标 = 取光标窗位置
                    $目标x = [int]$光标.x
                    $目标y = [int]$光标.y
                }
                $哪个键 = 1
                if ($null -ne $请求.button) {
                    if ($请求.button -is [string]) {
                        switch (([string]$请求.button).ToLowerInvariant()) {
                            'left' { $哪个键 = 1 }
                            'right' { $哪个键 = 2 }
                            'middle' { $哪个键 = 3 }
                            default { throw "不认识的鼠标键：$($请求.button)" }
                        }
                    } else {
                        $哪个键 = [int]$请求.button
                    }
                }
                $几次 = 1
                if ($null -ne $请求.count) { $几次 = [int]$请求.count }
                $走法 = 'auto'
                if ($null -ne $请求.mode) { $走法 = ([string]$请求.mode).ToLowerInvariant() }
                $结果 = 点击坐标 -x $目标x -y $目标y -按键 $哪个键 -次数 $几次 -路线 $走法
                $结果['x'] = $目标x
                $结果['y'] = $目标y
                $响应.data = $结果
                $响应.ok = $true
            }

            'type' {
                $文字 = [string]$请求.text
                if ([string]::IsNullOrEmpty($文字)) { throw 'type 的 text 不能为空' }
                $点了 = $false
                if ($null -ne $请求.x -and $null -ne $请求.y) {
                    $发了 = 输入文字 -文字 $文字 -x $请求.x -y $请求.y
                    $点了 = $true
                } else {
                    $发了 = 输入文字 -文字 $文字
                }
                $响应.data = @{ 'chars' = $发了; 'clicked' = $点了 }
                $响应.ok = $true
            }

            'key' {
                $描述 = [string]$请求.keys
                if ([string]::IsNullOrEmpty($描述)) { throw 'key 的 keys 不能为空，例如 ctrl+s 或 enter' }
                $键表 = [int[]](解析组合键 $描述)
                if ($键表.Length -eq 0) { throw "组合键解析为空：$描述" }
                $按住毫秒 = 30
                if ($null -ne $请求.holdMs) { $按住毫秒 = [int]$请求.holdMs }
                $按下成功 = [AssistNative.InputApi]::PressChord($键表, $按住毫秒)
                if (-not $按下成功) { throw "按键发送失败：$描述" }
                $响应.data = @{ 'keys' = $键表; 'chord' = $描述 }
                $响应.ok = $true
            }

            'scroll' {
                $光标 = 取光标窗位置
                $滚x = $光标.x
                $滚y = $光标.y
                if ($null -ne $请求.x) { $滚x = [int]$请求.x }
                if ($null -ne $请求.y) { $滚y = [int]$请求.y }
                $格 = 3
                if ($null -ne $请求.delta) { $格 = [int]$请求.delta }
                $滚成功 = [AssistNative.InputApi]::ScrollWheel($滚x, $滚y, $格)
                if (-not $滚成功) { throw "滚轮发送失败：坐标 ($滚x, $滚y)，格数 $格" }
                $响应.data = @{ 'x' = $滚x; 'y' = $滚y; 'delta' = $格 }
                $响应.ok = $true
            }

            'shutdown' {
                # 退出前先把录屏定时器停掉，别留下一个在后台空转的线程
                if ($null -ne $script:帧环) {
                    try { $script:帧环.Stop() } catch { }
                }
                $响应.data = @{ 'stopping' = $true }
                $响应.ok = $true
                $响应['interrupt'] = $true
            }

            default {
                $响应.error = "未知操作：$操作"
            }
        }
    } catch {
        $响应.ok = $false
        $响应.data = $null
        $响应.error = $_.Exception.Message
    }

    return $响应
}

# ---- 主循环 ----

# 先把"我要启动了"写进日志。这一行必须排在拉起光标窗之前——
# 光标窗起不来时助手会直接退出，如果这行在后面，日志里就只剩上一轮的旧记录，
# 看起来像"这次根本没启动过"，会把排查方向带歪（踩过）。
$空闲说明 = if ($IdleTimeoutMs -gt 0) { "空闲 ${IdleTimeoutMs}ms 后自动退出" } else { '常驻，不自动退出' }
写日志 "启动：pid=$PID 管道=$PipeName 带光标=$WithCursor DPI=$已声明DPI $空闲说明"

# 从这一刻起开始录屏。
# 为什么要一开机就录：模型什么时候想看图是说不准的，等它开口再录，
# 它想看的"刚才那几秒"已经过去了。录的是一个 40 秒的滚动窗口，
# 内存里放 JPEG，不落盘，平时几乎不占 CPU（实测一张 7 毫秒）。
if ($帧环可用) {
    try {
        $script:帧环 = New-Object FrameRing
        $script:帧环.Start(640, 360, 1000, 40)
        写日志 "帧环已启动：640×360，1 秒一帧，缓存 40 秒"
    } catch {
        $script:帧环 = $null
        写日志 "帧环启动失败，看变化的功能将不可用：$($_.Exception.Message)"
    }
} else {
    $script:帧环 = $null
    写日志 "帧环类编译失败，看变化的功能不可用（其余功能不受影响）"
}

# 启动时若要求带光标，先把光标窗拉起来；这一步失败要让调用方立刻知道
if ($WithCursor) {
    try {
        确保光标窗进程
    } catch {
        写日志 "光标窗启动失败：$($_.Exception.Message)"
        throw
    }
}

$编码 = New-Object System.Text.UTF8Encoding($false)
$管道 = New-Object System.IO.Pipes.NamedPipeServerStream -ArgumentList @(
    $PipeName,
    [System.IO.Pipes.PipeDirection]::InOut,
    1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte,
    [System.IO.Pipes.PipeOptions]::None
)
# 最大实例数给 1，再启动一个同样的助手会直接炸，正好防止两个助手抢同一个光标窗

# 最后一次"有人来找我办事"的时刻。空闲计时从这里起算
$script:最后活动时刻 = Get-Date

$应退出 = $false

try {
    while (-not $应退出) {
        # 等连接的同时盯空闲和急停：WaitForConnectionAsync 让主循环每 50 毫秒醒一次。
        # 50 毫秒不是随手的数——用户连按三次 ESC 的间隔大约一两百毫秒，
        # 醒得太慢就会把三次并成一次，急停按不出来。
        $连接任务 = $管道.WaitForConnectionAsync()
        $空转计数 = 0
        while ($true) {
            if ($连接任务.Wait(50)) { break }
            检查急停
            $空转计数 += 1
            # 空闲判断没必要这么勤，每 10 次（约 500 毫秒）看一遍就够了
            if ($空转计数 -ge 10 -and $IdleTimeoutMs -gt 0) {
                $空转计数 = 0
                $空闲毫秒 = ((Get-Date) - $script:最后活动时刻).TotalMilliseconds
                if ($空闲毫秒 -gt $IdleTimeoutMs) {
                    写日志 "空闲 $([int]($空闲毫秒 / 1000)) 秒没人用，自行退出"
                    $应退出 = $true
                    break
                }
            }
        }
        if ($应退出) { break }

        $读管道 = New-Object System.IO.StreamReader -ArgumentList @($管道, $编码, $false, 65536, $true)
        $写管道 = New-Object System.IO.StreamWriter -ArgumentList @($管道, $编码, 65536, $true)
        $写管道.AutoFlush = $true

        while (-not $应退出) {
            # 客户端一个字节都不发就断开时，ReadLine 返回 null
            $一行 = $null
            try {
                $一行 = $读管道.ReadLine()
            } catch {
                break
            }
            if ($null -eq $一行) { break }

            $响应 = 处理一行请求 -原文 $一行
            if ($响应.ContainsKey('interrupt')) { $应退出 = $true }
            $响应.Remove('interrupt')

            $写管道.WriteLine(($响应 | ConvertTo-Json -Depth 8 -Compress))
            $写管道.Flush()
        }

        try { $读管道.Dispose() } catch { }
        try { $写管道.Dispose() } catch { }
        try { $管道.Disconnect() } catch { }
    }
} catch {
    # 主循环一旦抛错，进程就会退出、管道随之消失。必须留下痕迹，否则调用方只会看到"助手连不上"
    写日志 "主循环异常终止：$($_.Exception.GetType().Name)：$($_.Exception.Message)"
    throw
} finally {
    try { $管道.Dispose() } catch { }

    # 退出时把光标窗进程一并结束：助手都不在了，屏幕上不该还留一个箭头、后台也不该还留一个进程
    收掉光标窗
    写日志 "已退出：pid=$PID"
}
