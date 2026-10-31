# 🏀 Scoreboard

籃球計分板：多裝置即時同步，手機鏡頭 + YOLO 自動辨識進球。

| | |
| --- | --- |
| 計分板（手機、平板、電視打開即用） | https://joechiboo.github.io/scoreboard/ |
| 進球偵測 App（Android APK） | [detector-latest](https://github.com/joechiboo/scoreboard/releases/tag/detector-latest) |

## 目前進度

- ✅ **計分板網頁**：點一下／上滑 +1、下滑 −1、撤銷、開新局（全場／半場），所有裝置即時同步
- ✅ **資料庫**：加分以事件記錄、撤銷不刪資料；自動進球支援籃框、換場對調、斷線重送不重複
- ✅ **進球判定邏輯**：軌跡 + 球框大小比例 + 籃網晃動，含單元測試與影片評估腳本
- ✅ **偵測 App 骨架**：選籃框、框選籃框、模擬進球、離線重送，GitHub Actions 自動編 APK
- ⏳ **等待實拍影片**：驗證 YOLO 準確率後，再把即時推論接進 App（[錄影指南](docs/recording-guide.md)）

## 架構

```
 ┌──────────────┐  自動進球（hoop, +2）  ┌──────────────┐  Realtime  ┌──────────────┐
 │ app/ 手機鏡頭 │ ────────────────────▶ │   Supabase   │ ─────────▶ │ web/ 計分板   │
 │ YOLO 辨識進球 │                       │ games        │ ◀───────── │ 手動加減分     │
 └──────────────┘                       │ score_events │  加分/撤銷  │ 改分、撤銷     │
        ▲                               └──────────────┘            └──────────────┘
        │ 模型（TFLite）
 ┌──────────────┐
 │ ml/ 訓練驗證  │
 └──────────────┘
```

| 目錄 | 角色 | 說明 |
| --- | --- | --- |
| [`web/`](web/README.md) | 計分板（Vite，GitHub Pages） | 比分顯示、手動加減分、撤銷、開新局 |
| [`app/`](app/README.md) | 辨識端（Flutter，Android） | 只負責鏡頭與辨識，進球寫入 Supabase |
| [`ml/`](ml/README.md) | YOLO 驗證與訓練（Python） | 進球判定邏輯、影片離線評估、匯出 TFLite |
| [`supabase/`](supabase/README.md) | 資料表 schema 與 migration | 事件制記分、RLS、籃框對應隊伍 |

## 功能目標

1. **多裝置共用計分板**：打開網址即進入同一場比賽，任一裝置加分即全部同步（房間代碼列為後期）
2. **自動辨識進球**：手機架在腳架上對準籃框，偵測球穿過籃框即自動加分
3. **全場與半場**：開新局時選擇
   - 全場：兩支手機各對一個籃框、各對應一隊；換場對調在網頁操作，App 自動跟著換
   - 半場（3v3）：一支手機對一個籃框；兩隊投同一個籃框，自動進球由計分板點選隊伍
4. **分值**：自動進球全場記 2 分、半場記 1 分（3x3 弧內），網頁可改分與撤銷；全自動三分列為後期目標

## 進球判定（摘要）

使用者在 App 畫面上**框選籃框一次**，YOLO 只在籃框周圍的偵測區找球，三道檢查都過才算進球：

1. **軌跡**：球先在框上方，0.7 秒內從框內往下穿出
2. **大小**：穿越時球徑約為框寬的一半，排除從框前或框後掉下的麵包球
3. **籃網晃動**：進球後網子要晃
4. 判定後冷卻 2 秒

詳見 [docs/goal-detection.md](docs/goal-detection.md)。

## 設備

| | 全場 5v5 | 半場 3v3 |
| --- | --- | --- |
| Android 手機 + 腳架（跑辨識） | 2（各對一個籃框） | 1 |
| 計分板（平板／筆電／電視，開瀏覽器即可） | 1 | 1 |
| 行動電源 | 每支手機 1 個 | 1 |
| 網路 | 所有裝置都要連網，場館訊號差時用一支手機開熱點 | 同左 |

影像辨識在各手機上進行，只把「進球」這筆資料送到 Supabase，不傳影片。

## 開發階段

### Phase 1：Web 手動計分板 + Supabase 同步 ✅
- [x] Supabase schema（games、score_events）與 RLS
- [x] 單一共用比賽（暫不做房間，所有裝置看同一場）
- [x] 開新局／重置比分
- [x] 加減分（點一下／上滑 +1、下滑 −1）
- [x] 撤銷
- [x] Realtime 多裝置同步
- [x] 部署到 GitHub Pages

### Phase 2：辨識 POC
- [x] 進球判定邏輯（軌跡 + 球框大小比例 + 籃網晃動）與單元測試
- [x] 影片離線評估腳本（`ml/scripts/eval_video.py`）
- [ ] 腳架 + 廣角實拍影片（含三分、麵包球、打框彈出），見[錄影指南](docs/recording-guide.md)
- [ ] 用實拍影片驗證 YOLO 準確率，決定是否自行訓練模型
- [ ] 匯出 TFLite，App 端確認可達 30fps

### Phase 3：整合
- [x] 資料表：籃框、client_id、換場狀態
- [x] App 骨架：選籃框、框選籃框、模擬進球、離線重送、自動編 APK
- [x] App 綁定籃框／隊伍
- [x] 比賽模式：全場（籃框對應隊伍）／半場（計分板點選隊伍）
- [x] 自動加分寫入 Supabase
- [ ] App 接上 YOLO 即時推論
- [ ] Web：最近加分紀錄，可改 3 分／1 分、撤銷誤判
- [ ] Web：換場對調、改隊名
- [ ] Web：PIN 碼保護（目前網址公開，任何人可改分）

### Phase 4：進階
- [ ] 房間代碼（多場比賽同時進行）
- [ ] 全自動三分判定（需要拍得到投籃位置的廣角畫面）
- [ ] 比賽紀錄與統計

## 文件

| 文件 | 內容 |
| --- | --- |
| [docs/goal-detection.md](docs/goal-detection.md) | 框選籃框、偵測區、三道進球檢查、麵包球分析、參數 |
| [docs/recording-guide.md](docs/recording-guide.md) | 腳架擺放、錄影規格、要錄的內容、標記格式 |
| [docs/decisions.md](docs/decisions.md) | 設計決策與已知風險 |

## 開發

各目錄的 README 有完整說明。

```bash
# 計分板
cd web && npm install && npm run dev

# 進球判定測試
cd ml && pip install -r requirements.txt && pytest

# 偵測 App
cd app && flutter pub get && flutter run
```

推送到 `main` 後，GitHub Actions 會自動：部署 `web/`、跑 `ml/` 測試、編 `app/` 的 APK。
