"""追一顆進球前的球與人，輸出追蹤資料和核對用的對照圖（精華剪輯用）。

用法：
  python scripts/highlight_track.py datasets/videos/2026-10-30_half/clip.mp4 453.6

輸出到 datasets/highlights/<場次>/tracks/<影片>_<進球秒數>.json、.jpg。
認人用 people_label.py 的指認結果，沒指認的都算路人。

對照圖只給人看：誰傳誰投要用眼睛判斷，球常被遮住，場邊閒置的球也會被當成比賽球。
"""

import argparse
import collections
import json
import sys
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO

from people_extract import clothing_feature

ML_ROOT = Path(__file__).resolve().parents[1]
OTHER = "路人"
PERSON, BALL = 0, 32  # COCO 類別
SHEET_BEFORE, SHEET_AFTER, SHEET_STEP = 7.0, 1.2, 0.5  # 對照圖涵蓋進球前後幾秒、每張間隔
SHEET_SCALE = 0.25
SHEET_COLUMNS = 3
VOTE_INTERVAL = 0.5  # 每條軌跡隔多久認一次人
PALETTE = [(255, 170, 90), (40, 190, 255), (130, 230, 70), (220, 110, 230), (110, 120, 255)]


def label_text(name: str, players: list[str]) -> str:
    """cv2 寫不了中文，非 ASCII 的名字換成代號。"""
    if name.isascii():
        return name
    return "ME" if name == "我" else f"P{players.index(name) + 1}"


class PersonClassifier:
    """用指認過的人框比衣著，k 個最像的投票。"""

    def __init__(self, session: Path):
        records = json.loads((session / "people.json").read_text(encoding="utf-8"))
        crops = json.loads((session / "labels.json").read_text(encoding="utf-8"))["crops"]
        self.X = np.load(session / "features.npy")
        self.names = [crops.get(r["crop"], OTHER) for r in records]
        self.players = sorted(set(self.names) - {OTHER})
        self.seg = YOLO(str(ML_ROOT / "yolo11n-seg.pt"))

    def vote(self, crop, k: int = 9) -> dict[str, float] | None:
        h, w = crop.shape[:2]
        result = self.seg.predict(crop, imgsz=320, conf=0.25, classes=[PERSON], verbose=False, retina_masks=True)[0]
        if result.masks is None or len(result.masks) == 0:
            return None
        # 人框裡可能有別人，取最靠中間的那個
        masks = result.masks.data.cpu().numpy() > 0.5
        mask = max(masks, key=lambda m: m[:, int(w * 0.3):int(w * 0.7)].sum())
        sim = self.X @ clothing_feature(crop, mask.astype(np.uint8))
        tally = collections.Counter()
        for i in np.argsort(-sim)[:k]:
            tally[self.names[i]] += float(sim[i])
        return tally


def draw_tile(image, frame, identity, players, box, t_from_goal):
    x0, y0, x1, y1 = box
    tile = cv2.resize(image[y0:y1, x0:x1], None, fx=SHEET_SCALE, fy=SHEET_SCALE, interpolation=cv2.INTER_AREA)

    def to_tile(x, y):
        return int((x - x0) * SHEET_SCALE), int((y - y0) * SHEET_SCALE)

    for person in frame["people"]:
        name = identity.get(person["id"], OTHER)
        if name == OTHER:
            continue
        color = PALETTE[players.index(name) % len(PALETTE)]
        x_a, y_a, x_b, y_b = person["box"]
        cv2.rectangle(tile, to_tile(x_a, y_a), to_tile(x_b, y_b), color, 2)
        origin = to_tile(x_a, y_a)
        cv2.putText(tile, label_text(name, players), (origin[0], origin[1] - 4), cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2, cv2.LINE_AA)
    for ball in frame["balls"]:
        x_a, y_a, x_b, y_b = ball["box"]
        cv2.circle(tile, to_tile((x_a + x_b) / 2, (y_a + y_b) / 2), 13, (0, 0, 255), 2)
    cv2.putText(tile, f"{t_from_goal:+.1f}s", (8, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2, cv2.LINE_AA)
    return tile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("goal", type=float, help="進球的影片秒數")
    parser.add_argument("--session", help="預設用影片所在資料夾的名稱")
    parser.add_argument("--model", default=str(ML_ROOT / "yolo11m.pt"), help="要用 m 以上：n 全場幾乎抓不到球")
    parser.add_argument("--before", type=float, default=14)
    parser.add_argument("--after", type=float, default=2)
    parser.add_argument("--fps", type=float, default=15)
    parser.add_argument("--sheet-box", default="500,380,3840,1560", help="對照圖裁切範圍 x0,y0,x1,y1")
    args = parser.parse_args()

    session = args.session or args.video.parent.name
    people_dir = ML_ROOT / "datasets" / "people" / session
    if not (people_dir / "labels.json").exists():
        sys.exit(f"找不到 {people_dir / 'labels.json'}，先跑 people_extract.py、people_label.py")
    out = ML_ROOT / "datasets" / "highlights" / session / "tracks"
    out.mkdir(parents=True, exist_ok=True)
    box = [int(v) for v in args.sheet_box.split(",")]

    classifier = PersonClassifier(people_dir)
    model = YOLO(args.model)
    cap = cv2.VideoCapture(str(args.video))
    start = max(0, args.goal - args.before)
    cap.set(cv2.CAP_PROP_POS_MSEC, start * 1000)

    frames, sheet_images = [], []
    votes = collections.defaultdict(collections.Counter)
    last_vote = {}
    next_t = start
    next_sheet = args.goal - SHEET_BEFORE
    while cap.grab():
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if t > args.goal + args.after:
            break
        if t < next_t:
            continue
        next_t += 1 / args.fps
        ok, image = cap.retrieve()
        if not ok:
            break
        result = model.track(image, persist=True, imgsz=1920, conf=0.12, classes=[PERSON, BALL], verbose=False, tracker="bytetrack.yaml")[0]
        people, balls = [], []
        if len(result.boxes):
            ids = result.boxes.id.int().tolist() if result.boxes.id is not None else [None] * len(result.boxes)
            for xyxy, cls, conf, track_id in zip(result.boxes.xyxy.cpu().numpy(), result.boxes.cls.int().tolist(), result.boxes.conf.tolist(), ids):
                xyxy = [float(v) for v in xyxy]
                if cls == BALL:
                    balls.append({"box": xyxy, "conf": conf})
                elif conf > 0.3 and xyxy[3] - xyxy[1] > 120:
                    people.append({"id": track_id, "box": xyxy, "conf": conf})
        for person in people:
            track_id = person["id"]
            if track_id is None or t - last_vote.get(track_id, -9) < VOTE_INTERVAL:
                continue
            x1, y1, x2, y2 = [int(v) for v in person["box"]]
            crop = image[max(0, y1):y2, max(0, x1):x2]
            if crop.size and min(crop.shape[:2]) > 20:
                tally = classifier.vote(crop)
                if tally:
                    votes[track_id].update(tally)
                    last_vote[track_id] = t
        frame = {"t": t, "people": people, "balls": balls}
        frames.append(frame)
        if next_sheet <= t <= args.goal + SHEET_AFTER:
            next_sheet += SHEET_STEP
            # 軌跡要跑完才知道是誰，先留小圖，最後才畫框
            x0, y0, x1, y1 = box
            sheet_images.append((frame, image[y0:y1, x0:x1].copy()))
    cap.release()

    identity = {track_id: tally.most_common(1)[0][0] for track_id, tally in votes.items()}
    stem = f"{args.video.stem}_{args.goal:.1f}"
    (out / f"{stem}.json").write_text(json.dumps({
        "video": args.video.name, "goal": args.goal, "frames": frames,
        "identity": {str(k): {"name": v} for k, v in identity.items()},
    }, ensure_ascii=False), encoding="utf-8")

    x0, y0, x1, y1 = box
    tiles = []
    for frame, crop in sheet_images:
        canvas = np.zeros((y1, x1, 3), np.uint8)
        canvas[y0:y1, x0:x1] = crop
        tiles.append(draw_tile(canvas, frame, identity, classifier.players, box, frame["t"] - args.goal))
    while len(tiles) % SHEET_COLUMNS:
        tiles.append(np.zeros_like(tiles[0]))
    sheet = np.vstack([np.hstack(tiles[i:i + SHEET_COLUMNS]) for i in range(0, len(tiles), SHEET_COLUMNS)])
    cv2.imwrite(str(out / f"{stem}.jpg"), sheet, [cv2.IMWRITE_JPEG_QUALITY, 82])

    hit = sum(1 for f in frames if f["balls"]) / max(1, len(frames))
    print(f"{stem}：{len(frames)} 幀，球命中率 {hit:.0%} → {out / (stem + '.jpg')}")


if __name__ == "__main__":
    main()
