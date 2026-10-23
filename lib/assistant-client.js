'use strict'

/**
 * 桌面助手的客户端：负责连管道、必要时把助手拉起来、发一条请求、收回一条响应。
 *
 * 设计取向：一次操作开一条连接、用完就断。
 * 理由是这样不用维护长连接的状态，任意进程都能随时调用，也不会因为谁忘了断开而卡住别的位置。
 * 代价是每次多几毫秒的连接开销——和截图、移动光标本身的耗时相比可以忽略。
 */

const net = require('node:net')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFile } = require('node:child_process')
const { promisify } = require('node:util')
const { 管道全路径, 校验请求 } = require('./pipe-protocol.js')

const 执行程序 = promisify(execFile)

// 助手脚本的位置：和本文件同级的 assistant 目录下
const 助手脚本路径 = path.join(__dirname, 'assistant', 'assistant.ps1')

// 助手日志。助手是由 WMI 拉起的独立进程，没有可重定向的标准输出，
// 所以这份日志由 assistant.ps1 自己追加写
const 助手日志路径 = path.join(os.tmpdir(), 'dsh-use-computer', 'assistant.log')

// 单条请求里允许的最大响应字节数。截图只回路径，所以正常响应都很小，给 8 MB 足够宽容
const 最大响应字节 = 8 * 1024 * 1024

/**
 * 助手是不是被 desktop_stop 明确关掉了。
 *
 * 记这个标记是为了让"开"和"关"都由调用方决定：
 * 关掉之后，后面任何桌面请求都直接报错，不会又悄悄把它拉起来。
 * 插件重新加载时这个值会归零，那时助手要么本来就在跑、要么由下一次调用决定，
 * 两种情况都不会误判成"已关闭"。
 */
let 助手已被明确关闭 = false

/**
 * 作用：睡一会儿。
 * 输入：毫秒数。
 * 输出：到点后兑现的空 Promise。
 */
function 睡(毫秒) {
    return new Promise((解决) => setTimeout(解决, 毫秒))
}

/**
 * 作用：连上命名管道。
 * 输入：超时毫秒。
 * 输出：已连接的套接字。连不上就抛错。
 */
function 连接管道(超时毫秒) {
    return new Promise((解决, 拒绝) => {
        const 套接字 = net.connect(管道全路径)
        let 已决定 = false

        const 定时器 = setTimeout(() => {
            if (已决定) return
            已决定 = true
            套接字.destroy()
            拒绝(new Error(`连接桌面助手超时（${超时毫秒} 毫秒）：管道 ${管道全路径} 没有应答`))
        }, 超时毫秒)

        套接字.once('connect', () => {
            if (已决定) return
            已决定 = true
            clearTimeout(定时器)
            解决(套接字)
        })

        套接字.once('error', (错误) => {
            if (已决定) return
            已决定 = true
            clearTimeout(定时器)
            拒绝(new Error(`连接桌面助手失败：${错误.message}`))
        })
    })
}

/**
 * 作用：在一条已连接的套接字上发请求并读回一行响应。
 * 输入：套接字、请求对象、超时毫秒。
 * 输出：解析好的响应对象。超时或响应不是合法 JSON 时抛错。
 */
function 发送并读一行(套接字, 请求, 超时毫秒) {
    return new Promise((解决, 拒绝) => {
        let 缓冲 = ''
        let 已决定 = false

        const 收尾 = (动作) => {
            if (已决定) return
            已决定 = true
            clearTimeout(定时器)
            套接字.removeAllListeners('data')
            套接字.removeAllListeners('error')
            套接字.removeAllListeners('close')
            动作()
        }

        const 定时器 = setTimeout(() => {
            收尾(() => 拒绝(new Error(`等待桌面助手响应超时（${超时毫秒} 毫秒），请求是 ${请求.op}`)))
        }, 超时毫秒)

        套接字.setEncoding('utf8')

        套接字.on('data', (片段) => {
            缓冲 += 片段
            if (缓冲.length > 最大响应字节) {
                收尾(() => 拒绝(new Error(`桌面助手返回的内容超过 ${最大响应字节} 字节，疑似协议错位`)))
                return
            }
            const 换行位置 = 缓冲.indexOf('\n')
            if (换行位置 < 0) return
            const 一行 = 缓冲.slice(0, 换行位置).replace(/\r$/, '')
            收尾(() => {
                try {
                    解决(JSON.parse(一行))
                } catch (错误) {
                    拒绝(new Error(`桌面助手返回的不是合法 JSON：${一行.slice(0, 200)}`))
                }
            })
        })

        套接字.once('error', (错误) => {
            收尾(() => 拒绝(new Error(`与桌面助手通信出错：${错误.message}`)))
        })

        套接字.once('close', () => {
            收尾(() => 拒绝(new Error('桌面助手提前关闭了连接，没有返回任何响应')))
        })

        套接字.write(JSON.stringify(请求) + '\n')
    })
}

/**
 * 作用：发一条请求给助手，拿回响应。不会自动拉起助手。
 * 输入：请求对象；选项可含 连接超时毫秒、响应超时毫秒。
 * 输出：响应对象（含 ok / data / error）。请求本身不合法时直接抛错，不浪费一次往返。
 */
async function 调用助手(请求, 选项 = {}) {
    const 检查 = 校验请求(请求)
    if (!检查.通过) {
        throw new Error(`请求不合法：${检查.原因}`)
    }

    const 带编号的请求 = { id: 请求.id || `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`, ...请求 }
    const 套接字 = await 连接管道(选项.连接超时毫秒 ?? 5000)
    try {
        return await 发送并读一行(套接字, 带编号的请求, 选项.响应超时毫秒 ?? 120000)
    } finally {
        套接字.destroy()
    }
}

/**
 * 作用：探一下助手在不在。靠"能不能连上管道"判断，连上立刻断开。
 * 输入：超时毫秒。
 * 输出：在的话 true，不在 false。不抛错。
 */
async function 探测助手(超时毫秒 = 500) {
    try {
        const 套接字 = await 连接管道(超时毫秒)
        套接字.destroy()
        return true
    } catch {
        return false
    }
}

/**
 * 作用：判断某个进程号还在不在。
 * 输入：进程号。
 * 输出：在的话 true。不抛错——没有权限去看也当成不在。
 */
function 进程活着(进程号) {
    try {
        process.kill(进程号, 0)
        return true
    } catch {
        return false
    }
}

/**
 * 作用：把助手进程拉起来（后台、无窗口），并等系统确认它已经被创建。
 * 输入：无。
 * 输出：{ 进程号 }。创建失败就抛错。
 *
 * 为什么不用 child_process.spawn 直接起 powershell：
 * 实测（Windows + Node，宿主里跑）spawn 出来的 powershell.exe 会随父 node 一起消失，
 * 下一条命令就再也连不上助手了——连不上不是因为助手写错了，而是它已经死在半路。
 * 改用 WMI 的 Win32_Process.Create：这样创建出来的进程挂在 WmiPrvSE.exe 名下，
 * 不属于当前进程树，父进程退出不会连坐。实测跨命令仍然活着。
 */
async function 启动助手进程() {
    if (!fs.existsSync(助手脚本路径)) {
        throw new Error(`桌面助手脚本不存在：${助手脚本路径}`)
    }

    const 解释器 = path.join(
        process.env.SystemRoot || 'C:\\Windows',
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe'
    )
    if (!fs.existsSync(解释器)) {
        throw new Error(`找不到 Windows PowerShell：${解释器}。这个插件只支持 Windows`)
    }

    fs.mkdirSync(path.dirname(助手日志路径), { recursive: true })

    // 用 conhost.exe --headless 包一层，给助手一个"看不见的控制台"。
    // 不加这层的话（实测）：WMI 直接起裸 powershell.exe，Windows Terminal 会把它接过去新开一个标签页，
    // 那个标签既不能单独关掉（关了就杀助手），也不显示任何有用的东西，纯粹碍眼。
    // 包上 headless 之后实测：终端标签数不变，命令照常执行。
    const 无窗宿主 = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'conhost.exe')
    const 命令行 = `"${无窗宿主}" --headless --width 80 --height 25 "${解释器}" -NoProfile -ExecutionPolicy Bypass -File "${助手脚本路径}" -WithCursor -LogPath "${助手日志路径}"`
    // WMI 的 CommandLine 是一整条字符串，里面用单引号包起来，内部单引号要翻倍
    const 转义后 = 命令行.replace(/'/g, "''")
    const 创建脚本 = [
        `$结果 = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '${转义后}' }`,
        'if ($结果.ReturnValue -ne 0) { throw "WMI 创建进程失败，返回码 " + $结果.ReturnValue }',
        '$结果.ProcessId',
    ].join('; ')

    const { stdout } = await 执行程序(
        解释器,
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 创建脚本],
        { windowsHide: true }
    )

    const 进程号 = Number(String(stdout).trim())
    if (!Number.isFinite(进程号) || 进程号 <= 0) {
        throw new Error(`创建桌面助手进程失败，WMI 返回：${String(stdout).trim() || '（空）'}`)
    }
    return { 进程号 }
}

/**
 * 作用：保证助手在跑。已在跑就直接返回，不在就拉起来并等到能连上。
 * 输入：选项可含 等待毫秒。
 * 输出：{ 刚启动: boolean, 进程号: number|null }。
 */
async function 确保助手在跑(选项 = {}) {
    if (await 探测助手()) {
        return { 刚启动: false, 进程号: null }
    }

    const 已启动 = await 启动助手进程()
    const 截止时刻 = Date.now() + (选项.等待毫秒 ?? 25000)

    while (Date.now() < 截止时刻) {
        await 睡(200)
        if (await 探测助手(800)) {
            return { 刚启动: true, 进程号: 已启动.进程号 }
        }
        // 进程已经没了就没必要再等下去，直接把日志尾巴抛出去
        if (!进程活着(已启动.进程号)) {
            break
        }
    }

    let 日志尾巴 = ''
    try {
        日志尾巴 = fs.readFileSync(助手日志路径, 'utf8').split('\n').slice(-15).join('\n').trim()
    } catch { }
    throw new Error(`桌面助手没能启动。日志（${助手日志路径}）：\n${日志尾巴 || '（空）'}`)
}

/**
 * 作用：确保助手在跑，然后发一条请求。
 * 输入：请求对象、选项（透传给 调用助手）。
 * 输出：响应对象。
 *
 * 如果助手是被 desktop_stop 明确关掉的，这里直接报错，不再偷偷拉起。
 * 这条很关键：一旦"关掉之后下一次调用又自己开了"，开关就等于没有，
 * 调用方永远说不清它此刻到底开没开。
 */
async function 请求桌面(请求, 选项 = {}) {
    if (助手已被明确关闭) {
        throw new Error('桌面助手已经被 desktop_stop 关掉了。要用它，先调用 desktop_start 启动。')
    }
    await 确保助手在跑()
    return 调用助手(请求, 选项)
}

/**
 * 作用：启动助手，并把"已被明确关闭"的标记清掉。
 * 输入：无。
 * 输出：{ 刚启动: boolean, 进程号: number|null }。
 */
async function 启动助手服务() {
    const 结果 = await 确保助手在跑()
    助手已被明确关闭 = false
    return 结果
}

/**
 * 作用：关掉助手，连同屏幕上那个可见光标。
 * 输入：无。
 * 输出：{ 关闭前在跑: boolean }。
 *
 * 关掉之后会等它真的从管道上消失再返回，
 * 否则紧接着的下一条请求可能撞上半死的连接，表现成"时好时坏"。
 */
async function 关闭助手服务() {
    const 关闭前在跑 = await 探测助手(500)
    if (关闭前在跑) {
        try {
            await 调用助手({ op: 'shutdown' }, { 响应超时毫秒: 5000 })
        } catch {
            // 发不进去也没关系，下面按"是否还能连上"来判断结果
        }
    }

    助手已被明确关闭 = true

    const 截止时刻 = Date.now() + 5000
    while (Date.now() < 截止时刻) {
        if (!(await 探测助手(300))) break
        await 睡(120)
    }
    return { 关闭前在跑 }
}

module.exports = {
    助手脚本路径,
    助手日志路径,
    调用助手,
    探测助手,
    启动助手进程,
    确保助手在跑,
    启动助手服务,
    关闭助手服务,
    请求桌面,
}
