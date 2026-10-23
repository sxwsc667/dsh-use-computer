'use strict'

/**
 * 视觉定位客户端：把"一句人话"变成"屏幕上的一个坐标"。
 *
 * 背后跑的是 UGround-V1-2B（Qwen2-VL-2B 微调的专用定位模型），
 * 由本机 llama.cpp 的 llama-server 提供服务，走 OpenAI 兼容接口。
 *
 * 分工是刻意的：通用大模型负责理解任务、判断大致在哪一片；
 * 这个 2B 小模型只负责在那一小片截图里给出精确的点。
 * 实测依据：目标独占一个紧框时命中率接近 100%，框里混入相似元素才会选错，
 * 所以"范围由调用方给、只让它在范围内挑"是准确率的关键，不是可选优化。
 */

const fs = require('node:fs')
const http = require('node:http')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const 仓库 = require('./model-store.js')

// 服务地址。llama-server 默认监听 8080，这里也允许环境变量换端口
const 服务端口 = Number(process.env.DSH_GROUNDING_PORT || 8080)
const 服务主机 = process.env.DSH_GROUNDING_HOST || '127.0.0.1'
const 服务基址 = `http://${服务主机}:${服务端口}`

// 默认都从 DSH 数据目录取（<数据目录>/UGround-V1-2B-gguf/ 与 <数据目录>/llama.cpp/bin/）。
// 为什么不放插件目录：模型有 2.2 GB，跟插件安装副本绑在一起的话，重装一次就全丢。
// 换机器、换位置时仍可用环境变量覆盖，这是排查和加速的兜底手段。
const 模型目录 = 仓库.模型目录
const 服务器路径 = process.env.DSH_GROUNDING_SERVER || 仓库.服务器路径
const 模型路径 =
    process.env.DSH_GROUNDING_MODEL || path.join(模型目录, 'UGround-V1-2B.Q4_K_M.gguf')
const 视觉投影路径 =
    process.env.DSH_GROUNDING_MMPROJ || path.join(模型目录, 'mmproj-UGround-V1-2B.f16.gguf')

// 服务日志。和助手日志放在同一个临时目录下，排错时一眼就能找到
const 日志目录 = path.join(os.tmpdir(), 'dsh-use-computer')
const 日志路径 = path.join(日志目录, 'grounding.log')

/**
 * 给模型的提示词。模板来自 UGround 官方仓库，改动会直接影响定位准确率。
 * 输出约定：单个 "(x, y)" 字符串，取值 0~1000，是相对所给图片的千分比。
 */
const 提示词模板 = [
    'Your task is to help the user identify the precise coordinates (x, y) of a specific area on the screen based on the description.',
    '',
    '  - Your response should aim to the center of a representative point within the described area or element as accurately as possible.',
    '  - Your answer should be a single string (x, y) corresponding to the point of the interest.',
    '',
    '  Description: {描述}',
    '',
    '  Answer:',
].join('\n')

/**
 * 作用：发一个本地 HTTP 请求，拿回状态码和正文。不依赖 fetch，免得受 Node 版本影响。
 * 输入：{ method, path, body, timeoutMs }。
 * 输出：{ status, body }。网络层出错就抛错。
 */
function 请求本地服务({ method = 'GET', path: 请求路径 = '/', body = null, timeoutMs = 180000 }) {
    return new Promise((解决, 拒绝) => {
        const 头 = { 'Content-Type': 'application/json' }
        if (body !== null) 头['Content-Length'] = Buffer.byteLength(body)

        const 请求 = http.request(
            { hostname: 服务主机, port: 服务端口, path: 请求路径, method, headers: 头 },
            (响应) => {
                const 片段 = []
                let 已中止 = false
                响应.on('data', (块) => {
                    if (已中止) return
                    片段.push(块)
                    // 定位响应只有几十字节，超过 1 MB 一定是出了别的问题
                    if (片段.reduce((和, 块) => 和 + 块.length, 0) > 1024 * 1024) {
                        已中止 = true
                        请求.destroy(new Error('定位服务返回的内容过大，疑似响应错位'))
                    }
                })
                响应.on('end', () => {
                    if (!已中止) 解决({ status: 响应.statusCode, body: Buffer.concat(片段).toString('utf8') })
                })
            }
        )

        请求.setTimeout(timeoutMs, () => 请求.destroy(new Error(`定位服务 ${timeoutMs} 毫秒没有响应`)))
        请求.on('error', 拒绝)
        if (body !== null) 请求.write(body)
        请求.end()
    })
}

/**
 * 作用：探一下定位服务在不在。
 * 输入：超时毫秒。
 * 输出：在的话 true。不抛错。
 */
async function 探测服务(超时毫秒 = 800) {
    try {
        const 结果 = await 请求本地服务({ path: '/health', timeoutMs: 超时毫秒 })
        return 结果.status === 200
    } catch {
        return false
    }
}

/**
 * 作用：把 llama-server 拉起来（独立进程、无窗口），并等到它能应答。
 * 输入：选项可含 等待毫秒。
 * 输出：{ 刚启动: boolean }。
 *
 * 为什么用 detached + unref：宿主调用这个插件的进程是短命的，
 * 子进程默认会跟着一起结束。llama-server 加载模型要好几秒，不能让每次调用都重新加载。
 * detached 之后它挂在系统里独立运行，下次调用直接复用。
 */
async function 确保定位服务在跑(选项 = {}) {
    if (await 探测服务()) return { 刚启动: false }

    for (const 路径 of [服务器路径, 模型路径, 视觉投影路径]) {
        if (!fs.existsSync(路径)) {
            throw new Error(`找不到视觉定位所需的文件：${路径}\n${仓库.下载指引()}`)
        }
    }

    fs.mkdirSync(日志目录, { recursive: true })

    const 参数 = [
        '-m',
        模型路径,
        '--mmproj',
        视觉投影路径,
        '-ngl',
        '99',
        '--host',
        服务主机,
        '--port',
        String(服务端口),
        '-c',
        '8192',
        // Qwen-VL 系列在 grounding 任务上需要足够的图像 token，官方日志明确建议至少 1024
        '--image-min-tokens',
        '1024',
        '--log-file',
        日志路径,
    ]

    const 子进程 = spawn(服务器路径, 参数, {
        detached: true,
        stdio: 'ignore',
        windowsHide: true,
    })
    子进程.unref()

    const 截止时刻 = Date.now() + (选项.等待毫秒 ?? 60000)
    while (Date.now() < 截止时刻) {
        await 睡(500)
        if (await 探测服务(1000)) return { 刚启动: true }
    }

    let 日志尾巴 = ''
    try {
        日志尾巴 = fs.readFileSync(日志路径, 'utf8').split('\n').slice(-20).join('\n').trim()
    } catch {
        // 日志读不到就不贴，不掩盖真正的原因
    }
    throw new Error(`视觉定位服务没能启动。日志（${日志路径}）：\n${日志尾巴 || '（空）'}`)
}

/**
 * 作用：睡一会儿。
 * 输入：毫秒数。
 * 输出：到点后兑现的空 Promise。
 */
function 睡(毫秒) {
    return new Promise((解决) => setTimeout(解决, 毫秒))
}

/**
 * 作用：把模型返回的文本解析成 0~1000 的归一化坐标。
 * 输入：模型原文，例如 "(103, 91)"。
 * 输出：{ x, y } 或 null（解析不出来）。不抛错——由调用方决定怎么报。
 */
function 解析坐标(文本) {
    if (typeof 文本 !== 'string') return null
    const 匹配 = 文本.match(/\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)/)
    const 备选 = 文本.match(/(\d+(?:\.\d+)?)\s*[,，]\s*(\d+(?:\.\d+)?)/)
    const 采用 = 匹配 || 备选
    if (!采用) return null
    const x = Number(采用[1])
    const y = Number(采用[2])
    if (!Number.isFinite(x) || !Number.isFinite(y)) return null
    // 模型理论上给 0~1000，越界说明它没按约定输出，夹回范围内比信它更好
    return { x: Math.max(0, Math.min(1000, x)), y: Math.max(0, Math.min(1000, y)) }
}

/**
 * 作用：在一张图上找目标，返回它相对这张图的千分比坐标。
 * 输入：图片绝对路径、目标描述。
 * 输出：{ x, y, raw, 耗时毫秒 }。x/y 是 0~1000 的千分比；找不到目标时 x/y 为 null。
 */
async function 定位(图片路径, 描述) {
    if (!fs.existsSync(图片路径)) throw new Error(`截图不存在：${图片路径}`)
    const 目标描述 = String(描述 ?? '').trim()
    if (目标描述 === '') throw new Error('定位需要一个目标描述')

    await 确保定位服务在跑()

    const 图片数据 = fs.readFileSync(图片路径).toString('base64')
    const 请求体 = JSON.stringify({
        model: 'UGround',
        messages: [
            {
                role: 'user',
                content: [
                    { type: 'image_url', image_url: { url: `data:image/png;base64,${图片数据}` } },
                    { type: 'text', text: 提示词模板.replace('{描述}', 目标描述) },
                ],
            },
        ],
        // 官方明确要求 greedy：定位是确定性任务，任何采样都会让同一个目标飘
        temperature: 0,
        max_tokens: 24,
    })

    const 开始 = Date.now()
    const 响应 = await 请求本地服务({ method: 'POST', path: '/v1/chat/completions', body: 请求体 })
    const 耗时毫秒 = Date.now() - 开始

    if (响应.status !== 200) {
        throw new Error(`定位服务返回 HTTP ${响应.status}：${响应.body.slice(0, 300)}`)
    }

    let 正文
    try {
        正文 = JSON.parse(响应.body)
    } catch {
        throw new Error(`定位服务返回的不是合法 JSON：${响应.body.slice(0, 300)}`)
    }

    const 原文 = 正文?.choices?.[0]?.message?.content ?? ''
    const 坐标 = 解析坐标(原文)

    return {
        x: 坐标 ? 坐标.x : null,
        y: 坐标 ? 坐标.y : null,
        raw: String(原文).trim(),
        耗时毫秒,
    }
}

module.exports = {
    服务基址,
    服务器路径,
    模型路径,
    视觉投影路径,
    日志路径,
    探测服务,
    确保定位服务在跑,
    定位,
    解析坐标,
}
