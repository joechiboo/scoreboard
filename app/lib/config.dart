/// Supabase 連線設定。publishable key 本來就是給前端公開使用，資料權限由 RLS 控管；
/// 建置時可用 --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=... 覆蓋。
const supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://fyfmhdoluahjvncmgcaq.supabase.co',
);
const supabaseKey = String.fromEnvironment(
  'SUPABASE_KEY',
  defaultValue: 'sb_publishable_r32ZjBy2q2nbXrMZXSp2XA_7UAR_tVk',
);

/// 自動進球預設分數，Web 端可再改成 3 分或 1 分。
const autoGoalPoints = 2;

/// 判定進球後的冷卻時間，避免同一球重複計分。
const goalCooldown = Duration(seconds: 2);
