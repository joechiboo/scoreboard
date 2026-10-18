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

// 訂閱比分與比賽變化。
// onScore(score)：比分變動（含剛連上／重連時的同步）
// onGameChange(game)：目前比賽被結束或開了新局
// 回傳取消訂閱的函式
export function subscribe(gameId, { onScore, onGameChange }) {
  const refreshScore = async () => onScore(await getScore(gameId))

  const channel = supabase
    .channel(`game:${gameId}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'score_events', filter: `game_id=eq.${gameId}` },
      refreshScore,
    )
    .on('postgres_changes', { event: '*', schema: 'public', table: 'games' }, async () => {
      const game = await getCurrentGame()
      if (game?.id !== gameId) onGameChange(game)
    })
    .subscribe((status) => {
      // 首次連上與斷線重連都重新抓一次，避免漏掉事件
      if (status === 'SUBSCRIBED') refreshScore()
    })

  return () => supabase.removeChannel(channel)
}
