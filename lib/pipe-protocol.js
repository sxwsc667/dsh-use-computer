'use strict'

/**
 * 管道协议：一条请求一行 JSON，一条响应一行 JSON。
 *
 * 请求字段：
 *   id    string  调用方自定的编号，响应原样带回，用来配对
 *   op    string  操作名，见下面的「支持的操作」
 *   其余字段随 op 而定：
 *     move   { x: number, y: number, smooth?: boolean }
 *     look   { hideCursor?: boolean, maxWidth?: number,
 *              crop?: { x, y, width, height } }   crop 用屏幕坐标，只截这一块；
 *              响应里会带回实际生效的 crop，用来把裁剪图里的坐标换回屏幕坐标
 *     click  { x: number, y: number, button?: 1|2|3|'left'|'right'|'middle',
 *              count?: number, mode?: 'auto'|'uia'|'post'|'input' }
 *     type   { text: string, x?: number, y?: number }
 *     key    { keys: string, holdMs?: number }   如 'ctrl+s'
 *     scroll { delta: number, x?: number, y?: number }
 *     status / cursor / windows / shutdown 不需要额外字段
 *
 * 响应字段：
 *   id      string   请求带来的编号
 *   ok      boolean  这条操作是否成功
 *   data    any      成功时的结果
 *   error   string   失败时的原因
 *
 * 注意：这里的常量必须和 PowerShell 那边的同名值保持一致，改一边就要改两边。
 */

// 命名管道名。必须和 assistant.ps1 里 -PipeName 的默认值一致
const 管道名 = 'dsh-use-computer'

// 管道在 Windows 上的完整路径
const 管道全路径 = '\\\\.\\pipe\\' + 管道名

// 光标窗标题。必须和 cursor.ps1 的 $窗口标题、assistant.ps1 的 $光标窗标题一致
const 光标窗标题 = 'DSH-USE-COMPUTER-CURSOR'

// 助手支持的操作名。权威定义在 assistant.ps1 的 switch 里，这里只用来提前挡住拼错的操作
const 支持的操作 = ['status', 'cursor', 'move', 'look', 'motion', 'windows', 'active', 'find', 'click', 'type', 'key', 'scroll', 'shutdown']

// 点击可以走的投递路线。auto 是"先试语义、不行再用真实鼠标"
const 点击路线 = ['auto', 'uia', 'post', 'input']

/**
 * 作用：校验一个即将发往助手的请求，把明显错误的调用挡在本地。
 * 输入：请求对象。
 * 输出：{ 通过: boolean, 原因: string }。原因只在没通过时有内容。
 */
function 校验请求(请求) {
    if (请求 === null || typeof 请求 !== 'object' || Array.isArray(请求)) {
        return { 通过: false, 原因: '请求必须是一个对象' }
    }
    if (typeof 请求.op !== 'string' || 请求.op === '') {
        return { 通过: false, 原因: '缺少 op 字段' }
    }
    if (!支持的操作.includes(请求.op)) {
        return { 通过: false, 原因: `不认识的 op：${请求.op}，支持的有 ${支持的操作.join('、')}` }
    }
    if (请求.op === 'move') {
        if (!Number.isFinite(请求.x) || !Number.isFinite(请求.y)) {
            return { 通过: false, 原因: 'move 需要 x 和 y 两个数字' }
        }
    }
    if (请求.op === 'click') {
        // 坐标可以省略：省略就是点光标窗当前所在的位置，
        // 也就是 desktop_locate 刚把它挪过去的那个地方。
        // 只给一半不行，那说明调用方自己没想清楚要传什么。
        const 给了x = 请求.x !== undefined && 请求.x !== null
        const 给了y = 请求.y !== undefined && 请求.y !== null
        if (给了x !== 给了y) {
            return { 通过: false, 原因: 'click 的 x 和 y 要么都给，要么都不给（都不给就是点光标当前位置）' }
        }
        if (给了x && (!Number.isFinite(请求.x) || !Number.isFinite(请求.y))) {
            return { 通过: false, 原因: 'click 的 x 和 y 必须是数字' }
        }
    }
    if (请求.op === 'click' && 请求.mode !== undefined && !点击路线.includes(请求.mode)) {
        return { 通过: false, 原因: `click 的 mode 只能是 ${点击路线.join('、')}` }
    }
    if (请求.op === 'type') {
        if (typeof 请求.text !== 'string' || 请求.text === '') {
            return { 通过: false, 原因: 'type 需要非空的 text' }
        }
    }
    if (请求.op === 'key') {
        if (typeof 请求.keys !== 'string' || 请求.keys === '') {
            return { 通过: false, 原因: 'key 需要非空的 keys，例如 ctrl+s' }
        }
    }
    if (请求.op === 'scroll' && !Number.isFinite(请求.delta)) {
        return { 通过: false, 原因: 'scroll 需要 delta 这个数字' }
    }
    return { 通过: true, 原因: '' }
}

module.exports = {
    管道名,
    管道全路径,
    光标窗标题,
    支持的操作,
    点击路线,
    校验请求,
}
