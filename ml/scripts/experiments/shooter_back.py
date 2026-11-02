"""從進球時的籃框往回追球，直到球碰到人：那個人當作出手者候選。輸出統計與檢查用的縮圖。"""
import json, math, sys
from pathlib import Path
import cv2, numpy as np
S = Path(sys.argv[1]); D = Path(r"D:/Personal/Project/scoreboard/ml/datasets/videos/2026-10-30_half")
RX1, RY1, RX2, RY2 = 1763, 623, 1866, 640
tiles, rows, hits = [], [], []
for jf in sorted((S / "shooter").glob("*.json")):
    clip, tg = jf.stem.rsplit("_", 1); tg = float(tg)
    fr = json.loads(jf.read_text())
    balls = [(f["t"], [d for d in f["det"] if d[0] == 32]) for f in fr]
    # 起點：進球時間前後，籃框上方附近的球
    start = None
    for i in range(len(balls) - 1, -1, -1):
        t, bs = balls[i]
        if t > tg + 0.4: continue
        c = [b for b in bs if RX1 - 150 <= (b[1] + b[3]) / 2 <= RX2 + 150 and RY1 - 450 <= (b[2] + b[4]) / 2 < RY1 + 10]
        if c:
            start = (i, max(c, key=lambda b: b[5])); break
    if start is None:
        rows.append((clip, tg, "框上方沒看到球", None)); continue
    i, b = start; tr = [(balls[i][0], (b[1] + b[3]) / 2, (b[2] + b[4]) / 2)]; hit = None; gap_limit = 0.5
    # 往回走：在速度上限內找最近的球；球進到人框內就停
    j = i - 1
    while j >= 0:
        t, bs = balls[j]; pt, px, py = tr[-1]; dt = pt - t
        if dt > gap_limit: break
        best = None; bd = 1e9
        for q in bs:
            x, y = (q[1] + q[3]) / 2, (q[2] + q[4]) / 2
            d = math.hypot(x - px, y - py)
            if d <= 1500 * dt + 40 and d < bd: best, bd = (x, y), d
        if best:
            tr.append((t, *best))
            persons = [d for d in fr[j]["det"] if d[0] == 0 and d[5] > 0.25]
            inside = [p for p in persons if p[1] - 15 <= best[0] <= p[3] + 15 and p[2] - 40 <= best[1] <= p[2] + (p[4] - p[2]) * 0.7]
            if inside and len(tr) >= 4:
                hit = (t, min(inside, key=lambda p: abs((p[1] + p[3]) / 2 - best[0])), best); break
        j -= 1
    fly = tr[0][0] - tr[-1][0]; pts = len(tr)
    if hit is None:
        rows.append((clip, tg, f"追到一半斷掉（追了 {fly:.1f} 秒、{pts} 點）", tr)); continue
    n_people = sum(1 for d in next(f for f in fr if f["t"] == hit[0])["det"] if d[0] == 0 and d[5] > 0.25)
    rows.append((clip, tg, f"找到人（追 {fly:.1f} 秒、{pts} 點，畫面 {n_people} 人）", tr))
    cap = cv2.VideoCapture(str(D / (clip + ".mp4"))); cap.set(cv2.CAP_PROP_POS_MSEC, hit[0] * 1000); ok, f = cap.read()
    p = hit[1]; x1, y1, x2, y2 = p[1:5]
    hits.append({"clip": clip, "goal": tg, "t": hit[0], "box": [x1, y1, x2, y2]})
    cv2.rectangle(f, (x1, y1), (x2, y2), (0, 255, 0), 5); cv2.circle(f, (int(hit[2][0]), int(hit[2][1])), 34, (0, 255, 255), 5)
    for k in range(1, len(tr)): cv2.line(f, (int(tr[k-1][1]), int(tr[k-1][2])), (int(tr[k][1]), int(tr[k][2])), (0, 165, 255), 3)
    th = cv2.resize(f, (640, 360), interpolation=cv2.INTER_AREA)
    cv2.putText(th, f"{clip[-6:]} {tg:.0f}s", (8, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
    tiles.append(th)
for r in rows: print(r[0][-6:], f"{r[1]:7.1f}", r[2])
ok = sum(r[2].startswith("找到") for r in rows); print(f"找到人 {ok}/{len(rows)}")
for k in range(0, len(tiles), 9):
    g = tiles[k:k + 9]; g += [np.zeros_like(tiles[0])] * ((3 - len(g) % 3) % 3)
    cv2.imwrite(str(S / f"shooter_sheet_{k // 9}.jpg"), np.vstack([np.hstack(g[a:a + 3]) for a in range(0, len(g), 3)]))
(S / "hits.json").write_text(json.dumps(hits))
print("sheets", (len(tiles) + 8) // 9)
