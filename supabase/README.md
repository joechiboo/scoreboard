# supabase/ — 資料表 schema 與 migration

- `migrations/`：SQL migration（使用 Supabase CLI：`supabase migration new <name>`）
- 主要資料表：`games`（比賽、房間代碼、隊名）、`score_events`（加分事件，撤銷以標記處理）
- Realtime：Web 與 App 都訂閱 `score_events`
- RLS 政策也放在 migration 中

> 尚未建立 schema，Phase 1 開始。
