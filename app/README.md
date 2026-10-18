# app/ — 辨識端（Flutter，Android）

手機架在籃框前，偵測到進球就寫入 Supabase，計分板網頁即時更新。

## 目前功能

- 選這支手機對應 1 號或 2 號籃框，顯示進球會記給哪一隊（換場對調在網頁操作，這裡自動更新）
- 鏡頭畫面上拖曳框選籃框，自動顯示偵測區；設定會記住
- **模擬進球**按鈕：YOLO 接上前先用它代替，記 2 分（`source = 'auto'`），冷卻 2 秒
- 進球先存在手機，送成功才刪除；斷線每 5 秒重試，`client_id` 防止重複計分
- 偵測時螢幕常亮、橫向全螢幕

尚未完成：YOLO（TFLite）即時推論，Phase 2 驗證模型後接上。

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
