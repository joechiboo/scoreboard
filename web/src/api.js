import { supabase } from './supabase.js'

function unwrap({ data, error }) {
  if (error) throw error
  return data
}

// 目前進行中的比賽（同時只會有一場）
export async function getCurrentGame() {
  return unwrap(
    await supabase.from('games').select('*').eq('status', 'live').maybeSingle(),
  )
}

export async function getScore(gameId) {
  const row = unwrap(
    await supabase.from('game_scores').select('score_a, score_b').eq('game_id', gameId).maybeSingle(),
  )
  return row ?? { score_a: 0, score_b: 0 }
}

// team: 'A' | 'B'，points: -3～3（不含 0）
export async function addScore(gameId, team, points, source = 'manual') {
  return unwrap(
    await supabase.from('score_events').insert({ game_id: gameId, team, points, source }).select().single(),
  )
}

// 撤銷最後一筆，沒有可撤銷的事件時回傳 null
export async function undoLast(gameId) {
  const row = unwrap(await supabase.rpc('undo_last', { p_game_id: gameId }))
  return row?.id ? row : null
}

export async function newGame(teamAName = '主隊', teamBName = '客隊') {
  return unwrap(
    await supabase.rpc('new_game', { p_team_a_name: teamAName, p_team_b_name: teamBName }),
  )
}

// 改目前這場的隊名（其他裝置透過 Realtime 跟著更新）
export async function renameTeams(gameId, teamAName, teamBName) {
  return unwrap(
    await supabase
      .from('games')
      .update({ team_a_name: teamAName, team_b_name: teamBName })
      .eq('id', gameId)
      .select()
      .single(),
  )
}

// 把某場比分改成指定數字：補手動加減分事件，原本的事件不動（每筆限 ±3，差太多就拆成多筆）
export async function setScore(gameId, scoreA, scoreB) {
  const now = await getScore(gameId)
  const rows = []
  for (const [team, diff] of [['A', scoreA - now.score_a], ['B', scoreB - now.score_b]]) {
    for (let left = diff; left !== 0;) {
      const step = Math.max(-3, Math.min(3, left))
      rows.push({ game_id: gameId, team, points: step, source: 'manual' })
      left -= step
    }
  }
  if (rows.length) unwrap(await supabase.from('score_events').insert(rows))
  return rows.length
}

// 刪除一場：把還沒撤銷的加分全部標成撤銷，比分變 0:0，紀錄就不再顯示。
// 資料不刪；回傳這次標記的事件 id，交給 restoreEvents 復原（之前就撤銷的不受影響）
export async function deleteGame(gameId) {
  const rows = unwrap(
    await supabase.from('score_events').update({ undone: true }).eq('game_id', gameId).eq('undone', false).select('id'),
  )
  return rows.map((r) => r.id)
}

export async function restoreEvents(ids) {
  if (!ids.length) return
  unwrap(await supabase.from('score_events').update({ undone: false }).in('id', ids))
}

// 歷史比賽（含比分），舊的在前
export async function listGames(limit = 500) {
  const [games, scores] = await Promise.all([
    supabase
      .from('games')
      .select('id, team_a_name, team_b_name, status, created_at, ended_at')
      .order('created_at', { ascending: false })
      .limit(limit)
      .then(unwrap),
    supabase.from('game_scores').select('game_id, score_a, score_b').then(unwrap),
  ])
  const byId = new Map(scores.map((s) => [s.game_id, s]))
  return games
    .map((g) => ({ ...g, score_a: byId.get(g.id)?.score_a ?? 0, score_b: byId.get(g.id)?.score_b ?? 0 }))
    .reverse()
}

// 訂閱比分與比賽變化。
// onChange()：比分可能變動，需重新抓取（含剛連上／重連時）
// onGameChange(game)：目前比賽被結束或開了新局
// onGameUpdate(game)：同一場比賽的資料變了（例如改隊名）
// onStatus(online)：連線狀態
// 回傳取消訂閱的函式
export function subscribe(gameId, { onChange, onGameChange, onGameUpdate = () => {}, onStatus = () => {} }) {
  const channel = supabase
    .channel(`game:${gameId}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'score_events', filter: `game_id=eq.${gameId}` },
      () => onChange(),
    )
    .on('postgres_changes', { event: '*', schema: 'public', table: 'games' }, async () => {
      const game = await getCurrentGame()
      if (game?.id !== gameId) onGameChange(game)
      else onGameUpdate(game)
    })
    // 伺服器確認開始推送 postgres_changes 後才算連上；
    // 首次連上與斷線重連都重新抓一次，避免漏掉事件
    .on('system', {}, (payload) => {
      if (payload.extension === 'postgres_changes' && payload.status === 'ok') {
        onStatus(true)
        onChange()
      }
    })
    .subscribe((status) => {
      if (status !== 'SUBSCRIBED') onStatus(false)
    })

  return () => supabase.removeChannel(channel)
}
