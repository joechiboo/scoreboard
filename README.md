# 🏀 Scoreboard

籃球計分板：多裝置即時同步，YOLO 自動辨識進球。

## 架構

```
scoreboard/
├── web/        計分板（Vite，部署到 GitHub Pages）
├── app/        辨識端（Flutter，Android）
├── ml/         YOLO 訓練與測試腳本（Python）
└── supabase/   資料表 schema 與 migration
```

| 目錄 | 角色 |
| --- | --- |
| `web/` | 比分顯示、手動加分、改分、撤銷。手機、平板、電視打開網址即可使用 |
| `app/` | 只負責鏡頭與 YOLO 辨識，偵測到進球就寫入 Supabase |
| `ml/` | 模型訓練、離線驗證、匯出 TFLite |
| `supabase/` | 資料表 schema、migration、RLS 政策 |

兩端透過 **Supabase Realtime** 同步：App 寫入進球事件 → Web 即時更新比分。

## 功能目標

1. **多裝置共用計分板**：用房間代碼加入同一場比賽，任一裝置加分即全部同步
2. **自動辨識進球**：手機架在籃框前，偵測球穿過籃框即自動加分
3. **雙籃框**：兩支手機各對一個籃框、各對應一隊，換場時可對調
4. **分值**：自動進球預設記 2 分，Web 端可一鍵改成 3 分或 1 分（罰球），並提供撤銷；全自動三分列為後期目標

## 進球判定邏輯

追蹤球的**軌跡**，不看單張畫面：

1. 球先出現在籃框**上方**
2. 數幀內從籃框框內**往下穿出**，才判定進球
3. 判定後**冷卻約 2 秒**，避免重複計分

模型使用 YOLO11n 或 YOLOv8n 轉 TFLite，在裝置端推論。

## 開發階段

### Phase 1：Web 手動計分板 + Supabase 同步
- [ ] Supabase schema（games、score_events）與 RLS
- [ ] 建立比賽、產生房間代碼
- [ ] 以房間代碼加入比賽
- [ ] 加減分
- [ ] 撤銷
- [ ] Realtime 多裝置同步
- [ ] 部署到 GitHub Pages

### Phase 2：辨識 POC
- [ ] 錄影建立測試素材
- [ ] 在 `ml/` 離線驗證 YOLO 準確率
- [ ] 在 `ml/` 驗證軌跡判定邏輯
- [ ] 匯出 TFLite，App 端確認可達 30fps

### Phase 3：整合
- [ ] App 綁定籃框／隊伍
- [ ] 自動加分寫入 Supabase
- [ ] Web 端一鍵改分（3 分／1 分）與撤銷誤判
- [ ] 換場對調

### Phase 4：進階
- [ ] 全自動三分判定
- [ ] 比賽紀錄與統計

## 開發

```bash
cd web
npm install
npm run dev
```
