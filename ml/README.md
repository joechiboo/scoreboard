# ml/ — YOLO 訓練與測試（Python）

- 資料：Roboflow 籃球／籃框資料集 + 自行錄製影片
- 模型：YOLO11n 或 YOLOv8n（Ultralytics）
- 離線驗證：偵測準確率、軌跡判定邏輯（以錄影回放測試）
- 匯出：TFLite，提供給 `app/` 使用

`*.pt`、`runs/`、`datasets/`、`*.mp4` 已被 `.gitignore` 排除，不進版控。

> 尚未建立程式碼，Phase 2 開始。
