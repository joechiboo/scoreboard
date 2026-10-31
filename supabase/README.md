# supabase/ — 資料表 schema 與 migration

## 套用 migration

```bash
supabase link --project-ref <project-ref>
supabase db push
```

或直接把 `migrations/*.sql` 貼到 Supabase Dashboard 的 SQL Editor 執行。

## Migration 清單

| 檔案 | 內容 |
| --- | --- |
| `20261018000000_init_scoreboard.sql` | Phase 1：比賽、加分事件、比分、開新局、撤銷 |
| `20261018010000_hoops_and_idempotency.sql` | 辨識端準備：`client_id`、籃框、信心度、換場對調 |
| `20261031000000_game_modes.sql` | 比賽模式全場／半場、待確認進球、自動進球分數 |

## Schema

| 物件 | 說明 |
| --- | --- |
| `games` | 比賽。同時只允許一場 `status = 'live'`（partial unique index） |
| `score_events` | 加分事件，只新增不刪除。`points` 為 -3～3（不含 0），`source` 為 `manual`／`auto` |
| `score_events.client_id` | 寫入端產生的 UUID（unique），App 重送時用 `on conflict do nothing` 避免重複計分 |
| `score_events.hoop` | 1／2 號籃框；自動進球必填。App 只傳 `hoop`，`team` 由 trigger 依換場狀態填入 |
| `score_events.confidence` | 辨識信心度 0～1 |
| `games.mode` | `full` 全場／`half` 半場；由 `new_game(a, b, mode)` 設定 |
| `score_events.pending` | 半場的自動進球先待確認（`team` 為空），計分板選隊伍後改為 false；判定不算則設 `undone` |
| `games.sides_swapped` | 換場對調：false 時 1 號籃框 = A 隊、2 號 = B 隊，true 時相反 |
| `game_scores` | view，由未撤銷的事件加總出 `score_a`、`score_b` |
| `new_game(a, b)` | RPC：結束目前 live 比賽並開新局（同一個 transaction） |
| `undo_last(game_id)` | RPC：撤銷該場最後一筆未撤銷事件 |

- Realtime：`games`、`score_events` 已加入 `supabase_realtime` publication
- RLS：Phase 1 無登入，anon 可讀／新增／更新，不可刪除
- migration 會建立第一場 live 比賽
