import './style.css'
import {
  getCurrentGame, getScore, addScore, undoLast, newGame, renameTeams, listGames, subscribe,
} from './api.js'
import {
  groupByDay, standings, recordText, gameLine, gameTime, shareText, dayKey, isPlayed, isFinished,
} from './records.js'

// 開新局時一定有的快選隊名
const DEFAULT_TEAMS = ['A', 'B', 'C', 'D']
// 資料庫的預設隊名，開新局時改用 A、B
const PLACEHOLDER_NAMES = ['主隊', '客隊']

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
  <footer class="bar">
    <span class="status" data-status title="連線狀態"></span>
    <button data-action="undo">↶ 撤銷</button>
    <button data-action="new">開新局</button>
    <button data-action="history">紀錄</button>
    <button data-action="help" class="help" aria-label="操作說明">?</button>
  </footer>
  <dialog class="modal" data-help>
    <h2>操作方式</h2>
    <ul>
      <li><b>點一下</b>比分：+1</li>
      <li><b>往上滑</b>：+1</li>
      <li><b>往下滑</b>：−1（最低 0）</li>
      <li><b>點隊名</b>：改這場的隊名</li>
      <li><b>撤銷</b>：取消最後一筆加減分</li>
      <li><b>開新局</b>：選下一場的兩隊，目前這場存進紀錄</li>
      <li><b>紀錄</b>：當天各隊戰績與每場比分，可分享到 LINE</li>
      <li>左下角燈號：<span class="dot online"></span>已連線　<span class="dot"></span>未連線</li>
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
    <div data-history-body></div>
    <div class="actions">
      <button type="button" data-share-line class="primary">分享到 LINE</button>
      <button type="button" data-copy>複製文字</button>
    </div>
    <div class="actions">
      <button type="button" data-close>關閉</button>
    </div>
  </dialog>
  <div class="toast" data-toast hidden></div>
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

function paint() {
  for (const team of ['A', 'B']) {
    const value = String(server[team] + pending[team])
    const el = $('[data-score]', teamEl(team))
    if (el.textContent !== value) {
      el.textContent = value
      el.classList.remove('bump')
      void el.offsetWidth // 重新觸發動畫
      el.classList.add('bump')
    }
  }
}

function renderNames() {
  $('[data-name]', teamEl('A')).textContent = game?.team_a_name ?? '—'
  $('[data-name]', teamEl('B')).textContent = game?.team_b_name ?? '—'
}

function renderStatus(online) {
  $('[data-status]').classList.toggle('online', online)
}

let toastTimer
function toast(msg) {
  const el = $('[data-toast]')
  el.textContent = msg
  el.hidden = false
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (el.hidden = true), 2000)
}

// 重新抓比分；請求可能亂序回來，較早發出的結果不可蓋掉較新的結果
async function refresh() {
  if (!game) return
  const req = ++reqSeq
  const gameId = game.id
  const score = await getScore(gameId)
  if (req > renderedReq && gameId === game?.id) {
    renderedReq = req
    renderScore(score)
  }
}

async function loadGame(g) {
  if (g && g.id === game?.id) return // 同一個變化可能通知多次
  unsubscribe?.()
  unsubscribe = null
  game = g
  renderNames()
  if (!game) {
    toast('目前沒有進行中的比賽')
    return
  }
  await refresh()
  unsubscribe = subscribe(game.id, {
    onChange: refresh,
    onGameChange: (g) => {
      if (g?.id !== game?.id) toast('已開新局')
      loadGame(g)
    },
    onGameUpdate: (g) => {
      if (g?.id !== game?.id) return
      game = g
      renderNames()
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

// ---------- 計分手勢：點一下或上滑 +1，下滑 −1 ----------

const SWIPE_PX = 40

async function score(team, points) {
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
    else if (dy < -SWIPE_PX || Math.abs(dy) < 10) score(el.dataset.team, 1)
  })
  el.addEventListener('pointercancel', () => (startY = null))
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
  const list = h('ol', { className: 'games' }, day.games.map((g) => h('li', {}, [
    h('span', { className: 'time', textContent: gameTime(g) }),
    gameLine(g),
  ])))
  const hasLive = day.games.some((g) => !isFinished(g))
  const note = hasLive ? h('p', { className: 'hint note', textContent: '進行中的那場要按「開新局」結束後才算進戰績' }) : ''
  body.replaceChildren(...(standings(day.games).length ? [table] : []), list, note)
}

async function openHistory() {
  days = []
  dayIdx = 0
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
  const btn = e.target.closest('button')
  if (!btn) return
  const day = days[dayIdx]
  if (btn.dataset.day) {
    // ‹ 往較早的日期（陣列後面），› 往較新的日期
    dayIdx = Math.min(Math.max(dayIdx - Number(btn.dataset.day), 0), Math.max(days.length - 1, 0))
    renderHistory()
  } else if ('shareLine' in btn.dataset && day) {
    window.open(`https://line.me/R/share?text=${encodeURIComponent(shareText(day))}`, '_blank')
  } else if ('copy' in btn.dataset && day) {
    try {
      await navigator.clipboard.writeText(shareText(day))
      toast('已複製，可以貼到 LINE')
    } catch {
      toast('無法複製')
    }
  }
})

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

loadGame(await getCurrentGame()).catch((err) => {
  console.error(err)
  toast('無法連線到伺服器')
})
