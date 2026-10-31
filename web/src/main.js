import './style.css'
import {
  getCurrentGame, getScore, getPendingGoals, addScore, assignGoal, dismissGoal, undoLast, newGame, subscribe,
} from './api.js'

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
    <span class="mode" data-mode></span>
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
      <li><b>開新局</b>：比分歸零，所有裝置一起切換；可選全場或半場</li>
      <li><b>全場</b>：自動進球記給該籃框對應的隊伍（2 分）</li>
      <li><b>半場</b>：自動進球會跳出「記給哪一隊？」，點隊名才計分（1 分）</li>
      <li>左下角燈號：<span class="dot online"></span>已連線　<span class="dot"></span>未連線</li>
    </ul>
    <form method="dialog"><button>知道了</button></form>
  </dialog>
  <dialog class="modal" data-new>
    <form data-new-form>
      <h2>開新局</h2>
      <fieldset class="modes">
        <legend>比賽模式</legend>
        <label><input type="radio" id="mode-full" name="mode" value="full" checked> 全場<small>兩個籃框各對應一隊</small></label>
        <label><input type="radio" id="mode-half" name="mode" value="half"> 半場<small>兩隊投同一個籃框</small></label>
      </fieldset>
      <label class="field">A 隊名稱<input id="team-a" name="a" maxlength="12" required></label>
      <label class="field">B 隊名稱<input id="team-b" name="b" maxlength="12" required></label>
      <p class="note">目前比分會歸零，所有裝置一起切換。</p>
      <div class="actions">
        <button type="button" data-new-cancel>取消</button>
        <button type="submit" class="primary">開新局</button>
      </div>
    </form>
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

// 半場模式：顯示最舊一筆待確認的進球
let claims = []

function renderClaims(list) {
  claims = list
  const el = $('[data-claim]')
  el.hidden = list.length === 0
  if (!list.length) return
  $('[data-claim-text]').textContent = `🏀 進球 +${list[0].points}`
  $('[data-claim-more]').textContent = list.length > 1 ? `（還有 ${list.length - 1} 筆）` : ''
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
  if (!game) {
    toast('目前沒有進行中的比賽')
    return
  }
  $('[data-name]', teamEl('A')).textContent = game.team_a_name
  $('[data-name]', teamEl('B')).textContent = game.team_b_name
  $('[data-claim-team="A"]').textContent = game.team_a_name
  $('[data-claim-team="B"]').textContent = game.team_b_name
  $('[data-mode]').textContent = game.mode === 'half' ? '半場' : '全場'
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
    const form = $('[data-new-form]')
    form.elements.mode.value = game?.mode ?? 'full'
    form.elements.a.value = game?.team_a_name ?? '主隊'
    form.elements.b.value = game?.team_b_name ?? '客隊'
    $('[data-new]').showModal()
  } else if (btn.dataset.newCancel !== undefined) {
    $('[data-new]').close()
  } else if (btn.dataset.claimTeam || btn.dataset.claimSkip !== undefined) {
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

$('[data-new-form]').addEventListener('submit', async (e) => {
  e.preventDefault()
  const f = e.currentTarget.elements
  $('[data-new]').close()
  try {
    await loadGame(await newGame(f.a.value.trim(), f.b.value.trim(), f.mode.value))
  } catch (err) {
    console.error(err)
    toast('開新局失敗')
  }
})

// 點 modal 外面關閉
for (const dialog of app.querySelectorAll('dialog')) {
  dialog.addEventListener('click', (e) => {
    if (e.target === e.currentTarget) e.currentTarget.close()
  })
}

loadGame(await getCurrentGame()).catch((err) => {
  console.error(err)
  toast('無法連線到伺服器')
})
