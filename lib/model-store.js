'use strict'

/**
 * 模型文件在哪、齐不齐、缺了去哪里下。
 *
 * 这个模块只做定位和说明，不下载：模型合计 2.3 GB，下载是用户自己该决定的事，
 * 插件替你偷偷下几十兆既不透明，也会在没网、限速、公司代理的环境里卡住。
 * 所以这里只回答两个问题——文件应该放在哪、按什么核对；下载动作交给人按文档做。
 *
 * 布局（全部落在 DSH 数据目录，源码目录不再放模型）：
 *   <数据目录>/UGround-V1-2B-gguf/UGround-V1-2B.Q4_K_M.gguf
 *   <数据目录>/UGround-V1-2B-gguf/mmproj-UGround-V1-2B.f16.gguf
 *   <数据目录>/llama.cpp/bin/llama-server.exe
 *
 * 数据目录默认是 %USERPROFILE%\.dsh\models\use-computer，可用环境变量 DSH_USE_COMPUTER_HOME 覆盖。
 */

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

// 数据目录。放在 DSH 自己的数据区，是为了让"插件安装副本"可以随时重装而不丢模型
const 数据目录 = process.env.DSH_USE_COMPUTER_HOME || path.join(os.homedir(), '.dsh', 'models', 'use-computer')
const 模型目录 = path.join(数据目录, 'UGround-V1-2B-gguf')
const 推理目录 = path.join(数据目录, 'llama.cpp')
const 服务器路径 = process.env.DSH_GROUNDING_SERVER || path.join(推理目录, 'bin', 'llama-server.exe')

/**
 * 模型清单。大小和 SHA-256 是下载完核对的依据：
 * 传了一半的文件、被代理换成的错误页，都会在核对这一步露出来。
 *
 * 为什么这里没有下载地址：这两个 GGUF 是我们自己从魔搭的原始权重转出来的，
 * 没有官方发布渠道，仓库也不托管（2.2 GB 不适合进 git 或 Release）。
 * 所以这里只给"该叫这个名字、该有多大、该是什么哈希"，来源和转换步骤写在 README 和 DESIGN 第七节。
 */
const 模型清单 = [
    {
        文件名: 'UGround-V1-2B.Q4_K_M.gguf',
        大小: 986046624,
        sha256: '8536bb397371006d06afa5047453e6a8e224d2ace299be68533453f7b3c7a849',
        来源: '魔搭 osunlp/UGround-V1-2B 转成 GGUF 后量化到 Q4_K_M（步骤见 DESIGN 第七节）',
    },
    {
        文件名: 'mmproj-UGround-V1-2B.f16.gguf',
        大小: 1331655712,
        sha256: 'dfcf96e6a1b3b19e89480388f5edc8e49a1ac7bef3533cf17245c5fd92124a54',
        来源: '同一份原始权重单独转出的视觉塔，必须和上面那个权重配套',
    },
]

/**
 * 推理程序从哪里拿。上游把构建号和资产名绑在一起，所以这里写死一个构建号：
 * 它的 "latest" 发布现在只有一个说明文本，拿不到二进制。
 */
const 推理来源 = {
    版本: 'b11838',
    下载地址:
        'https://github.com/ggml-org/llama.cpp/releases/download/b11838/llama-b11838-bin-win-cpu-x64.zip',
    说明: 'llama.cpp 官方 Windows CPU 版预编译包；有显卡想更快，可换 vulkan 版或自己编 CUDA 版，路径指向即可',
}

/**
 * 作用：判断这个文件是不是已经完整——大小对得上才算。
 * 输入：清单里的一项、文件路径。
 * 输出：true 表示可以直接用；false 表示缺或大小不对。
 * 为什么只看大小：2.2 GB 的文件每次算 SHA-256 要十几秒，每次调用都算会把响应拖垮；
 * 完整核对放在用户下载完之后自己做一次（README 里给了命令）。
 */
function 大小完整(项, 文件路径) {
    try {
        return fs.statSync(文件路径).size === 项.大小
    } catch {
        return false
    }
}

/**
 * 作用：列出每个模型文件当前的状态。
 * 输入：无。
 * 输出：[{ 文件名, 路径, 就绪, 已有大小, 期望大小, 下载地址, sha256 }]。
 */
function 模型概况() {
    return 模型清单.map((项) => {
        const 路径 = path.join(模型目录, 项.文件名)
        let 已有大小 = 0
        try {
            已有大小 = fs.statSync(路径).size
        } catch {
            // 不存在就按 0 算
        }
        return {
            文件名: 项.文件名,
            路径,
            就绪: 大小完整(项, 路径),
            已有大小,
            期望大小: 项.大小,
            来源: 项.来源,
            sha256: 项.sha256,
        }
    })
}

/**
 * 作用：一句话判断视觉定位现在能不能跑起来（模型齐 + 推理程序在）。
 * 输入：无。
 * 输出：{ 就绪: boolean, 缺什么: string[] }。
 */
function 视觉能力状况() {
    const 缺什么 = 模型概况()
        .filter((项) => !项.就绪)
        .map((项) => 项.路径)
    if (!fs.existsSync(服务器路径)) 缺什么.push(服务器路径)
    return { 就绪: 缺什么.length === 0, 缺什么 }
}

/**
 * 作用：拼一段"文件该放哪、从哪来"的说明，直接贴进报错或终端。
 * 输入：视觉能力状况（可省略，省略时现算）。
 * 输出：多行中文文本。
 * 为什么写在代码里而不是只写文档：报错是用户真正会看到的地方，
 * 讲一句"看文档"通常等于没说。
 */
function 下载指引(状况) {
    const 缺 = 状况 || 视觉能力状况()
    const 行 = []
    行.push(`模型和推理程序要放在：${数据目录}`)
    行.push('')
    行.push(`1) 两个模型文件放进 ${模型目录}`)
    for (const 项 of 模型清单) {
        行.push(`   ${项.文件名}（${(项.大小 / 1024 / 1024).toFixed(0)} MB，SHA-256 ${项.sha256.slice(0, 16)}…）`)
        行.push(`     来源：${项.来源}`)
    }
    行.push('   这两个文件没有现成下载地址：需要按 DESIGN 第七节从原始权重转出来，或者从别处拿同名字同哈希的文件。')
    行.push('')
    行.push(`2) 推理程序解压到 ${推理目录}，让 ${服务器路径} 存在`)
    行.push(`   ${推理来源.下载地址}`)
    if (缺.缺什么.length > 0) {
        行.push('')
        行.push(`现在缺的是：${缺.缺什么.join('、')}`)
    }
    return 行.join('\n')
}

module.exports = {
    数据目录,
    模型目录,
    推理目录,
    服务器路径,
    模型清单,
    推理来源,
    模型概况,
    视觉能力状况,
    下载指引,
}
