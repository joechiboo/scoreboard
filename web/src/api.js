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

// mode：'full' 全場（兩個籃框各對應一隊）／'half' 半場（自動進球需選隊伍）
export async function newGame(teamAName = '主隊', teamBName = '客隊', mode = 'full') {
  const args = { p_team_a_name: teamAName, p_team_b_name: teamBName }
  const res = await supabase.rpc('new_game', { ...args, p_mode: mode })
  // 資料庫尚未套用 game_modes migration 時沒有 p_mode 參數，改用舊版（只有全場）
  if (res.error?.code === 'PGRST202') return unwrap(await supabase.rpc('new_game', args))
  return unwrap(res)
}

// 半場模式下 App 偵測到、還沒選隊伍的進球（舊的在前）
export async function getPendingGoals(gameId) {
  const res = await supabase
    .from('score_events')
    .select('id, points, created_at')
    .eq('game_id', gameId)
    .eq('pending', true)
    .eq('undone', false)
    .order('id')
  // 資料庫尚未套用 game_modes migration 時沒有 pending 欄位，視為沒有待確認的進球
  if (res.error?.code === '42703') return []
  return unwrap(res)
}

// 把待確認的進球記給某隊。只更新仍待確認的那筆，兩台同時按時只有一台生效
export async function assignGoal(id, team) {
  return unwrap(
    await supabase.from('score_events').update({ team, pending: false }).eq('id', id).eq('pending', true).select(),
  )
}

// 待確認的進球判定為不算
export async function dismissGoal(id) {
  return unwrap(
    await supabase.from('score_events').update({ undone: true }).eq('id', id).eq('pending', true).select(),
  )
}

// 訂閱比分與比賽變化。
// onChange()：比分可能變動，需重新抓取（含剛連上／重連時）
// onGameChange(game)：目前比賽被結束或開了新局
// onStatus(online)：連線狀態
// 回傳取消訂閱的函式
export function subscribe(gameId, { onChange, onGameChange, onStatus = () => {} }) {
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
