"""把進球前的關鍵幾秒放大排成一張圖，用眼睛確認誰傳、誰投、誰搶籃板。

用法：
  python scripts/highlight_zoom.py clip.mp4 805.6 --range=-3.6,-1.3 --box 1900,650,3400,1500 --out zoom.jpg

--range 相對進球秒數，開頭是負號所以要用等號連接；--box 是 4K 原圖的裁切範圍。
"""

import argparse
from pathlib import Path

import cv2
import numpy as np


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("goal", type=float)
    parser.add_argument("--range", required=True, help="起,迄（相對進球秒數）")
    parser.add_argument("--box", default="500,380,3840,1560", help="裁切範圍 x0,y0,x1,y1")
    parser.add_argument("--step", type=float, default=0.2)
    parser.add_argument("--scale", type=float, default=0.5)
    parser.add_argument("--columns", type=int, default=3)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    start, end = [float(v) for v in args.range.split(",")]
    x0, y0, x1, y1 = [int(v) for v in args.box.split(",")]
    cap = cv2.VideoCapture(str(args.video))
    cap.set(cv2.CAP_PROP_POS_MSEC, max(0, args.goal + start - 0.2) * 1000)
    next_t = args.goal + start
    tiles = []
    while cap.grab():
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if t > args.goal + end:
            break
        if t < next_t:
            continue
        next_t += args.step
        ok, image = cap.retrieve()
        if not ok:
            break
        tile = cv2.resize(image[y0:y1, x0:x1], None, fx=args.scale, fy=args.scale, interpolation=cv2.INTER_AREA)
        cv2.putText(tile, f"{t - args.goal:+.2f}s", (8, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2, cv2.LINE_AA)
        tiles.append(tile)
    cap.release()

    while len(tiles) % args.columns:
        tiles.append(np.zeros_like(tiles[0]))
    rows = [np.hstack(tiles[i:i + args.columns]) for i in range(0, len(tiles), args.columns)]
    cv2.imwrite(str(args.out), np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 85])
    print(args.out)


if __name__ == "__main__":
    main()
