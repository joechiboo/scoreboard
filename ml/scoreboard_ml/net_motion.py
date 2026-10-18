"""籃網晃動量：籃網區域相鄰兩幀的平均差異（0～1）。前後兩幀球所在的位置都會被遮掉，
避免球從網子前面經過（麵包球）被當成網子在晃。"""

import cv2
import numpy as np

from .geometry import Ball, Box


class NetMotion:
    def __init__(self, region: Box, ball_pad: float = 0.3):
        self.region = region
        self.ball_pad = ball_pad
        self._prev: np.ndarray | None = None
        self._prev_ball: Ball | None = None

    def update(self, frame_bgr: np.ndarray, ball: Ball | None) -> float:
        h, w = frame_bgr.shape[:2]
        x1, y1, x2, y2 = self.region.clip(w, h).to_int()
        if x2 <= x1 or y2 <= y1:
            return 0.0
        gray = cv2.cvtColor(frame_bgr[y1:y2, x1:x2], cv2.COLOR_BGR2GRAY)
        gray = cv2.GaussianBlur(gray, (5, 5), 0)
        prev, self._prev = self._prev, gray
        prev_ball, self._prev_ball = self._prev_ball, ball
        if prev is None or prev.shape != gray.shape:
            return 0.0

        diff = cv2.absdiff(gray, prev).astype(np.float32) / 255.0
        mask = np.ones_like(diff, dtype=bool)
        for b in (ball, prev_ball):
            if b is None:
                continue
            pad = int(b.diameter * self.ball_pad)
            bx1, by1, bx2, by2 = b.box().to_int()
            mask[
                max(0, by1 - pad - y1) : max(0, by2 + pad - y1),
                max(0, bx1 - pad - x1) : max(0, bx2 + pad - x1),
            ] = False
        if not mask.any():
            return 0.0
        return float(diff[mask].mean())
