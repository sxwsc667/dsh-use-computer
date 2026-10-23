'use strict'

/**
 * 桌面浮窗的控制端：拉起 panel.ps1、把 AI 的输出和当前动作写给它。
 *
 * 为什么用状态文件而不是命名管道：
 *   这个面板只需要"显示最新一段文本"，不需要双向、不需要低延迟确认。
 *   用管道要处理并发写、断线重连、宿主重启后的残留连接；用文件零风险，
 *   面板进程崩了也不会影响正在操作桌面的助手，反过来也一样。
 *   代价是磁盘写入，但每秒最多几次、每次几 KB，可以忽略。
 *
 * 什么时候显形：模型第一次调用桌面工具时。什么时候收起：一段时间没有任何动作。
 */

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFile } = require('node:child_process')
const { promisify } = require('node:util')

const 执行程序 = promisify(execFile)

// 面板脚本位置：和本文件同级的 assistant 目录
const 面板脚本 = path.join(__dirname, 'assistant', 'panel.ps1')

// 状态文件位置。必须和 panel.ps1 里拼出来的路径一致
const 状态目录 = path.join(os.tmpdir(), 'dsh-use-computer')
const 状态文件 = path.join(状态目录, 'panel.json')

// 正文最多留这么多字符，防止文件无限增长
const 正文上限 = 2400

// 写文件的节流间隔：流式输出可能每几十毫秒一段，不必每段都落盘
const 写入间隔毫秒 = 150

// 没有任何动作多久之后自动收起面板
const 空闲收起毫秒 = 15000

// 各操作对应的动作说明，显示在面板第二行
const 操作说明 = {
    look: '正在截屏',
    windows: '正在列出窗口',
    active: '正在读取当前窗口',
    find: '正在界面元素树里找目标',
    move: '正在移动可见光标',
    click: '正在点击',
    type: '正在输入文字',
    key: '正在按键',
    scroll: '正在滚动',
    status: '正在读取屏幕信息',
}

let 面板PID = null
let 累计正文 = ''
let 当前动作 = ''
let 写入定时器 = null
let 收起定时器 = null
let 已经显示 = false
let 启动中 = false

// 解释器和无窗宿主的位置。和 assistant-client.js 用的是同一套
const 解释器 = path.join(
    process.env.SystemRoot || 'C:\\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
)
const 无窗宿主 = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'conhost.exe')

/**
 * 作用：面板进程是不是还活着。
 * 输出：true 表示还活着。
 */
function 面板在跑() {
    if (面板PID === null) return false
    try {
        // 信号 0 不真的发信号，只用来检查进程存在
        process.kill(面板PID, 0)
        return true
    } catch {
        面板PID = null
        return false
    }
}

/**
 * 作用：拉起面板进程。已经在跑就什么都不做。
 *
 * 为什么不用 child_process.spawn：
 * 实测（Windows + Node，在宿主里跑）spawn 出来的 powershell.exe 会随父 node 一起消失，
 * 下一条命令就再也连不上面板了。改用 WMI 的 Win32_Process.Create：
 * 创建出来的进程挂在 WmiPrvSE.exe 名下，不属于当前进程树，父进程退出不会连坐。
 * 再套一层 conhost.exe --headless，是为了不让 Windows Terminal 接过去新开一个标签页。
 */
async function 启动面板() {
    if (面板在跑() || 启动中) return
    if (!fs.existsSync(面板脚本)) return
    if (!fs.existsSync(解释器)) return
    try {
        fs.mkdirSync(状态目录, { recursive: true })
    } catch {
        return
    }

    启动中 = true
    try {
        const 命令行 =
            `"${无窗宿主}" --headless --width 100 --height 30 ` +
            `"${解释器}" -NoProfile -STA -ExecutionPolicy Bypass -File "${面板脚本}"`
        // WMI 的 CommandLine 是一整条字符串，里面用单引号包，内部单引号要翻倍
        const 转义后 = 命令行.replace(/'/g, "''")
        const 创建脚本 = [
            `$结果 = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '${转义后}' }`,
            'if ($结果.ReturnValue -ne 0) { throw "WMI 创建进程失败，返回码 " + $结果.ReturnValue }',
            '$结果.ProcessId',
        ].join('; ')

        const { stdout } = await 执行程序(
            解释器,
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 创建脚本],
            { windowsHide: true },
        )
        const 进程号 = Number(String(stdout).trim())
        if (Number.isFinite(进程号) && 进程号 > 0) 面板PID = 进程号
    } catch {
        // 面板拉不起来不该影响桌面操作本身
    } finally {
        启动中 = false
    }
}

/**
 * 作用：把当前状态落盘。
 * 输入：可见与否。
 */
function 写状态(可见) {
    try {
        fs.mkdirSync(状态目录, { recursive: true })
        const 内容 = JSON.stringify({
            visible: 可见,
            action: 当前动作,
            text: 累计正文,
        })
        fs.writeFileSync(状态文件, 内容, 'utf8')
    } catch {
        // 写不进去就算了，面板保持上一帧，不影响桌面操作
    }
}

/**
 * 作用：安排一次落盘。同一时间窗口里多次调用只写一次。
 * 输入：可见与否。
 */
function 安排写入(可见) {
    已经显示 = 可见
    if (写入定时器 !== null) return
    写入定时器 = setTimeout(() => {
        写入定时器 = null
        写状态(已经显示)
    }, 写入间隔毫秒)
}

/**
 * 作用：重置"空闲收起"的计时。每次有动作就往后推。
 */
function 推迟收起() {
    if (收起定时器 !== null) clearTimeout(收起定时器)
    收起定时器 = setTimeout(() => {
        收起定时器 = null
        安排写入(false)
    }, 空闲收起毫秒)
}

/**
 * 作用：往面板正文追加模型输出的文字。
 * 输入：一段文本。
 * 说明：只在面板已经亮起来之后才追加，避免模型干别的事时也在攒内容。
 */
function 追加正文(文本) {
    if (typeof 文本 !== 'string' || 文本 === '') return
    if (已经显示 !== true) return
    累计正文 += 文本
    if (累计正文.length > 正文上限) {
        累计正文 = 累计正文.slice(累计正文.length - 正文上限)
    }
    安排写入(true)
}

/**
 * 作用：更新面板上那行"正在做什么"，并把面板叫出来。
 * 输入：动作文字。
 */
function 更新动作(文字) {
    const 新文字 = typeof 文字 === 'string' ? 文字 : ''
    if (新文字 !== '') 当前动作 = 新文字
    // 拉起是异步的（要走一次 WMI），这里不等它：面板晚一两百毫秒出现没关系
    启动面板().catch(() => { })
    安排写入(true)
    推迟收起()
}

/**
 * 作用：按操作名更新动作。给工具的请求入口用。
 * 输入：操作名（look / click / type …）。
 */
function 记录操作(操作名) {
    const 说明 = 操作说明[操作名]
    更新动作(说明 === undefined ? '正在操作' : 说明)
}

/**
 * 作用：一次新的对话轮到来了，把上一轮的残留内容清掉。
 */
function 重置面板() {
    累计正文 = ''
    当前动作 = ''
    if (收起定时器 !== null) {
        clearTimeout(收起定时器)
        收起定时器 = null
    }
    安排写入(false)
}

/**
 * 作用：收掉面板进程和定时器。
 */
function 关闭面板() {
    if (写入定时器 !== null) {
        clearTimeout(写入定时器)
        写入定时器 = null
    }
    if (收起定时器 !== null) {
        clearTimeout(收起定时器)
        收起定时器 = null
    }
    try {
        写状态(false)
    } catch { }
    if (面板PID !== null) {
        try {
            process.kill(面板PID)
        } catch { }
        面板PID = null
    }
}

module.exports = {
    追加正文,
    更新动作,
    记录操作,
    重置面板,
    关闭面板,
    状态文件,
}
