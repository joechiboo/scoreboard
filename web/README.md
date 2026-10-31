# web/ — 計分板（Vite）

網址：https://joechiboo.github.io/scoreboard/

## 操作

- **點一下**或**往上滑**比分：+1
- **往下滑**：−1（最低 0）
- **撤銷**：取消最後一筆加減分（含 App 自動記的分）
- **開新局**：比分歸零，所有裝置一起切換；可設定隊名與模式（全場／半場）
- **半場模式**：App 偵測到進球時跳出「記給哪一隊？」，點隊名才計分，或按「不算」
- 左下角燈號：綠色已連線、紅色未連線；「?」按鈕顯示操作說明

## 開發

```bash
npm install
cp .env.example .env   # 填入 Supabase URL 與 publishable key
npm run dev
```

| 檔案 | 內容 |
| --- | --- |
| `src/api.js` | Supabase 資料存取：目前比賽、比分、加分、撤銷、開新局、Realtime 訂閱 |
| `src/main.js` | 畫面與手勢；樂觀更新、亂序回應保護 |
| `src/style.css` | 版面：橫向左右並排、直立上下排列 |

推送 `web/` 的改動到 `main` 後，GitHub Actions 會自動部署到 GitHub Pages（`.github/workflows/deploy-web.yml`）。
