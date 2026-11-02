"""把 YOLO 模型轉成 TFLite，給 app/ 使用。

用法：python scripts/export_tflite.py --model yolo11n.pt --imgsz 320 [--int8]
Ultralytics 的 LiteRT 轉檔只支援 Linux x86 和 macOS；Windows 請跑 GitHub Actions 的 export-model.yml。
"""

import argparse

from ultralytics import YOLO


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="yolo11n.pt")
    ap.add_argument("--imgsz", type=int, default=320, help="偵測區裁切後的輸入尺寸，越小越快")
    ap.add_argument("--int8", action="store_true", help="INT8 量化：更快更小，準確率可能略降")
    args = ap.parse_args()

    path = YOLO(args.model).export(format="litert", imgsz=args.imgsz, quantize=8 if args.int8 else None)
    print(f"已輸出：{path}")


if __name__ == "__main__":
    main()
