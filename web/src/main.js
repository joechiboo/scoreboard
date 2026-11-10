import { keepScreenOn } from './wake-lock.js'
import { createWatchLink, watchSupported } from './watch-ble.js'
import './style.css'
import {
  getCurrentGame, getScore, addScore, undoLast, newGame, renameTeams, listGames, subscribe,
  setScore, deleteGame, deleteGames, restoreEvents, setGameMode, getPendingGoals, assignGoal, dismissGoal,
} from './api.js'
import {
  groupByDay, standings, recordText, gameLine, gameTime, shareText, dayKey, isPlayed, isFinished, newestFirst,
} from './records.js'

// 開新局時一定有的快選隊名
const DEFAULT_TEAMS = ['A', 'B', 'C', 'D']
// 資料庫的預設隊名，開新局時改用 A、B
const PLACEHOLDER_NAMES = ['主隊', '客隊']
// 點一下加幾分：全場一般進球 2 分；半場鬥牛每球 1 分。上滑 +1、下滑 −1 兩種模式都一樣
const TAP_POINTS = { full: 2, half: 1 }
const MODE_LABEL = { full: '全場', half: '半場' }
// 資料庫還沒加 mode 欄位（舊資料）時一律當全場
const modeOf = (g) => (g?.mode === 'half' ? 'half' : 'full')

const app = document.querySelector('#app')

app.innerHTML = `
  <main class="board">
    ${['A', 'B'].map((team) => `
      <section class="team team-${team.toLowerCase()}" data-team="${team}">
        <h2 class="name" data-name title="點一下改隊名">—</h2>
        <div class="score" data-score>0</div>
      </section>
    `).join('')}
  </main>
  <div class="claim" data-claim hidden>
    <p><b data-claim-text>🏀 進球</b> 記給哪一隊？<small data-claim-more></small></p>
    <div class="claim-buttons">
      <button data-claim-team="A" class="claim-a">—</button>
      <button data-claim-team="B" class="claim-b">—</button>
      <button data-claim-skip>不算</button>
    </div>
  </div>
  <footer class="bar">
    <span class="status" data-status title="連線狀態"></span>
    <button data-action="undo">↶ 撤銷</button>
    <button data-action="new">開新局</button>
    <button data-action="history">紀錄</button>
    <button data-action="mode" data-mode-btn title="切換全場／半場">全場</button>
    <button data-action="watch" data-watch-btn class="watch" aria-label="用藍牙連接手錶" title="用藍牙連接手錶" hidden>⌚</button>
    <button data-action="help" class="help" aria-label="操作說明">?</button>
  </footer>
  <dialog class="modal" data-help>
    <h2>操作方式</h2>
    <ul>
      <li><b>點一下</b>比分：全場 +2、半場 +1</li>
      <li><b>往上滑</b>：+1（例如三分球再補 1 分）</li>
      <li><b>往下滑</b>：−1（最低 0）</li>
      <li><b>全場／半場</b>按鈕：切換這場的模式，所有裝置一起換；開新局會沿用</li>
      <li><b>半場自動進球</b>：上方跳出「記給哪一隊？」，點隊名才計分，看不清楚就按「不算」</li>
      <li><b>點隊名</b>：改這場的隊名</li>
      <li><b>撤銷</b>：取消最後一筆加減分</li>
      <li><b>開新局</b>：選下一場的兩隊，目前這場存進紀錄</li>
      <li><b>紀錄</b>：當天各隊戰績與每場比分，可分享到 LINE</li>
      <li>左下角燈號：<span class="dot online"></span>已連線　<span class="dot"></span>未連線</li>
      <li><b>⌚</b>（Android 平板才有）：用藍牙直接收手錶的比分，球場沒網路也會跳。手錶先打開計分板，再按 ⌚ 選手錶；亮綠色就是連上了</li>
    </ul>
    <form method="dialog"><button>知道了</button></form>
  </dialog>
  <dialog class="modal" data-newgame>
    <form data-newgame-form>
      <h2>開新局</h2>
      <p class="hint" data-newgame-hint></p>
      ${['A', 'B'].map((team) => `
        <label class="field team-${team.toLowerCase()}">
          <span>${team === 'A' ? '左／上' : '右／下'}</span>
          <input name="${team}" maxlength="12" autocomplete="off" required>
        </label>
        <div class="chips" data-chips="${team}"></div>
      `).join('')}
      <div class="actions">
        <button type="button" data-close>取消</button>
        <button type="submit" class="primary">開始</button>
      </div>
    </form>
  </dialog>
  <dialog class="modal records" data-history>
    <header class="day-nav">
      <button type="button" data-day="-1" aria-label="較早">‹</button>
      <h2 data-day-label>紀錄</h2>
      <button type="button" data-day="1" aria-label="較新">›</button>
    </header>
    <div class="records-body" data-history-body></div>
    <p class="undo-bar" data-undo-bar hidden>
      <span data-undo-text></span>
      <button type="button" data-restore>復原</button>
    </p>
    <footer class="records-foot">
      <div class="actions">
        <button type="button" data-share-line class="primary">分享到 LINE</button>
        <button type="button" data-copy>複製文字</button>
      </div>
      <div class="actions">
        <button type="button" data-close>關閉</button>
      </div>
    </footer>
  </dialog>
  <dialog class="modal" data-edit>
    <form data-edit-form>
      <h2 data-edit-title>編輯</h2>
      <p class="hint" data-edit-hint></p>
      ${['A', 'B'].map((team) => `
        <div class="field team-${team.toLowerCase()}">
          <span>${team === 'A' ? '左／上' : '右／下'}</span>
          <input name="name${team}" maxlength="12" autocomplete="off" required aria-label="隊名">
          <input name="score${team}" class="score-input" type="number" inputmode="numeric" min="0" max="200" step="1" required aria-label="比分">
        </div>
      `).join('')}
      <div class="actions">
        <button type="button" data-close>取消</button>
        <button type="submit" class="primary">儲存</button>
      </div>
      <div class="actions">
        <button type="button" class="danger" data-delete>刪除這場</button>
      </div>
    </form>
  </dialog>
  <div class="toast" data-toast popover="manual" hidden></div>
`

const $ = (sel, root = app) => root.querySelector(sel)
const teamEl = (team) => $(`[data-team="${team}"]`)

let game = null
let unsubscribe = null
let reqSeq = 0
let renderedReq = 0

// 畫面比分 = 伺服器比分 + 自己尚未確認的加減分（樂觀更新）
const server = { A: 0, B: 0 }
const pending = { A: 0, B: 0 }

function renderScore({ score_a, score_b }) {
  server.A = score_a
  server.B = score_b
  paint()
}

// 手錶用藍牙傳來的比分、模式、隊名；沒連著是 null。
// 連著時畫面以手錶為準：手錶的操作不用等網路，這裡看到的會比 Supabase 新
let watch = null
const watchGame = () => (watch?.hasGame ? watch : null)
const currentMode = () => (watchGame() ? (watch.half ? 'half' : 'full') : modeOf(game))
const shownScore = (team) => (watchGame() ? watch[team] : server[team] + pending[team])

function paint() {
  for (const team of ['A', 'B']) {
    const value = String(shownScore(team))
    const el = $('[data-score]', teamEl(team))
    if (el.textContent !== value) {
      el.textContent = value
      el.dataset.digits = Math.min(value.length, 3) // 三位數以上縮小字級才放得下
      el.classList.remove('bump')
      void el.offsetWidth // 重新觸發動畫
      el.classList.add('bump')
    }
  }
}

function renderNames() {
  const a = watchGame()?.teamA ?? game?.team_a_name ?? '—'
  const b = watchGame()?.teamB ?? game?.team_b_name ?? '—'
  $('[data-name]', teamEl('A')).textContent = a
  $('[data-name]', teamEl('B')).textContent = b
  $('[data-claim-team="A"]').textContent = a
  $('[data-claim-team="B"]').textContent = b
}

// 半場：App 偵測到的進球先待確認，顯示最舊的一筆讓場邊選隊伍
let claims = []

function renderClaims(list) {
  claims = list
  const el = $('[data-claim]')
  el.hidden = list.length === 0
  if (!list.length) return
  $('[data-claim-text]').textContent = `🏀 進球 +${list[0].points}`
  $('[data-claim-more]').textContent = list.length > 1 ? `（還有 ${list.length - 1} 筆）` : ''
}

function renderMode() {
  const mode = currentMode()
  const btn = $('[data-mode-btn]')
  btn.textContent = MODE_LABEL[mode]
  btn.classList.toggle('half', mode === 'half')
  app.dataset.mode = mode
}

function renderStatus(online) {
  $('[data-status]').classList.toggle('online', online)
}

// 提示用 popover 放進 top layer，開著對話框時才不會被蓋住；不支援 popover 的瀏覽器退回 hidden
const toastEl = $('[data-toast]')
const canPopover = typeof toastEl.showPopover === 'function'
if (canPopover) toastEl.hidden = false

function showToastEl(show) {
  if (!canPopover) return void (toastEl.hidden = !show)
  try {
    if (toastEl.matches(':popover-open')) toastEl.hidePopover()
    if (show) toastEl.showPopover() // 每次重新顯示，才會排在最新打開的對話框上面
  } catch { /* 狀態不對時忽略 */ }
}

let toastTimer
function toast(msg) {
  toastEl.textContent = msg
  showToastEl(true)
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => showToastEl(false), 2000)
}

// 重新抓比分；請求可能亂序回來，較早發出的結果不可蓋掉較新的結果
async function refresh() {
  if (!game) return
  const req = ++reqSeq
  const gameId = game.id
  const [score, pendingGoals] = await Promise.all([getScore(gameId), getPendingGoals(gameId)])
  if (req > renderedReq && gameId === game?.id) {
    renderedReq = req
    renderScore(score)
    renderClaims(pendingGoals)
  }
}

async function loadGame(g) {
  if (g && g.id === game?.id) return // 同一個變化可能通知多次
  unsubscribe?.()
  unsubscribe = null
  game = g
  renderNames()
  renderMode()
  renderClaims([])
  if (!game) {
    toast('目前沒有進行中的比賽')
    return
  }
  await refresh()
  unsubscribe = subscribe(game.id, {
    onChange: () => {
      pokeWatch()
      return refresh()
    },
    onGameChange: (g) => {
      pokeWatch()
      if (g?.id !== game?.id) toast('已開新局')
      loadGame(g)
    },
    onGameUpdate: (g) => {
      pokeWatch()
      if (g?.id !== game?.id) return
      game = g
      renderNames()
      renderMode()
    },
    onStatus: renderStatus,
  })
}

// 操作後立即更新自己畫面，不等 Realtime 回傳
async function run(action) {
  if (!game) return
  try {
    await action()
    await refresh()
  } catch (err) {
    console.error(err)
    toast('操作失敗，請檢查網路')
  }
}

// ---------- 計分手勢：點一下 +2（全場）／+1（半場），上滑 +1，下滑 −1 ----------

const SWIPE_PX = 40

async function score(team, points) {
  // 手錶連著時交給手錶記：它才是比分的正本，沒網路也記得住，記完會把新比分傳回來
  if (watchLink?.connected && watchGame()) {
    if (watch[team] + points < 0) return
    try {
      await watchLink.score(team, points)
    } catch (err) {
      console.error(err)
      toast('手錶沒收到，請再按一次')
    }
    return
  }
  if (!game) return
  if (server[team] + pending[team] + points < 0) return
  pending[team] += points
  paint()
  try {
    await addScore(game.id, team, points)
    await refresh() // 回來時伺服器比分已包含這筆
  } catch (err) {
    console.error(err)
    toast('操作失敗，請檢查網路')
  } finally {
    pending[team] -= points
    paint()
  }
}

for (const el of app.querySelectorAll('[data-team]')) {
  let startY = null
  el.addEventListener('pointerdown', (e) => {
    if (e.target.closest('[data-name]')) return // 點隊名是改名，不加分
    startY = e.clientY
    el.setPointerCapture(e.pointerId)
  })
  el.addEventListener('pointerup', (e) => {
    if (startY === null) return
    const dy = e.clientY - startY
    startY = null
    if (dy > SWIPE_PX) score(el.dataset.team, -1)
    else if (dy < -SWIPE_PX) score(el.dataset.team, 1)
    else if (Math.abs(dy) < 10) score(el.dataset.team, TAP_POINTS[currentMode()])
  })
  el.addEventListener('pointercancel', () => (startY = null))
}

// ---------- 手錶藍牙直連 ----------

const watchBtn = $('[data-watch-btn]')
let watchLink = null
let pokeTimer

if (watchSupported()) {
  watchBtn.hidden = false
  watchLink = createWatchLink({
    onState: (state) => {
      watch = state
      paint()
      renderNames()
      renderMode()
      if (!state) refresh().catch(console.error) // 斷線：退回顯示 Supabase 的比分
    },
    onStatus: (status) => {
      watchBtn.classList.toggle('linked', status === 'connected')
      watchBtn.classList.toggle('linking', status === 'connecting' || status === 'reconnecting')
      if (status === 'connected') toast('手錶已連線')
      else if (status === 'reconnecting') toast('手錶斷線，重新連線中')
    },
  })
}

async function toggleWatch() {
  if (watchLink.connected) {
    if (confirm('中斷手錶的藍牙連線？\n比分會改回從網路同步。')) watchLink.stop()
    return
  }
  // 沒連上、或重連一直不成功時，重新選一次手錶
  try {
    await watchLink.pick()
  } catch (err) {
    console.error(err)
    if (err?.name !== 'NotFoundError') toast('連不上手錶，確認手錶開著計分板') // NotFoundError：自己按了取消
  }
}

// Supabase 那邊有變動（這台或別台改的）：請手錶去拿最新的，不然畫面會停在手錶的舊比分。
// 手錶自己上傳完也會觸發，它那時多抓一次而已
function pokeWatch() {
  if (!watchLink?.connected) return
  clearTimeout(pokeTimer)
  pokeTimer = setTimeout(() => watchLink.poke().catch(console.warn), 300)
}

// ---------- 全場／半場 ----------

async function toggleMode() {
  if (!game) return
  const next = currentMode() === 'full' ? 'half' : 'full'
  try {
    game = await setGameMode(game.id, next)
    renderMode()
    pokeWatch()
    toast(next === 'half' ? '半場：點一下 +1' : '全場：點一下 +2')
  } catch (err) {
    console.error(err)
    // PGRST204：資料庫還沒套用 mode 欄位的 migration
    toast(err?.code === 'PGRST204' ? '資料庫還沒更新，暫時不能切換半場' : '切換失敗，請檢查網路')
  }
}

// ---------- 改隊名 ----------

const cleanName = (s) => (s ?? '').trim().slice(0, 12)

async function rename(team) {
  if (!game) return
  const current = team === 'A' ? game.team_a_name : game.team_b_name
  const other = team === 'A' ? game.team_b_name : game.team_a_name
  const name = cleanName(prompt('隊名', current))
  if (!name || name === current) return
  if (name === other) return toast('兩隊隊名不能一樣')
  try {
    game = await renameTeams(
      game.id,
      team === 'A' ? name : game.team_a_name,
      team === 'B' ? name : game.team_b_name,
    )
    renderNames()
  } catch (err) {
    console.error(err)
    toast('改名失敗，請檢查網路')
  }
}

for (const team of ['A', 'B']) {
  $('[data-name]', teamEl(team)).addEventListener('click', () => rename(team))
}

// ---------- 開新局：選兩隊 ----------

const newDlg = $('[data-newgame]')
const newForm = $('[data-newgame-form]')

const realName = (name) => (name && !PLACEHOLDER_NAMES.includes(name) ? name : null)

// 快選：A～D，加上今天出現過的隊名
async function todaysTeams() {
  const today = dayKey(new Date().toISOString())
  let names = []
  try {
    names = (await listGames(100))
      .filter((g) => isPlayed(g) && dayKey(g.created_at) === today)
      .flatMap((g) => [g.team_a_name, g.team_b_name])
  } catch (err) {
    console.error(err)
  }
  return [...new Set([...DEFAULT_TEAMS, ...names, game?.team_a_name, game?.team_b_name].map(realName).filter(Boolean))]
}

function renderChips(names) {
  for (const team of ['A', 'B']) {
    const box = $(`[data-chips="${team}"]`, newDlg)
    box.replaceChildren(...names.map((name) => {
      const chip = document.createElement('button')
      chip.type = 'button'
      chip.className = 'chip'
      chip.textContent = name
      chip.addEventListener('click', () => (newForm.elements[team].value = name))
      return chip
    }))
  }
}

async function openNewGame() {
  newForm.elements.A.value = realName(game?.team_a_name) ?? DEFAULT_TEAMS[0]
  newForm.elements.B.value = realName(game?.team_b_name) ?? DEFAULT_TEAMS[1]
  const played = game && server.A + server.B > 0
  $('[data-newgame-hint]', newDlg).textContent = played
    ? `目前這場 ${game.team_a_name} ${server.A} : ${server.B} ${game.team_b_name} 會存進紀錄`
    : '比分從 0 開始'
  renderChips(DEFAULT_TEAMS)
  newDlg.showModal()
  renderChips(await todaysTeams())
}

newForm.addEventListener('submit', async (e) => {
  e.preventDefault()
  const a = cleanName(newForm.elements.A.value)
  const b = cleanName(newForm.elements.B.value)
  if (!a || !b) return
  if (a === b) return toast('兩隊隊名不能一樣')
  newDlg.close()
  try {
    await loadGame(await newGame(a, b))
  } catch (err) {
    console.error(err)
    toast('開新局失敗')
  }
})

// ---------- 紀錄 ----------

const histDlg = $('[data-history]')
let days = []
let dayIdx = 0

function h(tag, props = {}, children = []) {
  const node = Object.assign(document.createElement(tag), props)
  node.append(...children)
  return node
}

function renderHistory() {
  const body = $('[data-history-body]', histDlg)
  const day = days[dayIdx]
  $('[data-day="1"]', histDlg).disabled = dayIdx <= 0
  $('[data-day="-1"]', histDlg).disabled = dayIdx >= days.length - 1
  $('[data-share-line]', histDlg).disabled = !day
  $('[data-copy]', histDlg).disabled = !day
  if (!day) {
    $('[data-day-label]', histDlg).textContent = '紀錄'
    body.replaceChildren(h('p', { className: 'hint', textContent: '還沒有打過的比賽' }))
    return
  }
  $('[data-day-label]', histDlg).textContent = `${day.label}・${day.games.length} 場`

  const head = h('tr', {}, ['隊伍', '戰績', '得', '失'].map((t) => h('th', { textContent: t })))
  const rows = standings(day.games).map((t) => h('tr', {}, [
    h('td', { textContent: t.name }),
    h('td', { textContent: recordText(t) }),
    h('td', { textContent: t.pointsFor }),
    h('td', { textContent: t.pointsAgainst }),
  ]))
  const table = h('table', { className: 'standings' }, [h('thead', {}, [head]), h('tbody', {}, rows)])
  const list = h('ol', { className: 'games' }, newestFirst(day.games).map(({ game: g, no }) => {
    const li = h('li', { value: no, title: '點一下編輯或刪除' }, [
      h('span', { className: 'time', textContent: gameTime(g) }),
      gameLine(g),
    ])
    li.dataset.gameId = g.id
    li.dataset.no = no
    return li
  }))
  const hasLive = day.games.some((g) => !isFinished(g))
  const notes = [
    hasLive ? '進行中的那場要按「開新局」結束後才算進戰績' : null,
    '點一場可以改隊名、比分或刪除',
  ].filter(Boolean).map((t) => h('p', { className: 'hint note', textContent: t }))
  const delDay = h('button', { type: 'button', className: 'delete-day', textContent: `刪除這一天（${day.games.length} 場）` })
  delDay.dataset.deleteDay = ''
  body.replaceChildren(...(standings(day.games).length ? [table] : []), list, ...notes, delDay)
}

// 重新抓紀錄，盡量停在原本那一天（那天的場次全刪光了就停在相鄰的日期）；preferKey 指定要跳到哪一天
async function reloadHistory(preferKey) {
  const key = preferKey ?? days[dayIdx]?.key
  days = groupByDay(await listGames())
  const idx = days.findIndex((d) => d.key === key)
  dayIdx = idx >= 0 ? idx : Math.min(dayIdx, Math.max(days.length - 1, 0))
  renderHistory()
}

async function openHistory() {
  days = []
  dayIdx = 0
  hideUndo()
  renderHistory()
  $('[data-day-label]', histDlg).textContent = '載入中…'
  histDlg.showModal()
  try {
    days = groupByDay(await listGames())
  } catch (err) {
    console.error(err)
    toast('無法讀取紀錄')
  }
  renderHistory()
}

histDlg.addEventListener('click', async (e) => {
  const li = e.target.closest('[data-game-id]')
  if (li) return openEdit(li.dataset.gameId, li.dataset.no)
  const btn = e.target.closest('button')
  if (!btn) return
  const day = days[dayIdx]
  if ('restore' in btn.dataset) return restoreDeleted()
  if ('deleteDay' in btn.dataset) return deleteDay(day)
  if (btn.dataset.day) {
    // ‹ 往較早的日期（陣列後面），› 往較新的日期
    dayIdx = Math.min(Math.max(dayIdx - Number(btn.dataset.day), 0), Math.max(days.length - 1, 0))
    renderHistory()
  } else if ('shareLine' in btn.dataset && day) {
    // line.me/R/share 只有手機會跳進 LINE App，電腦瀏覽器只會看到「請用手機開啟」，所以電腦改成複製
    if (isMobile()) window.open(`https://line.me/R/share?text=${encodeURIComponent(shareText(day))}`, '_blank')
    else await copyText(shareText(day), '已複製，請貼到 LINE 電腦版')
  } else if ('copy' in btn.dataset && day) {
    await copyText(shareText(day), '已複製，可以貼到 LINE')
  }
})

function isMobile() {
  if (navigator.userAgentData) return navigator.userAgentData.mobile
  // iPadOS 的 UA 會偽裝成 Mac，用觸控點數補判
  return /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) ||
    (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1)
}

async function copyText(text, msg) {
  try {
    await navigator.clipboard.writeText(text)
    toast(msg)
  } catch {
    toast('無法複製')
  }
}

// ---------- 編輯、刪除一場 ----------

const editDlg = $('[data-edit]')
const editForm = $('[data-edit-form]')
let editing = null // 正在編輯的那場
let lastDeleted = null // { ids, label }：最近一次刪除，給「復原」用

function openEdit(gameId, no) {
  const g = days[dayIdx]?.games.find((x) => x.id === gameId)
  if (!g) return
  editing = g
  $('[data-edit-title]', editDlg).textContent = `第 ${no} 場`
  $('[data-edit-hint]', editDlg).textContent =
    `開打 ${gameTime(g)}${g.status === 'live' ? '，還在進行中' : ''}。改比分會補一筆加減分，原本的紀錄不動。`
  editForm.elements.nameA.value = g.team_a_name
  editForm.elements.nameB.value = g.team_b_name
  editForm.elements.scoreA.value = g.score_a
  editForm.elements.scoreB.value = g.score_b
  editDlg.showModal()
}

editForm.addEventListener('submit', async (e) => {
  e.preventDefault()
  const g = editing
  if (!g) return
  const a = cleanName(editForm.elements.nameA.value)
  const b = cleanName(editForm.elements.nameB.value)
  const sa = Number(editForm.elements.scoreA.value)
  const sb = Number(editForm.elements.scoreB.value)
  if (!a || !b) return
  if (a === b) return toast('兩隊隊名不能一樣')
  if (![sa, sb].every((n) => Number.isInteger(n) && n >= 0 && n <= 200)) return toast('比分要是 0～200 的整數')
  if (sa + sb === 0) return toast('比分 0:0 會從紀錄消失，要刪除請按「刪除這場」')
  try {
    if (a !== g.team_a_name || b !== g.team_b_name) await renameTeams(g.id, a, b)
    await setScore(g.id, sa, sb)
    editDlg.close()
    toast('已儲存')
    await reloadHistory()
  } catch (err) {
    console.error(err)
    toast('儲存失敗，請檢查網路')
  }
})

$('[data-delete]', editDlg).addEventListener('click', async () => {
  const g = editing
  if (!g) return
  const label = gameLine(g)
  const warn = g.status === 'live' ? '\n這場還在進行中，刪除後計分板比分會歸零。' : ''
  if (!confirm(`刪除這場？\n${label}${warn}\n\n刪除後可以在紀錄頁按「復原」救回來。`)) return
  try {
    const ids = await deleteGame(g.id)
    editDlg.close()
    lastDeleted = { ids, label, dayKey: days[dayIdx]?.key }
    showUndo(`已刪除：${label}`)
    await reloadHistory()
  } catch (err) {
    console.error(err)
    toast('刪除失敗，請檢查網路')
  }
})

function showUndo(text) {
  $('[data-undo-text]', histDlg).textContent = text
  $('[data-undo-bar]', histDlg).hidden = false
}

function hideUndo() {
  lastDeleted = null
  $('[data-undo-bar]', histDlg).hidden = true
}

async function deleteDay(day) {
  if (!day) return
  const live = day.games.some((g) => g.status === 'live')
  const warn = live ? '\n其中有進行中的場次，刪除後計分板比分會歸零。' : ''
  if (!confirm(`刪除 ${day.label} 全部 ${day.games.length} 場？${warn}\n\n刪除後可以在紀錄頁按「復原」救回來。`)) return
  try {
    const ids = await deleteGames(day.games.map((g) => g.id))
    lastDeleted = { ids, label: `${day.label} 全部 ${day.games.length} 場`, dayKey: day.key }
    showUndo(`已刪除：${lastDeleted.label}`)
    await reloadHistory()
  } catch (err) {
    console.error(err)
    toast('刪除失敗，請檢查網路')
  }
}

async function restoreDeleted() {
  if (!lastDeleted) return
  try {
    const { ids, label, dayKey: restoredDay } = lastDeleted
    await restoreEvents(ids)
    toast(`已復原：${label}`)
    hideUndo()
    await reloadHistory(restoredDay)
  } catch (err) {
    console.error(err)
    toast('復原失敗，請檢查網路')
  }
}

// ---------- 底部按鈕 ----------

app.addEventListener('click', async (e) => {
  const btn = e.target.closest('button')
  if (!btn) return

  if ('close' in btn.dataset) {
    btn.closest('dialog').close()
  } else if (btn.dataset.action === 'undo') {
    run(async () => {
      const undone = await undoLast(game.id)
      toast(undone ? `已撤銷 ${undone.team === 'A' ? game.team_a_name : game.team_b_name} ${undone.points > 0 ? '+' : ''}${undone.points}` : '沒有可撤銷的紀錄')
    })
  } else if (btn.dataset.action === 'help') {
    $('[data-help]').showModal()
  } else if (btn.dataset.action === 'new') {
    openNewGame()
  } else if (btn.dataset.action === 'history') {
    openHistory()
  } else if (btn.dataset.action === 'mode') {
    toggleMode()
  } else if (btn.dataset.action === 'watch') {
    toggleWatch()
  } else if (btn.dataset.claimTeam || 'claimSkip' in btn.dataset) {
    const goal = claims[0]
    if (!goal) return
    const team = btn.dataset.claimTeam
    run(async () => {
      const rows = team ? await assignGoal(goal.id, team) : await dismissGoal(goal.id)
      if (!rows.length) toast('這球已由其他裝置處理')
      else if (team) toast(`${team === 'A' ? game.team_a_name : game.team_b_name} +${goal.points}`)
    })
  }
})

// 點 modal 外面關閉（點到對話框本身的內距不算）
for (const dlg of app.querySelectorAll('dialog')) {
  dlg.addEventListener('click', (e) => {
    if (e.target !== dlg) return
    const r = dlg.getBoundingClientRect()
    const inside = e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom
    if (!inside) dlg.close()
  })
}

keepScreenOn()

loadGame(await getCurrentGame()).catch((err) => {
  console.error(err)
  toast('無法連線到伺服器')
})
