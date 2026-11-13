"""照 clips.json 剪精華：虛擬鏡頭跟著球、字幕、慢動作重播。

用法：
  # 這場我有參與的球（得分、助攻、其他參與）
  python scripts/highlight_render.py datasets/highlights/2026-10-30_half/clips.json --player 我 --out 精華_我.mp4
  # 全收；加 --dry-run 只列出會收哪幾顆
  python scripts/highlight_render.py datasets/highlights/2026-10-30_half/clips.json --out 精華.mp4

clips.json（一場一份，不進版控，裡面有球員名字）：
  {
    "videos": "datasets/videos/2026-10-30_half",
    "rim": [1815, 630],
    "clips": [{
      "video": "clip.mp4", "goal": 805.6,
      "shooter": "乙", "assist": "甲", "involved": [],
      "live": [-7.0, 2.2],
      "captions": [[-3.1, -2.1, "甲 傳球"], [-2.1, 2.2, "乙 跳投命中"]],
      "replay": {"window": [-3.3, -1.3], "x": 2850, "y0": 560, "w": [1700, 1450]}
    }]
  }
shooter／assist／involved 的意思見 scoreboard_ml/clips.py；不用 --player 時可以省略。
時間都相對進球秒數。replay 的 x 是鏡頭中心、y0 是上緣、w 是開始到結束的裁切寬度（4K 原圖座標）。
鏡頭路徑用 highlight_track.py 的追蹤結果，要先對每顆跑過。
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ML_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ML_ROOT))
from scoreboard_ml.clips import roles, select_clips  # noqa: E402

OUT_W, OUT_H, FPS = 1920, 1080, 60
SRC_W, SRC_H = 3840, 2160
LIVE_W = 2300
LIVE_Y0 = 300  # 固定上緣：籃框和場上球員都在畫面內，鏡頭只左右搖
CAMERA_SIGMA = 0.5  # 鏡頭平滑的秒數，太小會跟著球抖
SLOW_SPEED = 0.5
FADE = 0.2
FONT_PATH = "C:/Windows/Fonts/msjhbd.ttc"
ACCENT = (64, 176, 255)


def camera_track(track_file: Path, clip: dict, rim_x: float):
    """回傳 t → 鏡頭中心 x：跟著球，濾掉地上不動的球，進球時帶到籃框。"""
    data = json.loads(track_file.read_text(encoding="utf-8"))
    points = []
    for frame in data["frames"]:
        if frame["balls"]:
            box = max(frame["balls"], key=lambda b: b["conf"])["box"]
            points.append((frame["t"] - clip["goal"], (box[0] + box[2]) / 2, (box[1] + box[3]) / 2))
    moving = [(0.0, rim_x)]
    if points:
        pts = np.array(points)
        for t, x, y in pts:
            # 隔一秒以上還在同一點，就是場邊放著的球（持球站著的也會被濾掉，鏡頭用內插補上）
            same = (np.abs(pts[:, 0] - t) > 1.0) & (np.hypot(pts[:, 1] - x, pts[:, 2] - y) < 60)
            if same.sum() < 3:
                moving.append((t, x))
    moving = np.array(sorted(moving))

    grid = np.arange(clip["live"][0] - 1, clip["live"][1] + 1, 1 / FPS)
    raw = np.interp(grid, moving[:, 0], moving[:, 1])
    sigma = int(CAMERA_SIGMA * FPS)
    kernel = np.exp(-0.5 * (np.arange(-3 * sigma, 3 * sigma + 1) / sigma) ** 2)
    smooth = np.convolve(np.pad(raw, 3 * sigma, mode="edge"), kernel / kernel.sum(), mode="valid")
    half = LIVE_W / 2
    return lambda t: float(np.clip(np.interp(t, grid, smooth), half, SRC_W - half))


def to_patch(image: Image.Image):
    return np.array(image)[:, :, [2, 1, 0, 3]].astype(np.float32)


def caption_patch(text: str, font):
    width = int(ImageDraw.Draw(Image.new("RGBA", (10, 10))).textlength(text, font=font)) + 78
    height = 98
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, width - 1, height - 1), radius=10, fill=(12, 14, 18, 200))
    draw.rectangle((0, 8, 7, height - 9), fill=ACCENT + (255,))
    draw.text((34, 16), text, font=font, fill=(255, 255, 255, 255))
    return to_patch(image)


def badge_patch(text: str, font):
    width = int(ImageDraw.Draw(Image.new("RGBA", (10, 10))).textlength(text, font=font)) + 36
    image = Image.new("RGBA", (width, 60), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, width - 1, 59), radius=8, fill=(220, 50, 50, 230))
    draw.text((18, 7), text, font=font, fill=(255, 255, 255, 255))
    return to_patch(image)


def blend(frame, patch, x: int, y: int, opacity: float = 1.0) -> None:
    h, w = patch.shape[:2]
    alpha = patch[:, :, 3:4] / 255 * opacity
    frame[y:y + h, x:x + w] = (frame[y:y + h, x:x + w] * (1 - alpha) + patch[:, :, :3] * alpha).astype(np.uint8)


def render_segment(pipe, video: Path, goal: float, start: float, end: float, speed: float, crop_of, captions, badge=None) -> int:
    """把 start 到 end（相對進球）寫進 pipe，回傳幀數。speed < 1 是慢動作。"""
    cap = cv2.VideoCapture(str(video))
    cap.set(cv2.CAP_PROP_POS_MSEC, max(0, goal + start - 0.5) * 1000)
    total = int(round((end - start) / speed * FPS))
    written = 0
    while written < total and cap.grab():
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000 - goal
        if t < start - 1 / FPS:
            continue
        ok, image = cap.retrieve()
        if not ok:
            break
        # 來源是變動幀率：照時間補幀或跳幀，輸出才是固定 60fps、聲音對得上
        while written < total and start + written * speed / FPS <= t:
            now = start + written * speed / FPS
            x0, y0, w = crop_of(now)
            h = w * OUT_H / OUT_W
            x0, y0 = int(np.clip(x0, 0, SRC_W - w)), int(np.clip(y0, 0, SRC_H - h))
            frame = cv2.resize(image[y0:int(y0 + h), x0:int(x0 + w)], (OUT_W, OUT_H), interpolation=cv2.INTER_AREA)
            for a, b, patch in captions:
                if a <= now < b:
                    blend(frame, patch, 60, OUT_H - patch.shape[0] - 60, min(1.0, (now - a) / (0.15 * min(speed, 1))))
            if badge is not None:
                blend(frame, badge, OUT_W - badge.shape[1] - 50, 44)
            fade = min(1.0, written / FPS / FADE, (total - written) / FPS / FADE)
            if fade < 1:
                frame = (frame * fade).astype(np.uint8)
            pipe.stdin.write(frame.tobytes())
            written += 1
    cap.release()
    return written


def render_clip(clip: dict, plan: dict, plan_dir: Path, workdir: Path, n: int, fonts) -> Path:
    videos = ML_ROOT / plan["videos"]
    video = videos / clip["video"]
    track_file = plan_dir / "tracks" / f"{Path(clip['video']).stem}_{clip['goal']:.1f}.json"
    track = camera_track(track_file, clip, plan["rim"][0])
    captions = [(a, b, caption_patch(text, fonts[0])) for a, b, text in clip["captions"]]
    silent = workdir / f"{n}_silent.mp4"
    pipe = subprocess.Popen(
        ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{OUT_W}x{OUT_H}", "-r", str(FPS), "-i", "-",
         "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", str(silent)],
        stdin=subprocess.PIPE,
    )
    start, end = clip["live"]
    live = render_segment(pipe, video, clip["goal"], start, end, 1.0, lambda t: (track(t) - LIVE_W / 2, LIVE_Y0, LIVE_W), captions)
    slow = 0
    replay = clip.get("replay")
    if replay:
        ra, rb = replay["window"]
        w0, w1 = replay["w"]

        def replay_crop(t):
            k = (t - ra) / (rb - ra)
            w = w0 + (w1 - w0) * k * k * (3 - 2 * k)
            return replay["x"] - w / 2, replay["y0"], w

        slow = render_segment(pipe, video, clip["goal"], ra, rb, SLOW_SPEED, replay_crop, captions, badge_patch("慢動作", fonts[1]))
    pipe.stdin.close()
    pipe.wait()

    # 聲音只配現場段，慢動作靜音
    part = workdir / f"{n}.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", str(silent), "-ss", f"{clip['goal'] + start:.3f}", "-t", f"{live / FPS:.3f}", "-i", str(video),
         "-map", "0:v", "-map", "1:a", "-af", "apad", "-shortest", "-c:v", "copy", "-c:a", "aac", "-ar", "48000", "-b:a", "160k", str(part)],
        check=True,
    )
    print(f"{clip['video']} @{clip['goal']}：現場 {live / FPS:.1f}s + 慢動作 {slow / FPS:.1f}s", flush=True)
    return part


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--player", help="只收這個人有參與的球（得分、助攻、其他參與）")
    parser.add_argument("--dry-run", action="store_true", help="只列出會收哪幾顆，不剪片")
    args = parser.parse_args()
    if not args.dry_run and args.out is None:
        parser.error("要給 --out（或加 --dry-run）")

    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    plan["clips"] = select_clips(plan["clips"], args.player)
    if not plan["clips"]:
        sys.exit(f"沒有 {args.player} 參與的球")
    for clip in plan["clips"]:
        who = f"（{roles(clip)[args.player]}）" if args.player else ""
        print(f"{clip['video']} @{clip['goal']}{who}：{' / '.join(c[2] for c in clip['captions'])}")
    if args.dry_run:
        return

    fonts = ImageFont.truetype(FONT_PATH, 52), ImageFont.truetype(FONT_PATH, 34)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        parts = [render_clip(clip, plan, args.plan.parent, workdir, n, fonts) for n, clip in enumerate(plan["clips"])]
        listing = workdir / "list.txt"
        listing.write_text("".join(f"file '{p.as_posix()}'\n" for p in parts), encoding="utf-8")
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy", "-movflags", "+faststart", str(args.out)],
            check=True,
        )
    print("完成", args.out)


if __name__ == "__main__":
    main()
