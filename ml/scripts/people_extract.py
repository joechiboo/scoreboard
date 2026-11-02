"""從實拍影片抓出所有人、依衣著分群，給 people_label.py 指認誰是誰。

用法：
  python scripts/people_extract.py datasets/videos/2026-10-30_half

輸出到 datasets/people/<場次>/：crops/（人框）、frames/（縮小的整張畫面）、people.json、features.npy。
群數故意抓得比人數多，同一人分到兩群沒關係，指認時選同一個名字就好。
衣著特徵只看分割遮罩內的顏色：沒摳背景時，分群會被樹牆、綠板帶著跑。
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO

ML_ROOT = Path(__file__).resolve().parents[1]
MIN_HEIGHT = 200  # 4K 上的人框高度下限，太小的看不清衣服
CROP_HEIGHT = 300
FRAME_WIDTH = 1600
# 人框由上到下分四段比顏色：上半身、腰腹、大腿、小腿
BANDS = ((0.14, 0.32), (0.32, 0.52), (0.52, 0.72), (0.72, 0.92))


def iou(a, b) -> float:
    x1, y1, x2, y2 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union else 0


def clothing_feature(crop, mask):
    """遮罩內各段的 HSV 直方圖，開根號再正規化後可以直接用內積比相似度。"""
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    h = crop.shape[0]
    parts = []
    for top, bottom in BANDS:
        band = np.zeros(mask.shape, np.uint8)
        band[int(h * top):int(h * bottom)] = mask[int(h * top):int(h * bottom)]
        hist = cv2.calcHist([hsv], [0, 1, 2], band, [12, 4, 4], [0, 180, 0, 256, 0, 256]).flatten()
        parts.append(np.sqrt(hist / (hist.sum() + 1e-6)))
    feature = np.concatenate(parts)
    return feature / (np.linalg.norm(feature) + 1e-6)


def kmeans(X, k: int, seed: int = 0):
    rng = np.random.default_rng(seed)
    centers = [X[rng.integers(len(X))]]
    for _ in range(k - 1):
        d = np.min([((X - c) ** 2).sum(1) for c in centers], axis=0)
        centers.append(X[rng.choice(len(X), p=d / d.sum())])
    centers = np.array(centers)
    for _ in range(50):
        labels = ((X[:, None] - centers[None]) ** 2).sum(2).argmin(1)
        centers = np.array([X[labels == c].mean(0) if (labels == c).any() else centers[c] for c in range(k)])
    return labels


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video_dir", type=Path)
    parser.add_argument("--clusters", type=int, default=16)
    parser.add_argument("--step", type=int, default=6, help="每幾秒取一張")
    parser.add_argument("--model", default=str(ML_ROOT / "yolo11n-seg.pt"))
    parser.add_argument("--out", type=Path, help="預設 datasets/people/<場次>")
    args = parser.parse_args()

    out = args.out or ML_ROOT / "datasets" / "people" / args.video_dir.name
    if (out / "labels.json").exists():
        sys.exit(f"{out / 'labels.json'} 已有指認結果，重新分群會對不上；要重跑請先移走")
    crops_dir, frames_dir, tmp = out / "crops", out / "frames", out / "_tmp"
    crops_dir.mkdir(parents=True, exist_ok=True)
    frames_dir.mkdir(exist_ok=True)

    model = YOLO(args.model)
    records, features = [], []
    for video in sorted(args.video_dir.glob("*.mp4")):
        shutil.rmtree(tmp, ignore_errors=True)
        tmp.mkdir()
        # 只解關鍵幀，4K 才跑得動；序號 × 取樣秒數 ≈ 影片時間
        subprocess.run(
            ["ffmpeg", "-v", "error", "-skip_frame", "nokey", "-i", str(video),
             "-vf", f"fps=1/{args.step}", "-q:v", "3", str(tmp / "%05d.jpg")],
            check=True,
        )
        paths = sorted(tmp.glob("*.jpg"))
        for i, path in enumerate(paths):
            image = cv2.imread(str(path))
            height, width = image.shape[:2]
            result = model.predict(image, imgsz=1920, conf=0.5, classes=[0], verbose=False, retina_masks=True)[0]
            if result.masks is None:
                continue
            masks = result.masks.data.cpu().numpy() > 0.5
            boxes = result.boxes.xyxy.cpu().numpy().astype(int).tolist()
            frame_name = f"{video.stem}_{i:05d}.jpg"
            kept = 0
            for n, box in enumerate(boxes):
                x1, y1, x2, y2 = box
                if y2 - y1 < MIN_HEIGHT or y2 - y1 < x2 - x1:
                    continue
                # 跟別人疊在一起的框衣服會混到，不拿來分群
                if any(iou(box, other) > 0.1 for m, other in enumerate(boxes) if m != n):
                    continue
                crop = image[y1:y2, x1:x2]
                name = f"{video.stem}_{i:05d}_{n}.jpg"
                size = (int(CROP_HEIGHT * crop.shape[1] / crop.shape[0]), CROP_HEIGHT)
                cv2.imwrite(str(crops_dir / name), cv2.resize(crop, size), [cv2.IMWRITE_JPEG_QUALITY, 90])
                features.append(clothing_feature(crop, masks[n][y1:y2, x1:x2].astype(np.uint8)))
                records.append({
                    "crop": name, "frame": frame_name, "video": video.stem, "t": i * args.step,
                    "box": [x1 / width, y1 / height, x2 / width, y2 / height],
                })
                kept += 1
            if kept:
                small = (FRAME_WIDTH, int(height * FRAME_WIDTH / width))
                cv2.imwrite(str(frames_dir / frame_name), cv2.resize(image, small), [cv2.IMWRITE_JPEG_QUALITY, 80])
        print(f"{video.name}: {len(paths)} 張，累計 {len(records)} 個人框", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)

    X = np.array(features, dtype=np.float32)
    np.save(out / "features.npy", X)
    labels = kmeans(X, args.clusters)
    # 群編號照人框數排，#1 最多
    order = np.argsort([-(labels == c).sum() for c in range(args.clusters)])
    rank = {int(c): r for r, c in enumerate(order, 1)}
    for record, label in zip(records, labels):
        record["cluster"] = rank[int(label)]

    (out / "people.json").write_text(json.dumps(records, ensure_ascii=False), encoding="utf-8")
    print(f"完成：{len(records)} 個人框，{args.clusters} 群 → {out}")
    print(f"下一步：python scripts/people_label.py {args.video_dir.name} --players 甲,乙,丙")


if __name__ == "__main__":
    main()
