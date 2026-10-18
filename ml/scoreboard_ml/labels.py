"""人工標記檔：每行一顆球「時間,結果,分數」，格式見 docs/recording-guide.md。"""

import csv
from pathlib import Path


def parse_time(s: str) -> float:
    parts = s.strip().split(":")
    return sum(float(p) * 60**i for i, p in enumerate(reversed(parts)))


MADE = {"進", "進球", "made", "goal", "y", "yes", "1"}


def load_labels(path: Path) -> list[float]:
    """回傳進球的時間（沒進的球略過）。"""
    times = []
    with path.open(encoding="utf-8") as f:
        for row in csv.reader(f):
            if not row or not row[0].strip() or row[0].lstrip().startswith("#"):
                continue
            try:
                t = parse_time(row[0])
            except ValueError:
                continue  # 標題列
            result = row[1].strip().lower() if len(row) > 1 else ""
            if not result or result in MADE:
                times.append(t)
    return sorted(times)
