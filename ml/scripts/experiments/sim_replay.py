"""重播手機規格的模擬：讀快取的找球結果，掃幀率與籃網門檻，算法與 app/lib/services/vision.dart 相同。"""
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, r"D:/Personal/Project/scoreboard/ml")
from scoreboard_ml import Ball, Box, GoalConfig, GoalDetector  # noqa: E402
from scoreboard_ml.labels import load_labels  # noqa: E402

ROOT = Path(r"D:/Personal/Project/scoreboard/ml/datasets/videos")
P = ROOT / (sys.argv[1] if len(sys.argv) > 1 else "proxy1080")
SUFFIX = sys.argv[2] if len(sys.argv) > 2 else "balls"
K = 2 if P.name == "proxy4k" else 1
L = Path(r"D:/Personal/Project/scoreboard/ml/datasets/videos/2026-10-30_half")
RIM = Box(31.5 * K, 129.5 * K, 83 * K, 138 * K)  # 4K 座標 1763,623,1866,640 換到裁切區
NET = Box(RIM.x1, RIM.y2, RIM.x2, RIM.y2 + RIM.width)
G = 51
CLIPS = sorted(p.name.split(".")[0] for p in P.glob(f"*.{SUFFIX}.json"))


def pick(balls, prev):
    if not balls:
        return None
    if prev is None:
        return max(balls, key=lambda b: b.conf)
    return min(balls, key=lambda b: math.hypot(b.cx - prev.cx, b.cy - prev.cy) / max(b.conf, 1e-3))


def motions(clip, step, conf):
    """回傳 [(t, ball, motion)]，每 step 幀取一幀。"""
    raw = json.loads((P / f"{clip}.{SUFFIX}.json").read_text())
    cap = cv2.VideoCapture(str(P / f"{clip}.mp4"))
    out, prev_g, prev_ball, ball, i = [], None, None, None, 0
    x1, y1, x2, y2 = NET.to_int()
    y2 = min(y2, 220 * K)
    sx, sy = G / NET.width, G / NET.height
    while True:
        ok, f = cap.read()
        if not ok or i >= len(raw):
            break
        if i % step == 0:
            balls = [Ball((a + c) / 2, (b + d) / 2, c - a, d - b, s) for a, b, c, d, s in raw[i] if s >= conf]
            ball = pick(balls, ball)
            gray = cv2.cvtColor(f[y1:y2, x1:x2], cv2.COLOR_BGR2GRAY)
            g = cv2.resize(gray, (G, G), interpolation=cv2.INTER_LINEAR).astype(np.float32) / 255
            g = cv2.GaussianBlur(g, (5, 5), 0)
            m = 0.0
            if prev_g is not None:
                mask = np.ones((G, G), bool)
                for b in (ball, prev_ball):
                    if b is None:
                        continue
                    pad = b.diameter * 0.3
                    mask[
                        max(0, int((b.cy - b.h / 2 - pad - NET.y1) * sy)) : max(0, int(math.ceil((b.cy + b.h / 2 + pad - NET.y1) * sy))),
                        max(0, int((b.cx - b.w / 2 - pad - NET.x1) * sx)) : max(0, int(math.ceil((b.cx + b.w / 2 + pad - NET.x1) * sx))),
                    ] = False
                if mask.any():
                    m = float(np.abs(g - prev_g)[mask].mean())
            prev_g, prev_ball = g, ball
            out.append((i / 30, ball, m))
        i += 1
    return out


def score(seq, thr, transit):
    det = GoalDetector(RIM, GoalConfig(net_threshold=thr, max_transit_s=transit))
    return [e.t for t, b, m in seq if (e := det.update(t, b, m))]


def match(preds, labels, tol=1.0):
    unused, ok, missed = list(preds), [], []
    for t in labels:
        best = min(unused, key=lambda p: abs(p - t), default=None)
        if best is not None and abs(best - t) <= tol:
            ok.append(t)
            unused.remove(best)
        else:
            missed.append(t)
    return ok, unused, missed


def main():
    labels = {c: load_labels(L / f"{c}.csv") for c in CLIPS}
    total = sum(len(v) for v in labels.values())
    print("影片", CLIPS, "標記進球", total)
    for step, name in ((1, "30fps"), (2, "15fps")):
        seqs = {c: motions(c, step, 0.05) for c in CLIPS}
        for transit in (1.0,):
            for thr in (0.02, 0.03, 0.04, 0.05, 0.06):
                tp = fp = 0
                detail = []
                for c in CLIPS:
                    ok, extra, missed = match(score(seqs[c], thr, transit), labels[c])
                    tp += len(ok)
                    fp += len(extra)
                    detail.append(f"{c[-6:]}:{len(ok)}/{len(labels[c])}+{len(extra)}")
                print(f"{name} 門檻{thr:<6} 判對{tp:>3} 誤判{fp:>3} 漏判{total - tp:>3}  " + " ".join(detail), flush=True)


if __name__ == "__main__":
    main()
