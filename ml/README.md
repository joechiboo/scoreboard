# ml/ — YOLO 進球辨識（Python）

離線驗證進球判定：對錄好的影片跑 YOLO 找球，再用軌跡判斷進球，和人工標記比對準確率。

## 安裝

```bash
cd ml
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## 評估一段影片

```bash
# 第一次：跳出視窗，框住籃框後按 Enter，終端機會印出 --rim 參數
python scripts/eval_video.py clip.mp4

# 之後帶入 --rim，加上人工標記，輸出標註影片方便檢查
python scripts/eval_video.py clip.mp4 --rim 812,402,955,430 --labels clip.csv --out clip_debug.mp4
```

`clip.csv`：每行一顆球「時間,結果,分數」，例如 `1:02.5,進,3`、`0:48,沒進`，格式見[錄影指南](../docs/recording-guide.md#標記格式)。

比較各項檢查的效果：`--no-size`（關閉球框大小比例）、`--no-net`（關閉籃網晃動確認）、`--net-threshold 0.03`。

## 判定邏輯（`scoreboard_ml/goal_detector.py`，詳見 [docs/goal-detection.md](../docs/goal-detection.md)）

1. **軌跡**：球先在框上方，0.7 秒內出現在框下方，且兩點連線穿過框內（球太快、中間幀沒拍到也能判定）
2. **大小**：穿越時球徑 / 框寬 ≈ 0.53（籃球 24cm / 籃框 45cm），排除從框前（看起來大）或框後（看起來小）掉下的麵包球
3. **籃網晃動**：穿越後 0.8 秒內籃網區域要有變化；前後兩幀球所在位置會被遮掉，球從網前經過不算
4. 判定後冷卻 2 秒

YOLO 只在偵測區（由籃框框選框往上 2.5、往下 1.6、左右 0.6 個框寬）裡找球。預設用 COCO 預訓練的 `yolo11n.pt`（sports ball 類別）；換成自訓模型時用 `--model`，會自動選名稱含 ball 的類別。

## 轉成 TFLite（給 app/）

```bash
python scripts/export_tflite.py --model yolo11n.pt --imgsz 320 [--int8]
```

## 測試

```bash
pytest tests
```

`*.pt`、`runs/`、`datasets/`、`*.mp4` 已被 `.gitignore` 排除，不進版控。
