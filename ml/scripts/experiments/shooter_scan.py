"""可行性測試：每顆進球前 5 秒，全畫面找人與球，存成 json 給 shooter_back.py 往回追。"""
import json, sys
from pathlib import Path
import cv2
from ultralytics import YOLO
sys.path.insert(0, r"D:/Personal/Project/scoreboard/ml")
from scoreboard_ml.labels import load_labels
D = Path(r"D:/Personal/Project/scoreboard/ml/datasets/videos/2026-10-30_half")
OUT = Path(sys.argv[1])
m = YOLO(r"D:/Personal/Project/scoreboard/ml/yolo11n.pt")
for csvp in sorted(D.glob("*.csv")):
    cap = cv2.VideoCapture(str(D / (csvp.stem + ".mp4")))
    for tg in load_labels(csvp):
        cap.set(cv2.CAP_PROP_POS_MSEC, max(0, tg - 5) * 1000)
        rows, i = [], 0
        while True:
            ok, f = cap.read()
            if not ok: break
            t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
            if t > tg + 0.5: break
            if i % 2 == 0:
                r = m.predict(f, conf=0.05, imgsz=1920, classes=[0, 32], verbose=False)[0]
                rows.append({"t": round(t, 3), "det": [[int(c), *[round(v) for v in b], round(s, 3)] for b, c, s in zip(r.boxes.xyxy.tolist(), r.boxes.cls.tolist(), r.boxes.conf.tolist())]})
            i += 1
        (OUT / f"{csvp.stem}_{tg:.1f}.json").write_text(json.dumps(rows))
        print(csvp.stem, tg, len(rows), flush=True)
print("SCAN_DONE")
