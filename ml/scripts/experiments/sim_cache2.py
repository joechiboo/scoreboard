"""同 sim_cache，但可指定模型輸入尺寸，結果存成 <影片>.<imgsz>.json。用法：sim_cache2.py <imgsz> <影片...>"""
import json, sys
from pathlib import Path
import cv2
from ultralytics import YOLO
m = YOLO(r"D:/Personal/Project/scoreboard/ml/yolo11n.pt")
sz = int(sys.argv[1])
for v in sys.argv[2:]:
    v = Path(v); cap = cv2.VideoCapture(str(v)); out = []
    while True:
        ok, f = cap.read()
        if not ok: break
        r = m.predict(f, conf=0.03, imgsz=sz, classes=[32], verbose=False)[0]
        out.append([[round(a,1),round(b,1),round(c,1),round(d,1),round(s,3)] for (a,b,c,d),s in zip(r.boxes.xyxy.tolist(), r.boxes.conf.tolist())])
    v.with_suffix(f".{sz}.json").write_text(json.dumps(out))
    print(v.name, sz, len(out), sum(bool(x) for x in out), flush=True)
