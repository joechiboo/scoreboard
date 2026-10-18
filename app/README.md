# app/ — 辨識端（Flutter，Android）

手機架在籃框前，用鏡頭 + 裝置端 YOLO（TFLite）偵測進球，判定後寫入 Supabase 的 `score_events`。

- 只負責鏡頭與辨識，不顯示完整計分板（比分看 `web/`）
- 綁定：房間代碼 + 籃框／隊伍，換場時可對調
- 進球判定：軌跡追蹤（籃框上方 → 框內往下穿出），判定後冷卻約 2 秒
- 目標效能：30fps

> 尚未建立程式碼，Phase 2／3 時以 `flutter create --org com.joechiboo .` 建立。
