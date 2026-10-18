import './style.css'
import { getCurrentGame, getScore, addScore, undoLast, newGame, subscribe } from './api.js'

const app = document.querySelector('#app')

app.innerHTML = `
  <main class="board">
    ${['A', 'B'].map((team) => `
      <section class="team team-${team.toLowerCase()}" data-team="${team}">
        <h2 class="name" data-name>—</h2>
        <div class="score" data-score>0</div>
      </section>
    `).join('')}
  </main>
  <footer class="bar">
    <span class="status" data-status title="連線狀態"></span>
    <button data-action="undo">↶ 撤銷</button>
    <button data-action="new">開新局</button>
    <button data-action="help" class="help" aria-label="操作說明">?</button>
  </footer>
  <dialog class="modal" data-help>
    <h2>操作方式</h2>
    <ul>
      <li><b>點一下</b>比分：+1</li>
      <li><b>往上滑</b>：+1</li>
      <li><b>往下滑</b>：−1（最低 0）</li>
      <li><b>撤銷</b>：取消最後一筆加減分</li>
      <li><b>開新局</b>：比分歸零，所有裝置一起切換</li>
      <li>左下角燈號：<span class="dot online"></span>已連線　<span class="dot"></span>未連線</li>
    </ul>
    <form method="dialog"><button>知道了</button></form>
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
  if (!game) {
    toast('目前沒有進行中的比賽')
    return
  }
  $('[data-name]', teamEl('A')).textContent = game.team_a_name
  $('[data-name]', teamEl('B')).textContent = game.team_b_name
  await refresh()
  unsubscribe = subscribe(game.id, {
    onChange: refresh,
    onGameChange: (g) => {
      if (g?.id !== game?.id) toast('已開新局')
      loadGame(g)
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

// 隊伍區塊手勢：點一下或上滑 +1，下滑 −1
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

app.addEventListener('click', async (e) => {
  const btn = e.target.closest('button')
  if (!btn) return

  if (btn.dataset.action === 'undo') {
    run(async () => {
      const undone = await undoLast(game.id)
      toast(undone ? `已撤銷 ${undone.team === 'A' ? game.team_a_name : game.team_b_name} ${undone.points > 0 ? '+' : ''}${undone.points}` : '沒有可撤銷的紀錄')
    })
  } else if (btn.dataset.action === 'help') {
    $('[data-help]').showModal()
  } else if (btn.dataset.action === 'new') {
    if (!confirm('確定要開新局？目前比分會歸零。')) return
    try {
      await loadGame(await newGame(game?.team_a_name, game?.team_b_name))
    } catch (err) {
      console.error(err)
      toast('開新局失敗')
    }
  }
})

// 點 modal 外面關閉
$('[data-help]').addEventListener('click', (e) => {
  if (e.target === e.currentTarget) e.currentTarget.close()
})

loadGame(await getCurrentGame()).catch((err) => {
  console.error(err)
  toast('無法連線到伺服器')
})
