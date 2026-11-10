// 用藍牙（Web Bluetooth）直接收手錶的比分，不經過網路。
// 手錶是周邊裝置，UUID 和資料格式要和 watch/ 的 BleScoreService.kt 一致。
// 只有 Android 的 Chrome、電腦的 Chrome／Edge 支援；iPad、iPhone 不支援。

const SERVICE = '7b1d0001-5c0a-4e7e-9d3a-6f2c8a41b0e5'
const STATE = '7b1d0002-5c0a-4e7e-9d3a-6f2c8a41b0e5'
const NAMES = '7b1d0003-5c0a-4e7e-9d3a-6f2c8a41b0e5'
const COMMAND = '7b1d0004-5c0a-4e7e-9d3a-6f2c8a41b0e5'

const CONNECT_TIMEOUT_MS = 10_000
const RETRY_MS = [1000, 2000, 3000, 5000]
const HEARTBEAT_MS = 10_000

export const watchSupported = (nav = navigator) => Boolean(nav.bluetooth)

// 狀態 7 bytes：版本、A 分數（2）、B 分數（2）、旗標、隊名版本
export function parseState(view) {
  if (view.byteLength < 7 || view.getUint8(0) !== 1) return null
  const flags = view.getUint8(5)
  return {
    A: view.getUint16(1, true),
    B: view.getUint16(3, true),
    half: Boolean(flags & 1),
    hasGame: Boolean(flags & 2),
    unsynced: Boolean(flags & 4),
    namesRev: view.getUint8(6),
  }
}

export function parseNames(view) {
  const [teamA = '', teamB = ''] = new TextDecoder().decode(view).split('\n')
  return { teamA, teamB }
}

// onState(state)：手錶的比分、模式、隊名；斷線時傳 null
// onStatus('connecting' | 'connected' | 'reconnecting' | 'off')
export function createWatchLink({ onState, onStatus, bluetooth = navigator.bluetooth }) {
  let device = null
  let chars = null
  let names = null
  let namesRev = -1
  let wanted = false // 使用者要連著；斷線時自動重連
  let opening = false
  let heartbeat = null

  // 同一時間只能有一個藍牙操作，全部排隊做
  let chain = Promise.resolve()
  const queue = (fn) => {
    const result = chain.then(fn)
    chain = result.catch(() => {})
    return result
  }

  const timeout = (promise, ms) => Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms)),
  ])

  async function handle(view, link) {
    const state = parseState(view)
    if (!state || link !== chars) return
    if (state.namesRev !== namesRev || !names) {
      names = parseNames(await queue(() => link.names.readValue()))
      namesRev = state.namesRev
    }
    if (link === chars) onState({ ...state, ...names })
  }

  async function open() {
    const server = await timeout(device.gatt.connect(), CONNECT_TIMEOUT_MS)
    const service = await server.getPrimaryService(SERVICE)
    const link = {
      state: await service.getCharacteristic(STATE),
      names: await service.getCharacteristic(NAMES),
      command: await service.getCharacteristic(COMMAND),
    }
    chars = link
    names = null
    link.state.addEventListener('characteristicvaluechanged', (e) => {
      handle(e.target.value, link).catch(drop)
    })
    await queue(() => link.state.startNotifications())
    await handle(await queue(() => link.state.readValue()), link)
    // 定時讀一次：漏掉的通知補得回來，連線其實斷了也會早點發現
    clearInterval(heartbeat)
    heartbeat = setInterval(() => {
      queue(() => timeout(link.state.readValue(), CONNECT_TIMEOUT_MS)).then((v) => handle(v, link)).catch(drop)
    }, HEARTBEAT_MS)
  }

  // 連線有問題就整個斷開，交給 gattserverdisconnected 重連
  function drop(err) {
    console.warn('手錶藍牙', err)
    if (device?.gatt.connected) device.gatt.disconnect()
    else onDisconnected()
  }

  async function keepOpen() {
    if (opening) return
    opening = true
    try {
      for (let attempt = 0; wanted; attempt++) {
        try {
          await open()
          onStatus('connected')
          return
        } catch (err) {
          console.warn('手錶藍牙連線失敗', err)
          device?.gatt.disconnect() // 還在等的連線要求也一併取消
          if (!wanted) return
          onStatus('reconnecting')
          await new Promise((r) => setTimeout(r, RETRY_MS[Math.min(attempt, RETRY_MS.length - 1)]))
        }
      }
    } finally {
      opening = false
    }
  }

  function onDisconnected() {
    clearInterval(heartbeat)
    if (chars) onState(null)
    chars = null
    if (!wanted) return
    onStatus('reconnecting')
    keepOpen()
  }

  function send(bytes) {
    const link = chars
    if (!link) return Promise.reject(new Error('手錶沒連線'))
    return queue(() => link.command.writeValueWithResponse(new Int8Array(bytes)))
  }

  return {
    get connected() {
      return Boolean(chars)
    },
    get active() {
      return wanted
    },

    // 一定要由使用者點按觸發：瀏覽器會跳出裝置清單讓人選手錶
    async pick() {
      const picked = await bluetooth.requestDevice({ filters: [{ services: [SERVICE] }] })
      if (device && device !== picked) {
        device.removeEventListener('gattserverdisconnected', onDisconnected)
        if (device.gatt.connected) device.gatt.disconnect()
        chars = null
      }
      device = picked
      device.addEventListener('gattserverdisconnected', onDisconnected)
      wanted = true
      onStatus('connecting')
      await keepOpen()
    },

    stop() {
      wanted = false
      clearInterval(heartbeat)
      if (device?.gatt.connected) device.gatt.disconnect()
      if (chars) onState(null)
      chars = null
      onStatus('off')
    },

    // 平板上按的加減分交給手錶記，手錶再把新比分傳回來
    score: (team, points) => send([1, team === 'A' ? 0 : 1, points]),

    // 伺服器的資料變了（別的裝置改的），請手錶去拿最新的
    poke: () => send([0]),
  }
}
