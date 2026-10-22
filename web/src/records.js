// 比賽紀錄：依日期分組、統計各隊戰績、產生可貼到 LINE 的文字。
// 全部是純函式，輸入 listGames() 的結果（含 score_a、score_b）。

// 凌晨 5 點前開的局算前一天，打到半夜的場次不會被拆成兩天
const DAY_START_HOUR = 5
const WEEKDAYS = '日一二三四五六'

const pad = (n) => String(n).padStart(2, '0')

function sessionDate(iso) {
  return new Date(new Date(iso).getTime() - DAY_START_HOUR * 3600 * 1000)
}

export function dayKey(iso) {
  const d = sessionDate(iso)
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export function dayLabel(iso) {
  const d = sessionDate(iso)
  return `${d.getMonth() + 1}/${d.getDate()}（${WEEKDAYS[d.getDay()]}）`
}

// 有得分的才算打過；開新局後沒打的 0:0、測試局都排除
export const isPlayed = (g) => g.score_a + g.score_b > 0

export function winnerOf(g) {
  if (g.score_a === g.score_b) return null
  return g.score_a > g.score_b ? 'A' : 'B'
}

// 依日期分組，新的日期在前；每組內依開局時間排序
export function groupByDay(games) {
  const days = new Map()
  for (const g of games.filter(isPlayed)) {
    const key = dayKey(g.created_at)
    if (!days.has(key)) days.set(key, { key, label: dayLabel(g.created_at), games: [] })
    days.get(key).games.push(g)
  }
  for (const day of days.values()) day.games.sort((a, b) => a.created_at.localeCompare(b.created_at))
  return [...days.values()].sort((a, b) => b.key.localeCompare(a.key))
}

// 進行中的那場還沒打完，只列在比分清單，不算進戰績
export const isFinished = (g) => isPlayed(g) && g.status !== 'live'

// 各隊戰績：只算打完的場次；勝場多的在前，同勝場比淨勝分
export function standings(games) {
  const teams = new Map()
  const team = (name) => {
    if (!teams.has(name)) teams.set(name, { name, played: 0, won: 0, lost: 0, tied: 0, pointsFor: 0, pointsAgainst: 0 })
    return teams.get(name)
  }
  for (const g of games.filter(isFinished)) {
    const a = team(g.team_a_name)
    const b = team(g.team_b_name)
    const w = winnerOf(g)
    a.played++; b.played++
    a.pointsFor += g.score_a; a.pointsAgainst += g.score_b
    b.pointsFor += g.score_b; b.pointsAgainst += g.score_a
    if (w === 'A') { a.won++; b.lost++ }
    else if (w === 'B') { b.won++; a.lost++ }
    else { a.tied++; b.tied++ }
  }
  return [...teams.values()].sort(
    (x, y) => y.won - x.won || (y.pointsFor - y.pointsAgainst) - (x.pointsFor - x.pointsAgainst) || x.lost - y.lost,
  )
}

export function recordText(t) {
  return `${t.won}勝${t.lost}敗${t.tied ? `${t.tied}和` : ''}`
}

// 超過這個長度就不顯示分鐘數：多半是最後一場沒按開新局，隔天才結束
const MAX_GAME_MINUTES = 120

// 開局時間「19:32」；打完的場次附上打了幾分鐘
export function gameTime(g) {
  const start = new Date(g.created_at)
  const hhmm = `${pad(start.getHours())}:${pad(start.getMinutes())}`
  if (!g.ended_at) return hhmm
  const minutes = Math.round((new Date(g.ended_at) - start) / 60000)
  return minutes > MAX_GAME_MINUTES ? hhmm : `${hhmm}（${minutes} 分鐘）`
}

// 贏的隊伍放前面，方便一眼看出勝負
export function gameLine(g) {
  const live = g.status === 'live' ? '（進行中）' : ''
  if (winnerOf(g) === 'B') return `${g.team_b_name} ${g.score_b} : ${g.score_a} ${g.team_a_name}${live}`
  return `${g.team_a_name} ${g.score_a} : ${g.score_b} ${g.team_b_name}${live}`
}

// 顯示順序：最新的在上（進行中的那場一定是最新開的），編號仍照開打順序，第 1 場在最下面
export function newestFirst(games) {
  return games.map((g, i) => ({ game: g, no: i + 1 })).reverse()
}

// 貼到 LINE 群組的文字
export function shareText(day) {
  const finished = day.games.filter(isFinished).length
  const live = day.games.length - finished
  const lines = [`🏀 ${day.label} 比賽紀錄`, `共 ${finished} 場${live ? `（另有 1 場進行中）` : ''}`, '', '【戰績】']
  for (const t of standings(day.games)) {
    lines.push(`${t.name}　${recordText(t)}　得 ${t.pointsFor}／失 ${t.pointsAgainst}`)
  }
  lines.push('', '【各場比分】')
  for (const { game, no } of newestFirst(day.games)) lines.push(`${no}. ${gameTime(game)}　${gameLine(game)}`)
  return lines.join('\n')
}
