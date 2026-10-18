# supabase/ — 資料表 schema 與 migration

## 套用 migration

```bash
supabase link --project-ref <project-ref>
supabase db push
```

或直接把 `migrations/*.sql` 貼到 Supabase Dashboard 的 SQL Editor 執行。

## Schema（Phase 1）

| 物件 | 說明 |
| --- | --- |
| `games` | 比賽。同時只允許一場 `status = 'live'`（partial unique index） |
| `score_events` | 加分事件，只新增不刪除。`points` 為 -3～3（不含 0），`source` 為 `manual`／`auto` |
| `game_scores` | view，由未撤銷的事件加總出 `score_a`、`score_b` |
| `new_game(a, b)` | RPC：結束目前 live 比賽並開新局（同一個 transaction） |
| `undo_last(game_id)` | RPC：撤銷該場最後一筆未撤銷事件 |

- Realtime：`games`、`score_events` 已加入 `supabase_realtime` publication
- RLS：Phase 1 無登入，anon 可讀／新增／更新，不可刪除
- migration 會建立第一場 live 比賽
