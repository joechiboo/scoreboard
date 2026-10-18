"""離線評估：對一段影片跑 YOLO + 進球判定，和人工標記的進球時間比對。

用法：
  python scripts/eval_video.py clip.mp4                       # 跳出視窗框選籃框
  python scripts/eval_video.py clip.mp4 --rim 812,402,955,430 --labels clip.csv --out clip_debug.mp4

labels CSV：每行一顆球「時間,結果,分數」，例如 1:02.5,進,3 或 0:48,沒進。
時間可寫秒數（12.5）或 分:秒（1:02.5）；只有時間沒有結果的行視為進球；# 開頭為註解。
詳見 docs/recording-guide.md。
"""

import argparse
import sys
from pathlib import Path

import cv2

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scoreboard_ml import Box, GoalConfig, GoalDetector, detection_roi, net_region  # noqa: E402
from scoreboard_ml.ball_detector import YoloBallDetector  # noqa: E402
from scoreboard_ml.labels import load_labels  # noqa: E402
from scoreboard_ml.net_motion import NetMotion  # noqa: E402


def select_rim(frame) -> Box:
    x, y, w, h = cv2.selectROI("框住籃框後按 Enter", frame, showCrosshair=False)
    cv2.destroyAllWindows()
    if w == 0 or h == 0:
        sys.exit("沒有框選籃框")
    return Box(x, y, x + w, y + h)


def match(preds: list[float], labels: list[float], tol: float):
    """一對一配對：每個標記最多配一個預測。回傳 (配對, 誤判, 漏判)。"""
    unused = list(preds)
    pairs, missed = [], []
    for t in labels:
        best = min(unused, key=lambda p: abs(p - t), default=None)
        if best is not None and abs(best - t) <= tol:
            pairs.append((t, best))
            unused.remove(best)
        else:
            missed.append(t)
    return pairs, unused, missed


def fmt(t: float) -> str:
    return f"{int(t // 60)}:{t % 60:05.2f}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video", type=Path)
    ap.add_argument("--rim", help="籃框框選框 x1,y1,x2,y2（像素）；省略則跳出視窗框選")
    ap.add_argument("--labels", type=Path, help="人工標記的進球時間 CSV")
    ap.add_argument("--model", default="yolo11n.pt")
    ap.add_argument("--conf", type=float, default=0.15)
    ap.add_argument("--no-size", action="store_true", help="關閉球框大小比例檢查")
    ap.add_argument("--no-net", action="store_true", help="關閉籃網晃動確認")
    ap.add_argument("--net-threshold", type=float, default=GoalConfig.net_threshold)
    ap.add_argument("--tol", type=float, default=1.0, help="預測與標記時間可差幾秒")
    ap.add_argument("--out", type=Path, help="輸出標註影片（畫出籃框、偵測區、球、進球）")
    args = ap.parse_args()

    cap = cv2.VideoCapture(str(args.video))
    if not cap.isOpened():
        sys.exit(f"無法開啟影片：{args.video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    ok, first = cap.read()
    if not ok:
        sys.exit("影片沒有畫面")
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)

    rim = Box(*map(float, args.rim.split(","))) if args.rim else select_rim(first)
    print(f"籃框：--rim {','.join(str(int(v)) for v in (rim.x1, rim.y1, rim.x2, rim.y2))}")

    cfg = GoalConfig(use_size=not args.no_size, use_net=not args.no_net, net_threshold=args.net_threshold)
    goal = GoalDetector(rim, cfg)
    roi = detection_roi(rim)
    net = NetMotion(net_region(rim))
    detector = YoloBallDetector(args.model, conf=args.conf)

    writer = None
    if args.out:
        h, w = first.shape[:2]
        writer = cv2.VideoWriter(str(args.out), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))

    events, ball, i, flash = [], None, 0, 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        t = i / fps
        ball = detector.detect(frame, roi, prev=ball)
        motion = net.update(frame, ball) if cfg.use_net else None
        ev = goal.update(t, ball, motion)
        if ev:
            events.append(ev)
            flash = int(fps)
            print(f"進球 {fmt(ev.t)}  信心 {ev.confidence:.2f}  球框比 {ev.size_ratio:.2f}  網晃 {ev.net_motion}")

        if writer:
            cv2.rectangle(frame, roi.to_int()[:2], roi.to_int()[2:], (214, 111, 47), 2)
            cv2.rectangle(frame, rim.to_int()[:2], rim.to_int()[2:], (27, 96, 224), 2)
            if ball:
                cv2.circle(frame, (int(ball.cx), int(ball.cy)), int(ball.diameter / 2), (0, 255, 255), 2)
            if motion is not None:
                cv2.putText(frame, f"net {motion:.3f}", (rim.to_int()[0], rim.to_int()[3] + 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
            if flash > 0:
                cv2.putText(frame, f"GOAL {len(events)}", (30, 60), cv2.FONT_HERSHEY_SIMPLEX, 2, (76, 194, 131), 4)
                flash -= 1
            writer.write(frame)
        i += 1

    cap.release()
    if writer:
        writer.release()

    preds = [e.t for e in events]
    print(f"\n共 {i} 幀（{i / fps:.1f} 秒），判定進球 {len(preds)} 次")
    if args.labels:
        labels = load_labels(args.labels)
        pairs, false_pos, missed = match(preds, labels, args.tol)
        precision = len(pairs) / len(preds) if preds else 0.0
        recall = len(pairs) / len(labels) if labels else 0.0
        print(f"標記進球 {len(labels)}，判對 {len(pairs)}，誤判 {len(false_pos)}，漏判 {len(missed)}")
        print(f"準確率（判定的進球有多少是真的）{precision:.0%}　召回率（真的進球抓到多少）{recall:.0%}")
        if false_pos:
            print("誤判：" + ", ".join(fmt(t) for t in false_pos))
        if missed:
            print("漏判：" + ", ".join(fmt(t) for t in missed))


if __name__ == "__main__":
    main()
