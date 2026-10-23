/**
 * DSH 宿主插件：给模型一套直接操作 Windows 桌面的工具。
 *
 * 没有子代理这一层。主对话自己看屏幕、自己点。
 * "算坐标"由 desktop_locate 内部解决：
 *   1. 先查 UIA 控件树按名字命中——有名字的控件（按钮、菜单、链接、输入框）
 *      直接拿它自己的矩形，准且不花模型；
 *   2. 命中不了才退到本地 2B 视觉定位模型（UGround-V1-2B）看截图算坐标。
 */

import path from 'node:path'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import { readFile, mkdir, appendFile } from 'node:fs/promises'

const require = createRequire(import.meta.url)

// lib 下是 CommonJS，Node 会把它们缓存住：改了文件、热重载重新执行本文件，
// require 仍然返回旧版本。每次加载插件时先清掉这几个的缓存，
// 这样改完 lib 里的代码保存即生效，不用重启宿主。
for (const 模块相对路径 of [
  './lib/assistant-client.js',
  './lib/panel-client.js',
  './lib/grounding-client.js',
  './lib/pipe-protocol.js',
]) {
  try {
    delete require.cache[require.resolve(模块相对路径)]
  } catch {
    // 还没加载过就没有缓存可清，正常
  }
}

const { 请求桌面, 启动助手服务, 关闭助手服务 } = require('./lib/assistant-client.js')
const { 定位 } = require('./lib/grounding-client.js')
const 面板 = require('./lib/panel-client.js')

/**
 * 本插件的稳定标识，和 cordis.patch.yml 里插入那一行的 id 对应。
 */
export const name = 'use-computer'

/**
 * 依赖的宿主服务。
 */
export const inject = ['tools']

/**
 * 给模型用的原子工具名。全是主对话直接调，没有中间层。
 */
const 原子工具 = {
  看: 'desktop_look',
  找: 'desktop_locate',
  点: 'desktop_click',
  打: 'desktop_type',
  键: 'desktop_key',
  窗: 'desktop_windows',
}

/**
 * 插件自己的目录，用来拼出 CLI 的绝对路径。
 */
const 插件目录 = path.dirname(fileURLToPath(import.meta.url))

/**
 * 命令行工具的绝对路径，方便人工排错时直接敲。
 */
const 命令行路径 = path.join(插件目录, 'bin', 'use-computer.js')

/**
 * 把一个操作包成"失败就抛错"的形式，避免把 ok:false 当成功往下走。
 *
 * @param 请求 发给桌面助手的请求。
 * @returns 响应里的 data。
 */
async function 取数据(请求) {
  // 每次真正操作桌面之前，先把"正在做什么"推到浮窗上。
  // 用户的对话窗口常被 AI 打开的窗口挡住，这块板子是他唯一能看到进度的地方。
  面板.记录操作(请求?.op)
  const 响应 = await 请求桌面(请求)
  if (!响应 || 响应.ok !== true) {
    throw new Error((响应 && 响应.error) || '桌面助手返回了无法理解的结果')
  }
  return 响应.data
}

/**
 * DeepSeek 模型对图片的最小像素要求。
 *
 * 取自 dsh-llm-deepseek：MIN_PIXELS = 544 * 544，patch 14，按 3:1 下采样。
 * 低于这个面积的图会被模型那边自动放大再喂进去，既糊又白花钱；
 * 正好 544×544 时不会被二次缩放，是"看得清又最省"的尺寸。
 */
const 近景边长 = 544

/**
 * 上一次把图交给模型的时刻（Unix 毫秒）。
 *
 * desktop_motion 用它界定"感知间隔"：从上次交付到现在这一段，
 * 正是模型从拿到信息、想清楚、到发出指令所花的时间。
 * 只按固定时长取帧的话，模型想得久、画面早就全变了，取的却是最后一小截。
 */
let 上次交付时刻 = 0

/**
 * 记一笔"刚把图交出去了"。每次返回值里带图的工具都要调它。
 */
function 记下交付时刻() {
  上次交付时刻 = Date.now()
}

/**
 * 把一张已经落盘的图登记成附件，好让 render 能把它当图片块交给模型。
 *
 * 附件服务不存在、或者存不进去时返回 undefined，调用方退回"只给路径"。
 * 这个降级是必要的：图看不到总比整个调用失败强。
 *
 * @param ctx 宿主上下文。
 * @param 图片路径 图片文件的绝对路径。
 * @returns 预览描述对象，或 undefined。
 */
async function 登记预览(ctx, 图片路径) {
  try {
    const 附件 = ctx.get?.('attachments')
    if (!附件 || typeof 附件.saveImage !== 'function') return undefined
    const 小写 = String(图片路径).toLowerCase()
    const 媒体类型 = 小写.endsWith('.jpg') || 小写.endsWith('.jpeg') ? 'image/jpeg' : 'image/png'
    const 字节 = await readFile(图片路径)
    const 引用 = await 附件.saveImage({ data: 字节, mediaType: 媒体类型, name: path.basename(图片路径) })
    return {
      attachmentId: String(引用.attachmentId),
      mediaType: String(引用.mediaType),
      bytes: Number(引用.bytes),
      width: Number(引用.width),
      height: Number(引用.height),
    }
  } catch {
    return undefined
  }
}

/**
 * 把预览描述转成 render 用的图片内容块。
 *
 * @param 预览 登记预览 的返回值。
 * @returns 内容块，或 undefined（没有图时）。
 */
function 图片内容块(预览) {
  if (预览 === undefined || typeof 预览?.attachmentId !== 'string' || 预览.attachmentId === '') return undefined
  return {
    type: 'image',
    attachment: {
      attachmentId: 预览.attachmentId,
      mediaType: String(预览.mediaType ?? 'image/png'),
      bytes: Number(预览.bytes ?? 0),
      width: Number(预览.width ?? 0),
      height: Number(预览.height ?? 0),
    },
  }
}

/**
 * 定位成功后的收尾：把那条可见的鱼挪到目标上，再截一张目标周围的小图。
 *
 * 这是整套工具的分工核心：**坐标只在小模型和助手进程之间流转，不进对话**。
 * 视觉定位模型算出 (x, y) 之后，这里直接拿它挪光标、裁图，
 * 交回给对话的只有一张图。对话里的模型不需要、也不应该拿到坐标：
 * 它没法验证一个数字对不对，只能看图确认"光标停的这个东西是不是我要的"。
 *
 * 还有一条同样重要：**图要跟着结果一起回来**。
 * 只给路径的话，模型还得再调一次 read_image 才看得到，
 * 那就是白白多一轮思考——按一轮几秒算，一天下来全是这类空转。
 * 适配器支持 tool_result 里带图片，所以直接把图塞进返回值。
 *
 * 有一条约束必须守住：**目标永远在图的正中心，误差为零**。
 * 屏幕边缘那半张图靠补黑边凑满，绝不能为了凑正方形去平移裁剪框——
 * 一平移，图中心就不是目标了，看图的人会判断错。
 *
 * @param ctx 宿主上下文，用来取附件服务。
 * @param x 目标屏幕 x，只在本函数内部使用。
 * @param y 目标屏幕 y，只在本函数内部使用。
 * @param 附加 要并进返回值的其它字段。
 * @returns 近景图路径、可直接放进结果的图片，不带坐标。
 */
async function 定位收尾(ctx, x, y, 附加 = {}) {
  // 先把鱼挪过去。挪不动不影响截图，但用户就看不到"要点的在哪"了
  try {
    await 取数据({ op: 'move', x, y })
  } catch {
    // 光标窗被关掉了之类的情况，截图那头还是有效的
  }

  // 再截目标周围那一小片，目标永远落在图的正中心。
  // 靠近屏幕边缘时裁剪框会有一部分在屏幕外，那部分由抓屏那边补黑边，
  // 图仍然是完整的 544×544。
  // 这里不要为了"不出界"去挪裁剪框：一挪，中心就不是目标了。
  const 边 = 近景边长
  const 图 = await 取数据({
    op: 'look',
    crop: { x: Math.round(x - 边 / 2), y: Math.round(y - 边 / 2), width: 边, height: 边 },
  })
  const 近景 = String(图?.path ?? '')
  if (近景 === '') throw new Error('定位成功了，但没能截出近景图')

  // 把图登记成附件，让 render 能直接把它当图片块交给模型
  const 预览 = await 登记预览(ctx, 近景)
  记下交付时刻()

  return 预览 === undefined ? { image: 近景, ...附加 } : { image: 近景, preview: 预览, ...附加 }
}

/**
 * 取出某个会话事件当前该有的消息内容（已经应用过投影）。
 *
 * 为什么用投影后的：`image/offload` 不会改写原始事件，它只是往会话里追加一条
 * "这些图已卸载"的记录，由投影把它应用到消息上。所以原始事件里的图永远是
 * `offloaded: false`，照它判断会一遍遍重复卸载，直接报 `already offloaded`。
 *
 * 投影只把 image 块换成带 offloaded 标记的同一块，不增不删不改顺序，
 * 所以按它数出来的"第几张图"和官方认的编号是一致的。
 *
 * @param agent 会话所属的 agent。
 * @param 序号 事件序号。
 * @returns 消息对象，事件类型不对或取不到时返回 null。
 */
function 取消息(agent, 序号) {
  const 事件 = agent.session.eventAt(序号)
  if (事件?.type !== 'user/message' && 事件?.type !== 'tool/result') return null
  try {
    const 消息 = agent.session.deriveEventMessage(事件)
    if (消息?.content !== undefined) return 消息
  } catch {
    // 投影算不出来就退回原始结构，至少别把整轮请求拖垮
  }
  if (事件.type === 'user/message') return 事件.data ?? null
  return 事件.data?.message ?? null
}

/**
 * 找出会话里"最新一批带图的事件"的序号。
 *
 * 用途：决定哪些图该留着。留着的是最新那一批——也就是模型这一次要看的那几张；
 * 比它早的图都已经看过了，可以扔掉。
 *
 * @param agent 会话所属的 agent。
 * @returns 最新的含图事件序号；一个都没有时返回 -1。
 */
function 找最新含图事件(agent) {
  const 节点 = agent?.session?.surface?.nodes
  if (!Array.isArray(节点)) return -1

  let 最新 = -1
  for (const 序号 of 节点) {
    const 内容 = 取消息(agent, 序号)?.content
    if (!Array.isArray(内容)) continue
    if (内容.some((块) => 块?.type === 'image' && 块?.offloaded !== true)) 最新 = 序号
  }
  return 最新
}

/**
 * 把比某个序号更早的图全部标记成"已卸载"。
 *
 * 被标记的图不会消失，磁盘上还在，路径也还在；只是之后组装请求时
 * 只发一行占位文字，不再发图片字节。模型要重看，用 read_image 按路径再读一次。
 *
 * @param agent 会话所属的 agent。
 * @param 保留序号 这个序号及之后的图不动。
 * @returns 这次卸掉了几张。
 */
function 卸载较早的图(agent, 保留序号) {
  const 节点 = agent?.session?.surface?.nodes
  if (!Array.isArray(节点)) return 0

  const 目标 = []
  for (const 序号 of 节点) {
    if (序号 >= 保留序号) continue
    // 只动工具结果里的图。
    // 用户自己发进来的图（user/message）一律不动：那可能是他正在讨论的素材，
    // 什么时候不看应该由他说了算，不该被工具顺手清掉。
    const 事件 = agent.session.eventAt(序号)
    if (事件?.type !== 'tool/result') continue
    const 内容 = 取消息(agent, 序号)?.content
    if (!Array.isArray(内容)) continue

    // 注意：index 是"第几张图"（从 0 数，只数图片块），不是它在 content 数组里的位置。
    // 官方的投影是按图片出现次序编号的，传数组下标会直接报 image index N does not exist。
    const 图序号们 = []
    let 第几张 = 0
    内容.forEach((块) => {
      if (块?.type !== 'image') return
      if (块.offloaded !== true) 图序号们.push(第几张)
      第几张 += 1
    })
    if (图序号们.length > 0) 目标.push({ seq: 序号, imageIndexes: 图序号们 })
  }

  if (目标.length === 0) return 0
  agent.session.append('image/offload', { targets: 目标 })
  return 目标.reduce((和, 项) => 和 + 项.imageIndexes.length, 0)
}

/**
 * 登记全部桌面工具。这些都是主对话直接调的，没有中间层。
 *
 * 分工是刻意的：**坐标只在助手进程和视觉模型内部流转，不进对话。**
 * desktop_locate 拿一句人话，自己算出位置、挪光标、裁一张以目标为中心的近景图，
 * 交回给对话的只有那张图。desktop_click 省略坐标时就点光标当前所在的位置。
 * 这样对话里的模型永远不需要算、也不需要核对屏幕坐标。
 *
 * @param ctx 宿主上下文。
 * @returns {void}
 */
/**
 * 把一句人话变成一个屏幕上的点。只在工具内部用，不交给对话。
 *
 * 两条路：UIA 控件树按名字命中（准、快、不花模型），命中不了才让视觉模型看截图。
 * 抽成独立函数是因为 desktop_locate 和 desktop_click(target) 都要用同一套判断，
 * 各复制一份的话迟早改漏一边。
 *
 * @param 目标 要找的东西，一句人话。
 * @param 选项 { 窗口, 区域 }。
 * @returns { x, y, via, name?, role?, candidates? }，x/y 是屏幕物理像素。
 */
async function 找目标(目标, 选项 = {}) {
  // ---- 第一步：UIA 控件树。按名字命中就直接用控件自己的矩形，最准也最快 ----
  try {
    const 窗口 = typeof 选项.窗口 === 'string' && 选项.窗口.trim() !== '' ? 选项.窗口.trim() : undefined
    const 找到 = await 取数据({ op: 'find', text: 目标, window: 窗口, limit: 8 })
    const 匹配 = Array.isArray(找到?.matches) ? 找到.matches : []
    const 最佳 = 匹配[0]
    // 分数太低说明只是字面蹭上的（实测：找"新会话"蹭到名字叫"会话"的整块面板）。
    // 这种宁可退到视觉定位，也不要拿个"差不多对"的坐标去点错东西
    if (最佳 !== undefined && 最佳?.rect && Number(最佳.score) >= 75) {
      return {
        x: Math.round(最佳.rect.x + 最佳.rect.width / 2),
        y: Math.round(最佳.rect.y + 最佳.rect.height / 2),
        via: 'uia',
        name: String(最佳.name ?? ''),
        role: String(最佳.role ?? ''),
        candidates: 匹配.length,
      }
    }
  } catch {
    // UIA 那边读不动（窗口太复杂、权限不够）就往下走视觉，不在这里报错
  }

  // ---- 第二步：视觉定位。UIA 找不到名字的（图标、canvas 里的东西、游戏画面）走这条 ----
  let 区域 = 选项.区域
  if (区域 === undefined || 区域 === null) {
    // 没给范围就默认用当前活动窗口：在一个窗口里找，比在全屏找准得多
    try {
      const 活 = await 取数据({ op: 'active' })
      if (活?.rect && 活.rect.width > 16 && 活.rect.height > 16) 区域 = 活.rect
    } catch {
      // 拿不到活动窗口就还是全屏
    }
  }
  const 请求 = { op: 'look' }
  if (区域 !== undefined && 区域 !== null) {
    // 四个值都落在 0~1 之间就按比例理解，否则当成屏幕像素坐标直接裁剪
    const 四个值 = [区域.x, 区域.y, 区域.width, 区域.height]
    const 全在比例区间 = 四个值.every((值) => Number.isFinite(值) && 值 >= 0 && 值 <= 1)
    if (全在比例区间) {
      const 屏 = await 取数据({ op: 'status' })
      const 屏框 = 屏?.screen ?? { x: 0, y: 0, width: 0, height: 0 }
      请求.crop = {
        x: Math.round(屏框.x + 区域.x * 屏框.width),
        y: Math.round(屏框.y + 区域.y * 屏框.height),
        width: Math.round(区域.width * 屏框.width),
        height: Math.round(区域.height * 屏框.height),
      }
    } else {
      请求.crop = {
        x: Math.round(区域.x),
        y: Math.round(区域.y),
        width: Math.round(区域.width),
        height: Math.round(区域.height),
      }
    }
    if (请求.crop.width < 16 || 请求.crop.height < 16) {
      throw new Error(`region 太小或写错了：算出来只有 ${请求.crop.width}×${请求.crop.height} 像素，至少要 16×16`)
    }
  }

  const 图 = await 取数据(请求)
  const 结果 = await 定位(图.path, 目标)
  if (结果.x === null || 结果.y === null) {
    throw new Error(`UIA 里没有「${目标}」，视觉定位也没给出结果（它说的是：${结果.raw || '空'}）`)
  }

  // 有裁剪记录就按裁剪那块换算；没裁剪就按整个屏幕换算
  let 基准
  if (图.crop) {
    基准 = 图.crop
  } else {
    const 屏 = await 取数据({ op: 'status' })
    基准 = {
      x: 屏?.screen?.x ?? 0,
      y: 屏?.screen?.y ?? 0,
      width: 屏?.screen?.width ?? 图.width,
      height: 屏?.screen?.height ?? 图.height,
    }
  }

  return {
    x: Math.round(基准.x + (结果.x / 1000) * 基准.width),
    y: Math.round(基准.y + (结果.y / 1000) * 基准.height),
    via: 'vision',
  }
}

/**
 * 每个工具描述都以这句开头。放在模块级，原子工具和脚本工具都要用它。
 */
const 前置 =
  '动手前先加载 use-computer 技能：坐标怎么换算、为什么必须先点后打、哪些情况会点错，都写在那里。\n' +
  '用户随时可以连按三次 ESC 急停：看到「已暂停」就立刻停手，不要重试，那个状态只有用户本人能解除。\n'

function 登记原子工具(ctx) {
  // 坐标换算、先点后打、各条实测的坑，全写在 use-computer 技能里。
  // 工具描述只负责把模型指过去，不在这里重复那些内容。

  // ---- 助手的开关：开和关都显式，不许它自己溜掉 ----
  //
  // 原来的设计是"没人用就自己退出"，结果就是调用方说不清它此刻开着还是关着：
  // 看到连不上，分不清是崩了、是关了、还是超时走了。
  // 现在改成常驻，停止这件事只由 desktop_stop 一个人说了算。
  ctx.tools.register({
    name: 'desktop_start',
    description:
      '启动桌面助手进程。已经在跑就直接返回，不会重复启动。\n' +
      '其余所有桌面工具都依赖它：被 desktop_stop 关掉之后再调别的工具会报错，提示你先调这个。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['running', 'started'],
        properties: {
          running: { type: 'boolean' },
          started: { type: 'boolean' },
          pid: { type: 'number' },
        },
      },
      render: (_args, 结果) => [
        {
          type: 'text',
          text: 结果?.started ? '桌面助手已启动。' : '桌面助手本来就在跑，没有重复启动。',
        },
      ],
    },
    async execute() {
      const 结果 = await 启动助手服务()
      const 返回 = { running: true, started: 结果?.刚启动 === true }
      if (Number.isFinite(结果?.进程号)) 返回.pid = 结果.进程号
      return 返回
    },
  })

  ctx.tools.register({
    name: 'desktop_stop',
    description:
      '关掉桌面助手进程，连同屏幕上那个可见的光标一起收掉。\n' +
      '关掉之后其他桌面工具都会报错，也不会自己再拉起来——要恢复必须显式调 desktop_start。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['running'],
        properties: {
          running: { type: 'boolean' },
          wasRunning: { type: 'boolean' },
        },
      },
      render: (_args, 结果) => [
        {
          type: 'text',
          text: 结果?.wasRunning
            ? '桌面助手已关闭。要再用，调 desktop_start。'
            : '桌面助手本来就没在跑，现在保持关闭状态。',
        },
      ],
    },
    async execute() {
      const 结果 = await 关闭助手服务()
      return { running: false, wasRunning: 结果?.关闭前在跑 === true }
    },
  })

  ctx.tools.register({
    name: 原子工具.看,
    description: 前置 + '截一张全屏图，返回图片路径、图片尺寸、屏幕尺寸和坐标换算比例 scale。截图坐标 × scale = 屏幕坐标。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        maxWidth: { type: 'number', description: '截图最大宽度，默认 1280；要看细节可以给 2560' },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['path', 'width', 'height', 'screenWidth', 'screenHeight', 'scale'],
        properties: {
          path: { type: 'string' },
          width: { type: 'number' },
          height: { type: 'number' },
          screenWidth: { type: 'number' },
          screenHeight: { type: 'number' },
          scale: { type: 'number' },
        },
      },
      render: (_args, 结果) => [
        {
          type: 'text',
          text: `截图：${结果?.path}\n图片 ${结果?.width}×${结果?.height}，屏幕 ${结果?.screenWidth}×${结果?.screenHeight}\n换算：屏幕坐标 = 图上坐标 × ${结果?.scale}`,
        },
      ],
    },
    async execute(args) {
      const 请求 = { op: 'look' }
      if (Number.isFinite(args?.maxWidth) && args.maxWidth > 0) 请求.maxWidth = Math.round(args.maxWidth)
      const 图 = await 取数据(请求)
      const 屏 = await 取数据({ op: 'status' })
      const 屏幕宽 = 屏?.screen?.width ?? 图.width
      return {
        path: 图.path,
        width: 图.width,
        height: 图.height,
        screenWidth: 屏幕宽,
        screenHeight: 屏?.screen?.height ?? 图.height,
        scale: 图.width > 0 ? 屏幕宽 / 图.width : 1,
      }
    },
  })

  ctx.tools.register({
    name: 'desktop_motion',
    description:
      前置 +
      '看「刚才这一段时间」屏幕上的变化，而不是此刻的一张快照。\n' +
      '它把最近几秒的若干帧拼成一张联系表，每格左上角标着时刻，所以看得出动画、加载、进度条、视频画面在动。\n' +
      '**什么时候用**：目标在动，或者你要判断「刚才发生了什么」。\n' +
      '**什么时候别用**：只是确认某个按钮在不在、长什么样——那种事 desktop_look 或 desktop_locate 更清楚。\n' +
      '助手每秒记一帧、滚动保留 40 秒，所以取不到 40 秒以前的画面。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        count: { type: 'number', description: '拼几帧，默认 4，可选 2~9' },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['image', 'count', 'span', 'times'],
        properties: {
          image: { type: 'string' },
          count: { type: 'number' },
          span: { type: 'number' },
          times: { type: 'array', items: { type: 'string' } },
          preview: {
            type: 'object',
            additionalProperties: false,
            required: ['attachmentId', 'mediaType', 'bytes', 'width', 'height'],
            properties: {
              attachmentId: { type: 'string' },
              mediaType: { type: 'string' },
              bytes: { type: 'number' },
              width: { type: 'number' },
              height: { type: 'number' },
            },
          },
        },
      },
      render: (_args, 结果) => {
        const 时刻 = Array.isArray(结果?.times) ? 结果.times : []
        const 块 = [
          {
            type: 'text',
            text: `${结果?.count ?? 0} 帧、跨 ${结果?.span ?? 0} 秒：${时刻.join(' → ')}\n每格左上角标着它的时刻，按阅读顺序排。`,
          },
        ]
        const 图 = 图片内容块(结果?.preview)
        if (图 !== undefined) 块.push(图)
        return 块
      },
    },
    async execute(args) {
      const 请求 = { op: 'motion' }
      if (Number.isFinite(args?.count)) 请求.count = Math.round(args.count)
      // 上次交付之后到现在就是一次感知间隔，把起点交给助手，只取这一段。
      // 第一次调用没有起点，让它按缓冲里最长的一段取。
      if (上次交付时刻 > 0) 请求.since = 上次交付时刻
      const 数据 = await 取数据(请求)
      const 路径 = String(数据?.path ?? '')
      if (路径 === '') throw new Error('助手没有返回拼图')
      const 返回 = {
        image: 路径,
        count: Number(数据?.count ?? 0),
        span: Number(数据?.span ?? 0),
        times: Array.isArray(数据?.times) ? 数据.times.map(String) : [],
      }
      const 预览 = await 登记预览(ctx, 路径)
      if (预览 !== undefined) 返回.preview = 预览
      记下交付时刻()
      return 返回
    },
  })

  ctx.tools.register({
    name: 原子工具.找,
    description:
      前置 +
      '把光标挪到屏幕上某个东西上，交回一张它周围的近景图。**不返回坐标**——你不需要坐标，也验证不了坐标；\n' +
      '看图确认正中间是不是你要的那个东西，然后直接调用 desktop_click 点击（不给 x、y，它会点光标现在停的地方）。\n' +
      '内部走两条路：先用 UIA 控件树按名字找（快、准、不花模型），找不到才用视觉模型看截图定位。\n' +
      'target 写要找的东西，描述到形状、位置、颜色特征，别只说概念名："浏览器工具栏里的圆形刷新箭头"比"刷新"准得多。\n' +
      '有名字的控件（保存、确定、关闭、取消）UIA 基本必中；图标、画布、游戏画面走视觉。\n' +
      'window 可选，限定只在标题含这段文字的窗口里找，默认当前活动窗口。\n' +
      'region 只在视觉那条路用，是屏幕物理像素（和 desktop_windows 给的矩形同一套坐标）。\n' +
      '  视觉模型不会说"这里没有"：目标不在你给的 region 里，它照样会挑区域内最像的东西给一个点。\n' +
      '  所以给 region 之前先确认目标真的在里面；不确定就别给，让它自己找窗口。范围给错必定定位错。\n' +
      '返回的 image 是 544×544 的近景，**正中心就是目标**；贴近屏幕边缘时四周是黑边，那是正常的。\n' +
      '典型用法：desktop_locate → read_image 看一眼正中间 → desktop_click。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['target'],
      properties: {
        target: { type: 'string', description: '要找的东西，用一句人话说清楚，例如"浏览器工具栏里的刷新按钮"' },
        window: {
          type: 'string',
          description: '可选：只在标题包含这段文字的窗口里找（UIA 那条路用）。省略就用当前活动窗口',
        },
        region: {
          type: 'object',
          additionalProperties: false,
          required: ['x', 'y', 'width', 'height'],
          properties: {
            x: { type: 'number' },
            y: { type: 'number' },
            width: { type: 'number' },
            height: { type: 'number' },
          },
          description:
            '视觉定位用的大致范围。四个数都在 0~1 之间时按比例理解（相对屏幕），否则按屏幕像素理解。' +
            '从截图里估个大概就行，不用精确——它的作用是排除干扰',
        },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['image', 'via'],
        properties: {
          image: { type: 'string', description: '544×544 近景图的路径，正中心就是目标' },
          preview: {
            type: 'object',
            additionalProperties: false,
            required: ['attachmentId', 'mediaType', 'bytes', 'width', 'height'],
            properties: {
              attachmentId: { type: 'string' },
              mediaType: { type: 'string' },
              bytes: { type: 'number' },
              width: { type: 'number' },
              height: { type: 'number' },
            },
          },
          via: { type: 'string' },
          name: { type: 'string' },
          role: { type: 'string' },
          candidates: { type: 'number' },
        },
      },
      render: (_args, 结果) => {
        const 方式 =
          结果?.via === 'uia'
            ? `UIA 控件树命中「${结果?.name ?? ''}」${结果?.role ? `（${结果.role}）` : ''}，共 ${结果?.candidates ?? 1} 个候选`
            : '视觉模型定位'
        const 块 = [
          {
            type: 'text',
            text: `${方式}，光标已经停在目标上。图的正中间就是它。\n确认对了就直接调 desktop_click 点击（不用给坐标）；不对就换个说法重新定位。\n文件：${结果?.image ?? ''}`,
          },
        ]
        // 图跟着结果一起回来：模型这一轮就看得到，不用再调一次 read_image。
        // 附件取不到时只有文字，路径还在，仍可以手动读图。
        const 图 = 图片内容块(结果?.preview)
        if (图 !== undefined) 块.push(图)
        return 块
      },
    },
    async execute(args) {
      const 目标 = typeof args?.target === 'string' ? args.target.trim() : ''
      if (目标 === '') throw new Error('desktop_locate 需要 target：说清要找什么')

      const 位置 = await 找目标(目标, { 窗口: args?.window, 区域: args?.region })
      const 附加 = { via: 位置.via }
      if (位置.via === 'uia') {
        附加.name = 位置.name
        附加.role = 位置.role
        附加.candidates = 位置.candidates
      }
      // 坐标的旅程到这里就结束了：交给 定位收尾 去挪光标、裁近景图。
      // 不把坐标、也不把模型原文回传给对话——拿到数字的模型会去算、会去核对，
      // 而它没有任何办法验证那个数字，越核对越乱。
      return 定位收尾(ctx, 位置.x, 位置.y, 附加)
    },
  })

  ctx.tools.register({
    name: 原子工具.点,
    description:
      前置 +
      '点击光标现在停的位置——也就是 desktop_locate 刚把它挪过去的地方。常规用法就是：locate → 看图确认 → 直接点，不要传坐标。\n' +
      'x、y 只在你要点的是自己从截图算出来的位置时才传，其余情况都不该用。\n' +
      '默认左键单击；button 可选 left/right/middle，count 可给 2 表示双击。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        x: { type: 'number', description: '可选。不传就点光标当前位置，这是推荐用法' },
        y: { type: 'number', description: '可选。不传就点光标当前位置' },
        button: { type: 'string' },
        count: { type: 'number' },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['ok', 'via'],
        properties: {
          ok: { type: 'boolean' },
          via: { type: 'string' },
          image: { type: 'string', description: '点完之后目标周围的 544×544 近景图路径' },
          preview: {
            type: 'object',
            additionalProperties: false,
            required: ['attachmentId', 'mediaType', 'bytes', 'width', 'height'],
            properties: {
              attachmentId: { type: 'string' },
              mediaType: { type: 'string' },
              bytes: { type: 'number' },
              width: { type: 'number' },
              height: { type: 'number' },
            },
          },
        },
      },
      render: (_args, 结果) => {
        const 块 = [
          {
            type: 'text',
            text: 结果?.ok
              ? `已点击（${结果?.via}），下面是点完之后它周围的图——用它判断这一下有没有点对。`
              : '点击失败',
          },
        ]
        const 图 = 图片内容块(结果?.preview)
        if (图 !== undefined) 块.push(图)
        return 块
      },
    },
    async execute(args) {
      const 请求 = { op: 'click' }
      // 两个都没给就让助手点光标窗当前的位置：
      // 坐标从定位到点击这条路上一次都不用经过对话，也就没有对不上的机会
      if (Number.isFinite(args?.x) && Number.isFinite(args?.y)) {
        请求.x = Math.round(args.x)
        请求.y = Math.round(args.y)
      }
      if (typeof args.button === 'string') 请求.button = args.button
      if (Number.isFinite(args.count)) 请求.count = Math.round(args.count)
      const 数据 = await 取数据(请求)
      const 点x = Number(数据?.x ?? 0)
      const 点y = Number(数据?.y ?? 0)

      // 点完立刻看结果：让这一轮就把"点对了没有"交还回去。
      // 界面反应有一点延迟，等一小会儿再截，否则拍到的还是点击前的样子。
      await new Promise((解决) => setTimeout(解决, 150))
      const 返回 = { ok: true, via: String(数据?.via ?? 'input') }
      try {
        const 收尾 = await 定位收尾(ctx, 点x, 点y, {})
        if (typeof 收尾?.image === 'string') 返回.image = 收尾.image
        if (收尾?.preview !== undefined) 返回.preview = 收尾.preview
      } catch {
        // 图截不到不影响点击本身，只是这一轮看不到结果
      }
      return 返回
    },
  })

  ctx.tools.register({
    name: 原子工具.打,
    description:
      前置 +
      '往当前焦点窗口输入文字，支持中文。\n' +
      '光标挪过去不等于键盘焦点过去了：要打进某个框，先用 desktop_locate 找到它、看图确认、desktop_click 点进去，再调这个工具。\n' +
      '可选 x、y 让它先点那里再打字，但那等于跳过确认，只在很有把握时用。\n' +
      '打完不会自动回车，要回车用 desktop_key 发 enter。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['text'],
      properties: {
        text: { type: 'string' },
        x: { type: 'number' },
        y: { type: 'number' },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['chars'],
        properties: { chars: { type: 'number' }, clicked: { type: 'boolean' } },
      },
      render: (_args, 结果) => [
        { type: 'text', text: `已输入 ${结果?.chars} 个字符${结果?.clicked ? '（先点了一下拿焦点）' : ''}` },
      ],
    },
    async execute(args) {
      const 请求 = { op: 'type', text: String(args.text ?? '') }
      if (Number.isFinite(args.x) && Number.isFinite(args.y)) {
        请求.x = Math.round(args.x)
        请求.y = Math.round(args.y)
      }
      const 数据 = await 取数据(请求)
      return { chars: Number(数据?.chars ?? 0), clicked: 数据?.clicked === true }
    },
  })

  ctx.tools.register({
    name: 原子工具.键,
    description: 前置 + '按一个组合键，如 ctrl+s、enter、alt+f4、tab。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['keys'],
      properties: { keys: { type: 'string' } },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['chord'],
        properties: { chord: { type: 'string' } },
      },
      render: (_args, 结果) => [{ type: 'text', text: `已发送 ${结果?.chord}` }],
    },
    async execute(args) {
      const 数据 = await 取数据({ op: 'key', keys: String(args.keys ?? '') })
      return { chord: String(数据?.chord ?? args.keys) }
    },
  })

  ctx.tools.register({
    name: 原子工具.窗,
    description: 前置 + '列出当前所有顶层窗口的标题、进程号、位置和尺寸。最小化的窗口没有位置。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['windows'],
        properties: {
          windows: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['title', 'pid'],
              properties: {
                title: { type: 'string' },
                pid: { type: 'number' },
                class: { type: 'string' },
                rect: {
                  type: 'object',
                  additionalProperties: false,
                  required: ['x', 'y', 'width', 'height'],
                  properties: {
                    x: { type: 'number' },
                    y: { type: 'number' },
                    width: { type: 'number' },
                    height: { type: 'number' },
                  },
                },
              },
            },
          },
        },
      },
      render: (_args, 结果) => {
        const 列表 = Array.isArray(结果?.windows) ? 结果.windows : []
        const 行 = 列表.map((w, i) => {
          const 框 = w?.rect
          const 位置 = 框 ? `(${框.x},${框.y}) ${框.width}×${框.height}` : '（已最小化，没有位置）'
          return `${i + 1}. ${w?.title ?? ''} · 进程 ${w?.pid ?? '?'} · ${位置}`
        })
        return [{ type: 'text', text: 行.length > 0 ? 行.join('\n') : '没有可见窗口' }]
      },
    },
    async execute() {
      const 数据 = await 取数据({ op: 'windows' })
      const 列表 = Array.isArray(数据?.windows) ? 数据.windows : []
      // 只交出上面 schema 声明过的字段：宿主会按 schema 严格校验返回值，
      // 多一个没声明的字段、或者把 rect 交成 null，都会让整次调用失败
      return {
        windows: 列表.map((窗口) => {
          const 项 = {
            title: String(窗口?.title ?? ''),
            pid: Number.isFinite(窗口?.pid) ? 窗口.pid : 0,
          }
          if (typeof 窗口?.class === 'string' && 窗口.class !== '') 项.class = 窗口.class
          const 框 = 窗口?.rect
          if (
            框 &&
            Number.isFinite(框.x) &&
            Number.isFinite(框.y) &&
            Number.isFinite(框.width) &&
            Number.isFinite(框.height)
          ) {
            项.rect = { x: 框.x, y: 框.y, width: 框.width, height: 框.height }
          }
          return 项
        }),
      }
    },
  })
}

/**
 * 登记全部桌面工具。
 *
 * 没有子代理这一层了：主对话直接拿着这些工具干活。
 * 坐标由 desktop_locate 内部解决——先查 UIA 控件树按名字命中，
 * 找不到才退到视觉模型看截图定位。
 *
 * @param ctx 宿主上下文，携带 tools 服务。
 * @returns {void}
 */
export function apply(ctx) {
  登记原子工具(ctx)

  // 把模型的输出搬进桌面浮窗。
  // agent/assistant-stream 是模型输出的实时流，每帧带 type: 'start' | 'chunk' | 'end'，
  // chunk 里 text-delta 是正文增量、reasoning-delta 是思考过程。
  // 只在浮窗已经亮起来（也就是正在操作桌面）时才往里写，平时不攒内容。
  ctx.on('agent/assistant-stream', (载荷) => {
    const 帧 = 载荷?.frame
    if (!帧 || 帧.type !== 'chunk') return
    const 块 = 帧.chunk
    if (!块) return
    if (块.type === 'text-delta' && typeof 块.text === 'string') {
      面板.追加正文(块.text)
    }
  })

  // 图看完就扔。
  //
  // 一张图一旦进了对话历史，后面每一轮请求都会把它重发一遍。
  // 544×544 大约一千多 token，一轮轮重发下来，光图就能吃掉几万 token，
  // 而模型真正用到它的只有产生之后那一次。
  //
  // 做法是在每次请求组装前，把"最新一批之外"的图全部标记成已卸载。
  // DSH 自带这个机制（image/offload），被标记的图在请求里只投影成
  // 一行带路径的占位文字，字节不再发送；要重看，用 read_image 按路径再读。
  // 文件本身不删，删了就没法重读了。
  ctx.on('agent/pre-step', async (载荷, next) => {
    try {
      const agent = 载荷?.agent
      const 保留 = 找最新含图事件(agent)
      if (保留 >= 0) {
        const 卸掉 = 卸载较早的图(agent, 保留)
        if (卸掉 > 0) {
          try {
            const 日志 = path.join(os.tmpdir(), 'dsh-use-computer', 'offload.log')
            await mkdir(path.dirname(日志), { recursive: true })
            await appendFile(日志, `${new Date().toISOString()} 卸掉 ${卸掉} 张旧图\n`)
          } catch {
            // 日志写不进去不影响功能
          }
        }
      }
    } catch {
      // 卸载失败绝不能挡住这一轮：宁可多发一张图，也不能让对话卡住
    }
    return next()
  })

  // 每一轮开始时清掉上一轮的残留，避免面板上还挂着很久以前的内容
  ctx.on('turn/start', () => {
    面板.重置面板()
  })

  // 插件卸载时把浮窗一起收掉，不在屏幕上留一个孤儿窗口
  ctx.effect(() => {
    return () => {
      面板.关闭面板()
    }
  })

  // 操作语言单独一个函数登记，免得原子工具那一段越来越长
  登记脚本工具(ctx)
}

/**
 * 登记操作语言工具：一次写一段脚本，本地逐条执行。
 *
 * 它和"一个工具做一件事"的原子工具不是一类东西——它是一套指令集，
 * 以后加指令、改语法只动这里。
 *
 * @param ctx 宿主上下文。
 * @returns {void}
 */
function 登记脚本工具(ctx) {
  // ---- 操作语言：一次写一段，本地逐条执行 ----
  //
  // 为什么要它：一个个调工具时，每动一下都要等模型把话说完、再等下一次，
  // 一轮只能做一个动作。把连续动作写成一段脚本交给本地，一口气执行完，
  // 只在"需要人确认"的地方停下来把图交回去——
  // 往返次数从"动作数"降到"确认次数"，这是延迟的大头。
  //
  // 关键取舍：确认这件事不能省。所以「停」是一条指令，由写脚本的人自己决定在哪停。
  // 有把握就不写停，整段跑完；没把握就在动作前停一下，看完图再继续。
  ctx.tools.register({
    name: 'desktop_do',
    description:
      前置 +
      '按一段脚本一次执行多个动作，不要一个一个调工具。一行一条，`#` 开头是注释。\n' +
      '指令：\n' +
      '  找 <描述>        定位一个东西，自动编号 1、2、3…，并截一张它周围的图\n' +
      '  区域 x y 宽 高    限定后面所有「找」「看」的搜索范围（屏幕物理像素），强烈建议先写它\n' +
      '  点 [编号] [双击|右键]   点某个编号的位置；不给编号就点最新找到的那个\n' +
      '  打 <文字>        往当前焦点窗口打字\n' +
      '  键 <组合键>      例如 键 enter、键 ctrl+s\n' +
      '  等 <毫秒>        等界面反应\n' +
      '  看 <描述>        定位并把图截回来（只定位，不点）\n' +
      '  停              执行到这里停下，把这一段的图交回来让你判断\n' +
      '规则：\n' +
      '  - 每条执行完继续下一条，遇到「停」或出错才中断。\n' +
      '  - 需要你先看一眼再动手的地方，就在那条动作前面写一行「停」，在那里停下给你图。\n' +
      '  - 有把握时整段写完，一次跑到底。\n' +
      '  - 「找」产生的图会随结果回来，最多 3 张。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['script'],
      properties: {
        script: { type: 'string', description: '多行脚本，一行一条指令' },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['ran', 'stopped', 'log'],
        properties: {
          ran: { type: 'number' },
          stopped: { type: 'string' },
          log: { type: 'array', items: { type: 'string' } },
          breakAt: { type: 'number' },
          image: { type: 'string' },
          previews: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['attachmentId', 'mediaType', 'bytes', 'width', 'height'],
              properties: {
                attachmentId: { type: 'string' },
                mediaType: { type: 'string' },
                bytes: { type: 'number' },
                width: { type: 'number' },
                height: { type: 'number' },
              },
            },
          },
        },
      },
      render: (_args, 结果) => {
        const 行 = Array.isArray(结果?.log) ? 结果.log : []
        const 结尾 =
          结果?.stopped === 'break'
            ? '\n已按「停」中断，看完图再写下一段。'
            : 结果?.stopped === 'error'
              ? '\n中途出错，后面的指令没执行。'
              : ''
        const 块 = [{ type: 'text', text: (行.length > 0 ? 行.join('\n') : '脚本没执行任何指令') + 结尾 }]
        const 数组 = Array.isArray(结果?.previews) ? 结果.previews : []
        for (const 预览 of 数组) {
          const 图 = 图片内容块(预览)
          if (图 !== undefined) 块.push(图)
        }
        return 块
      },
    },
    async execute(args) {
      const 原文 = typeof args?.script === 'string' ? args.script : ''
      const 行们 = []
      for (const [下标, 原始行] of 原文.split(/\r?\n/).entries()) {
        const 内容 = 原始行.trim()
        if (内容 === '' || 内容.startsWith('#')) continue
        行们.push({ 行号: 下标 + 1, 内容 })
      }
      if (行们.length === 0) throw new Error('脚本是空的：一行一条指令，例如「找 搜索框」')

      // 定位结果按编号存住，坐标只活在这个函数里，绝不写进返回值
      const 目标表 = new Map()
      let 最新编号 = 0
      let 默认区域
      const 日志 = []
      const 图们 = []
      let 停在第 = 0
      let 结局 = 'end'

      for (const { 行号, 内容 } of 行们) {
        const 空格 = 内容.indexOf(' ')
        const 命令 = 空格 === -1 ? 内容 : 内容.slice(0, 空格)
        const 参数 = 空格 === -1 ? '' : 内容.slice(空格 + 1).trim()

        if (命令 === '停') {
          停在第 = 行号
          结局 = 'break'
          日志.push(`第 ${行号} 行 停：中断`)
          break
        }

        try {
          if (命令 === '区域') {
            const 数字 = 参数.split(/\s+/).filter((段) => 段 !== '').map(Number)
            if (数字.length !== 4 || 数字.some((值) => !Number.isFinite(值))) {
              throw new Error('「区域」后面要写四个数：x y 宽 高')
            }
            默认区域 = { x: 数字[0], y: 数字[1], width: 数字[2], height: 数字[3] }
            日志.push(`第 ${行号} 行 区域：${数字[0]},${数字[1]} ${数字[2]}×${数字[3]}`)
          } else if (命令 === '找' || 命令 === '看') {
            if (参数 === '') throw new Error(`「${命令}」后面要写找什么，例如 找 顶部搜索框`)
            最新编号 += 1
            const 位置 = await 找目标(参数, { 区域: 默认区域 })
            目标表.set(最新编号, 位置)
            const 收尾 = await 定位收尾(ctx, 位置.x, 位置.y, {})
            if (图们.length < 3) 图们.push(收尾)
            日志.push(`第 ${行号} 行 ${命令} #${最新编号}「${参数}」：已定位`)
          } else if (命令 === '点') {
            const 片段 = 参数 === '' ? [] : 参数.split(/\s+/)
            let 号 = 最新编号
            let 次数 = 1
            let 按键 = 'left'
            for (const 段 of 片段) {
              if (/^\d+$/.test(段)) 号 = Number(段)
              else if (段 === '双击') 次数 = 2
              else if (段 === '右键') 按键 = 'right'
              else if (段 === '中键') 按键 = 'middle'
              else throw new Error(`「点」不认识这个参数：${段}`)
            }
            const 请求 = { op: 'click', button: 按键, count: 次数 }
            const 位置 = 目标表.get(号)
            if (位置 !== undefined) {
              请求.x = 位置.x
              请求.y = 位置.y
            }
            await 取数据(请求)
            const 说明 = `${次数 === 2 ? '双击' : '点击'}${按键 === 'right' ? '（右键）' : 按键 === 'middle' ? '（中键）' : ''}`
            日志.push(`第 ${行号} 行 点 #${号}：${说明}`)
          } else if (命令 === '打') {
            if (参数 === '') throw new Error('「打」后面要写打什么字')
            await 取数据({ op: 'type', text: 参数 })
            日志.push(`第 ${行号} 行 打「${参数.length > 20 ? `${参数.slice(0, 20)}…` : 参数}」：已输入`)
          } else if (命令 === '键') {
            if (参数 === '') throw new Error('「键」后面要写组合键，例如 键 enter')
            await 取数据({ op: 'key', keys: 参数 })
            日志.push(`第 ${行号} 行 键 ${参数}：已发送`)
          } else if (命令 === '等') {
            const 毫秒 = Number(参数)
            if (!Number.isFinite(毫秒) || 毫秒 < 0) throw new Error('「等」后面要写毫秒数，例如 等 500')
            // 上限 10 秒：等太久多半是写错了，不如报出来让人重写
            await new Promise((解决) => setTimeout(解决, Math.min(毫秒, 10000)))
            日志.push(`第 ${行号} 行 等 ${Math.min(毫秒, 10000)} 毫秒`)
          } else {
            throw new Error(`不认识的指令「${命令}」，支持：找 点 打 键 等 看 停`)
          }
        } catch (错误) {
          结局 = 'error'
          日志.push(`第 ${行号} 行 ${命令}：失败——${错误 instanceof Error ? 错误.message : String(错误)}`)
          break
        }
      }

      const 返回 = { ran: 日志.length, stopped: 结局, log: 日志 }
      if (停在第 > 0) 返回.breakAt = 停在第
      if (图们.length > 0 && typeof 图们[0]?.image === 'string') 返回.image = 图们[0].image
      const 预览们 = 图们.map((图) => 图?.preview).filter((预览) => 预览 !== undefined)
      if (预览们.length > 0) 返回.previews = 预览们
      return 返回
    },
  })
}
export const 调试信息 = { 命令行路径 }
