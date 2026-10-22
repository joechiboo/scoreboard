# 🏀 Scoreboard

籃球計分板：多裝置即時同步，手機鏡頭 + YOLO 自動辨識進球。

| | |
| --- | --- |
| 計分板（手機、平板、電視打開即用） | https://joechiboo.github.io/scoreboard/ |
| 進球偵測 App（Android APK） | [detector-latest](https://github.com/joechiboo/scoreboard/releases/tag/detector-latest) |

## 目前進度

- ✅ **計分板網頁**：點一下／上滑 +1、下滑 −1、撤銷、開新局，所有裝置即時同步
- ✅ **比賽紀錄**：開新局時選隊伍、點隊名改名；當天各隊戰績與每場比分，一鍵分享到 LINE
- ✅ **資料庫**：加分以事件記錄、撤銷不刪資料；自動進球支援籃框、換場對調、斷線重送不重複
- ✅ **進球判定邏輯**：軌跡 + 球框大小比例 + 籃網晃動，含單元測試與影片評估腳本
- ✅ **偵測 App 骨架**：選籃框、框選籃框、模擬進球、離線重送，GitHub Actions 自動編 APK
- ⏳ **等待實拍影片**：驗證 YOLO 準確率後，再把即時推論接進 App（[錄影指南](docs/recording-guide.md)）
- 💡 **之後想做**：個人數據（勝率、得分、籃板）與 MVP，見 [TODO](docs/TODO.md)

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
| [`web/`](web/README.md) | 計分板（Vite，GitHub Pages） | 比分顯示、手動加減分、撤銷、開新局、比賽紀錄與分享 |
| [`app/`](app/README.md) | 辨識端（Flutter，Android） | 只負責鏡頭與辨識，進球寫入 Supabase |
| [`ml/`](ml/README.md) | YOLO 驗證與訓練（Python） | 進球判定邏輯、影片離線評估、匯出 TFLite |
| [`supabase/`](supabase/README.md) | 資料表 schema 與 migration | 事件制記分、RLS、籃框對應隊伍 |

## 功能目標

1. **多裝置共用計分板**：打開網址即進入同一場比賽，任一裝置加分即全部同步（房間代碼列為後期）
2. **自動辨識進球**：手機架在腳架上對準籃框，偵測球穿過籃框即自動加分
3. **雙籃框**：兩支手機各對一個籃框；換場對調在網頁操作，App 自動跟著換
4. **分值**：自動進球預設記 2 分，網頁可改成 3 分或 1 分（罰球），並可撤銷；全自動三分列為後期目標

## 進球判定（摘要）

使用者在 App 畫面上**框選籃框一次**，YOLO 只在籃框周圍的偵測區找球，三道檢查都過才算進球：

1. **軌跡**：球先在框上方，0.7 秒內從框內往下穿出
2. **大小**：穿越時球徑約為框寬的一半，排除從框前或框後掉下的麵包球
3. **籃網晃動**：進球後網子要晃
4. 判定後冷卻 2 秒

詳見 [docs/goal-detection.md](docs/goal-detection.md)。

## 待辦

完整待辦（網頁、個人數據、App、辨識訓練、待決定事項）見 [docs/TODO.md](docs/TODO.md)。

## 文件

| 文件 | 內容 |
| --- | --- |
| [docs/TODO.md](docs/TODO.md) | 待辦清單與待決定事項 |
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
