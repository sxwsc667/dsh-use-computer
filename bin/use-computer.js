#!/usr/bin/env node
'use strict'

/**
 * use-computer 命令行工具。
 *
 * 作用：在终端里直接指挥桌面助手——看它状态、挪虚拟光标、截图、列窗口、关掉它。
 * 这是插件之外的第二个入口：模型走插件里的工具，人手调试走这里，两者调的是同一个助手进程。
 *
 * 用法：use-computer <命令> [参数] [--json]
 * 退出码：0 成功，1 失败。
 */

const { 请求桌面, 探测助手, 调用助手 } = require('../lib/assistant-client.js')

/**
 * 作用：打印用法。
 * 输入：无。
 * 输出：无返回值，写标准输出。
 */
function 打印帮助() {
    console.log(`use-computer —— 操作本机桌面的命令行工具

用法：use-computer <命令> [参数] [--json]

命令：
  status                          看助手在不在、屏幕多大、光标在哪
  cursor                          确保虚拟光标出现，报出它的位置
  move <x> <y> [--no-smooth]      把虚拟光标挪到屏幕坐标 (x, y)
  look [--with-cursor] [--max-width 宽度]
                                  截一张全屏图，打印文件路径（默认不带光标、宽 1280）
  windows                         列出屏幕上的顶层窗口
  click <x> <y> [--button left|right|middle] [--count 次数] [--mode auto|uia|post|input]
                                  在坐标处点一下；默认先试界面语义，不行再用真实鼠标
  type "文字" [--at 坐标x,坐标y]   输入文字；给 --at 就先点那里拿焦点再打
  key <组合键>                     发一个按键，如 ctrl+s、enter、alt+f4
  scroll [格数] [--at 坐标x,坐标y] 滚轮；负数向下、正数向上，默认向下 3 格
  stop                            立刻关掉助手进程和虚拟光标
                                  （插件里用 desktop_stop 关掉后，要 desktop_start 才能恢复）
  model [--json]                   看视觉定位要用的模型和推理程序在哪、齐不齐；缺了给出下载地址

开关：
  --json    直接打印原始 JSON，不排版

例子：
  use-computer status
  use-computer move 800 400
  use-computer look --max-width 1600
  use-computer click 640 360
  use-computer type "你好，世界" --at 800 500
  use-computer key ctrl+s
  use-computer windows --json
  use-computer model
`)
}

/**
 * 作用：把命令行参数切成命令、位置参数和开关。
 * 输入：process.argv 去掉前两项后的数组。
 * 输出：{ 命令, 位置参数, 开关 }。开关是对象，出现即为 true，带值的存字符串。
 */
function 解析参数(参数们) {
    const 位置参数 = []
    const 开关 = {}
    let 命令 = ''

    for (let 序号 = 0; 序号 < 参数们.length; 序号++) {
        const 当前 = 参数们[序号]
        if (当前.startsWith('--')) {
            const 名字 = 当前.slice(2)
            const 下一个 = 参数们[序号 + 1]
            if (下一个 !== undefined && !下一个.startsWith('--')) {
                开关[名字] = 下一个
                序号++
            } else {
                开关[名字] = true
            }
            continue
        }
        if (命令 === '') {
            命令 = 当前
        } else {
            位置参数.push(当前)
        }
    }

    return { 命令, 位置参数, 开关 }
}

/**
 * 作用：发一条请求，失败时把 error 变成异常抛出，避免把"ok:false"当成功。
 * 输入：请求对象。
 * 输出：响应里的 data。
 */
async function 取数据(请求) {
    const 响应 = await 请求桌面(请求)
    if (!响应 || 响应.ok !== true) {
        throw new Error((响应 && 响应.error) || '桌面助手返回了无法理解的结果')
    }
    return 响应.data
}

/**
 * 作用：把窗口矩形排版成一行可读文本。
 * 输入：矩形对象或 null。
 * 输出：形如 "x=446 y=64 1920×1200" 的字符串；没有矩形时给"—"。
 */
function 排版矩形(矩形) {
    if (!矩形) return '—'
    return `x=${矩形.x} y=${矩形.y} ${矩形.width}×${矩形.height}`
}

/**
 * 作用：按命令分发执行。
 * 输入：解析后的命令、位置参数、开关。
 * 输出：无返回值；向标准输出写结果。命令不认识时抛错。
 */
async function 执行命令(命令, 位置参数, 开关) {
    if (开关.json) {
        // --json 模式下每个命令都把原始响应打出来，这里统一处理
    }

    switch (命令) {
        case 'status': {
            const 数据 = await 取数据({ op: 'status' })
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            console.log(`助手进程号：${数据.pid}`)
            console.log(`管道：${数据.pipe}`)
            console.log(`屏幕：${数据.screen.width}×${数据.screen.height}（原点 ${数据.screen.x},${数据.screen.y}）`)
            console.log(`DPI 模式：${数据.dpi}`)
            console.log(`虚拟光标：(${数据.cursor.x}, ${数据.cursor.y})`)
            console.log(`已截屏：${数据.shots} 张`)
            if (数据.lastShot) console.log(`最后一张：${数据.lastShot}`)
            console.log(`启动于：${数据.startedAt}`)
            return
        }

        case 'cursor': {
            const 数据 = await 取数据({ op: 'cursor' })
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            console.log(`虚拟光标已在屏幕上，位置 (${数据.x}, ${数据.y})`)
            return
        }

        case 'move': {
            const [原始x, 原始y] = 位置参数
            const x = Number(原始x)
            const y = Number(原始y)
            if (!Number.isFinite(x) || !Number.isFinite(y)) {
                throw new Error('move 需要两个数字：use-computer move <x> <y>')
            }
            const 数据 = await 取数据({ op: 'move', x, y, smooth: !开关['no-smooth'] })
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            console.log(`虚拟光标已到 (${数据.x}, ${数据.y})`)
            return
        }

        case 'look': {
            const 请求 = { op: 'look' }
            if (开关['with-cursor']) 请求.hideCursor = false
            if (开关['max-width']) {
                const 宽度 = Number(开关['max-width'])
                if (!Number.isFinite(宽度) || 宽度 <= 0) {
                    throw new Error('--max-width 要一个正整数')
                }
                请求.maxWidth = Math.round(宽度)
            }
            const 数据 = await 取数据(请求)
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            console.log(数据.path)
            console.log(`（${数据.width}×${数据.height}，${Math.round(数据.bytes / 1024)} KB）`)
            return
        }

        case 'windows': {
            const 数据 = await 取数据({ op: 'windows' })
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            const 窗口们 = 数据.windows || []
            if (窗口们.length === 0) return console.log('没有可用的顶层窗口')
            console.log(`共 ${窗口们.length} 个顶层窗口：`)
            窗口们.forEach((窗口, 序号) => {
                console.log(`${String(序号 + 1).padStart(2, ' ')}. ${窗口.title}`)
                console.log(`    进程 ${窗口.pid} · ${窗口.class} · ${排版矩形(窗口.rect)}`)
            })
            return
        }

        case 'click': {
            const [原始x, 原始y] = 位置参数
            const x = Number(原始x)
            const y = Number(原始y)
            if (!Number.isFinite(x) || !Number.isFinite(y)) {
                throw new Error('click 需要两个数字：use-computer click <x> <y>')
            }
            const 请求 = { op: 'click', x: Math.round(x), y: Math.round(y) }
            if (开关.button) 请求.button = 开关.button
            if (开关.count) 请求.count = Math.round(Number(开关.count))
            if (开关.mode) 请求.mode = 开关.mode
            const 数据 = await 取数据(请求)
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            const 路线名 = { uia: '界面语义', post: '后台消息', input: '真实鼠标' }[数据.via] || 数据.via
            console.log(`已在 (${数据.x}, ${数据.y}) 点击，走的是${路线名}路线`)
            if (数据.element) console.log(`命中的元素：${数据.element}`)
            if (数据.note) console.log(`（语义路线没成，原因：${数据.note}）`)
            return
        }

        case 'type': {
            const 文字 = 位置参数.join(' ')
            if (!文字) {
                throw new Error('type 需要内容：use-computer type "要输入的文字"')
            }
            const 请求 = { op: 'type', text: 文字 }
            if (开关.at) {
                const [点x, 点y] = String(开关.at).split(',')
                const 数字x = Number(点x)
                const 数字y = Number(点y)
                if (!Number.isFinite(数字x) || !Number.isFinite(数字y)) {
                    throw new Error('--at 要写成 坐标x,坐标y，例如 --at 800,400')
                }
                请求.x = Math.round(数字x)
                请求.y = Math.round(数字y)
            }
            const 数据 = await 取数据(请求)
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            console.log(`已输入 ${数据.chars} 个字符${数据.clicked ? '（输入前先点了一下坐标拿焦点）' : ''}`)
            return
        }

        case 'key': {
            const 描述 = 位置参数.join('')
            if (!描述) {
                throw new Error('key 需要按键：use-computer key ctrl+s')
            }
            const 数据 = await 取数据({ op: 'key', keys: 描述 })
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            console.log(`已发送按键：${数据.chord}（键码 ${数据.keys.join(' + ')}）`)
            return
        }

        case 'scroll': {
            const 原始格数 = 位置参数[0]
            const 格数 = 原始格数 === undefined ? -3 : Number(原始格数)
            if (!Number.isFinite(格数)) {
                throw new Error('scroll 的格数要是个数字：复数向下滚，正数向上滚')
            }
            const 请求 = { op: 'scroll', delta: Math.round(格数) }
            if (开关.at) {
                const [点x, 点y] = String(开关.at).split(',')
                请求.x = Math.round(Number(点x))
                请求.y = Math.round(Number(点y))
            }
            const 数据 = await 取数据(请求)
            if (开关.json) return console.log(JSON.stringify(数据, null, 2))
            console.log(`已在 (${数据.x}, ${数据.y}) 滚动 ${数据.delta} 格`)
            return
        }

        case 'stop': {
            if (!(await 探测助手())) {
                console.log('桌面助手本来就没在跑')
                return
            }
            const 响应 = await 调用助手({ op: 'shutdown' })
            if (开关.json) return console.log(JSON.stringify(响应, null, 2))
            console.log('桌面助手和虚拟光标已关闭')
            return
        }

        case 'model': {
            // 只报位置和下载地址，不替用户下：模型合计 2.3 GB，下不下、下到哪由人决定
            const 仓库 = require('../lib/model-store.js')
            const 状况 = 仓库.视觉能力状况()
            if (开关.json) {
                return console.log(
                    JSON.stringify({ 数据目录: 仓库.数据目录, 就绪: 状况.就绪, 文件: 仓库.模型概况() }, null, 2)
                )
            }
            for (const 项 of 仓库.模型概况()) {
                const 现状 = 项.就绪 ? '已就绪' : '缺'
                console.log(`${项.就绪 ? '✓' : '✗'} ${项.文件名}  ${现状}  ${项.路径}`)
            }
            console.log(`${require('node:fs').existsSync(仓库.服务器路径) ? '✓' : '✗'} llama-server.exe  ${仓库.服务器路径}`)
            if (!状况.就绪) {
                console.log('')
                console.log(仓库.下载指引(状况))
            }
            return
        }

        default:
            throw new Error(`不认识的命令：${命令}。用 use-computer --help 看用法`)
    }
}

/**
 * 作用：程序入口。解析参数、执行、兜住所有异常。
 * 输入：无。
 * 输出：无返回值；失败时把退出码设成 1。
 */
async function 主函数() {
    const { 命令, 位置参数, 开关 } = 解析参数(process.argv.slice(2))

    if (命令 === '' || 命令 === 'help' || 开关.help) {
        打印帮助()
        return
    }

    try {
        await 执行命令(命令, 位置参数, 开关)
    } catch (错误) {
        console.error(`失败：${错误.message}`)
        process.exitCode = 1
    }
}

主函数()
