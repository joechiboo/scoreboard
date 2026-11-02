# app/ — 辨識端（Flutter，Android）

手機架在籃框前，偵測到進球就寫入 Supabase，計分板網頁即時更新。

## 目前功能

- 全場：選這支手機對應 1 號或 2 號籃框，顯示進球會記給哪一隊（換場對調在網頁操作，這裡自動更新）
- 半場：不用選籃框，進球記 1 分、先待確認，在計分板網頁選隊伍
- 鏡頭畫面上拖曳框選籃框，自動顯示偵測區；設定會記住
- **模擬進球**按鈕：YOLO 接上前先用它代替，全場記 2 分、半場記 1 分（`source = 'auto'`），冷卻 2 秒
- 進球先存在手機，送成功才刪除；斷線每 5 秒重試，`client_id` 防止重複計分
- 偵測時螢幕常亮、橫向全螢幕

偵測用現成 YOLO（`assets/yolo11n_640.tflite`），由 GitHub Actions 的 `export-model.yml` 轉檔；還不夠準，實戰前請先看 `docs/goal-detection.md`。

## 架設步驟

1. 先架好手機：橫拿放上腳架，架高，籃框要完整入鏡且不被擋住，寬度至少佔畫面 1/20。打球時不要碰到腳架
2. 選全場或半場（App 首頁或計分板網頁都能切，所有裝置一起換）。半場只要一支手機，不用選籃框；全場每個籃框各一支手機
3. 按「開始偵測」
4. 照著鐵圈框住籃框（左右貼齊鐵圈，上下只框圈本身），按「完成」。上次的框還在的話，按「重新框選」再框一次
5. 畫面上方出現「找球 fps」就開始偵測了，球經過時會畫黃圈
6. 腳架動到就要重新框選

## 安裝到手機

每次推送 `app/` 的改動，GitHub Actions 會自動編 APK 並更新到 [detector-latest release](https://github.com/joechiboo/scoreboard/releases/tag/detector-latest)。用 Android 手機打開下載 `app-release.apk` 安裝（需允許安裝未知來源 App）。

## 開發

```bash
cd app
flutter pub get
flutter run
flutter test
```

Supabase 連線預設寫在 `lib/config.dart`，可用 `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...` 覆蓋。
