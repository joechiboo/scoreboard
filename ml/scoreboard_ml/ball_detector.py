"""用 YOLO 在偵測區內找球。預設用 COCO 預訓練模型的 sports ball 類別；
換成自訓模型時，會自動選類別名稱含 ball 的類別（例如 basketball）。"""

import math

import numpy as np

from .geometry import Ball, Box


class YoloBallDetector:
    def __init__(self, model: str = "yolo11n.pt", conf: float = 0.15, imgsz: int = 640, classes: list[int] | None = None):
        from ultralytics import YOLO

        self.model = YOLO(model)
        self.conf = conf
        self.imgsz = imgsz
        if classes is None:
            classes = [i for i, name in self.model.names.items() if "ball" in name.lower()]
            if not classes:
                raise ValueError(f"模型裡找不到 ball 類別，請用 classes 指定：{self.model.names}")
        self.classes = classes

    def detect(self, frame: np.ndarray, roi: Box, prev: Ball | None = None) -> Ball | None:
        h, w = frame.shape[:2]
        x1, y1, x2, y2 = roi.clip(w, h).to_int()
        crop = frame[y1:y2, x1:x2]
        if crop.size == 0:
            return None
        result = self.model.predict(crop, conf=self.conf, imgsz=self.imgsz, classes=self.classes, verbose=False)[0]
        balls = [
            Ball((bx1 + bx2) / 2 + x1, (by1 + by2) / 2 + y1, bx2 - bx1, by2 - by1, float(c))
            for (bx1, by1, bx2, by2), c in zip(result.boxes.xyxy.tolist(), result.boxes.conf.tolist())
        ]
        if not balls:
            return None
        if prev is None:
            return max(balls, key=lambda b: b.conf)
        # 有上一幀時選最近的那顆，避免在兩顆球之間跳來跳去
        return min(balls, key=lambda b: math.hypot(b.cx - prev.cx, b.cy - prev.cy) / max(b.conf, 1e-3))
