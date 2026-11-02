"""本機指認介面：看 people_extract.py 分好的人框，指定誰是誰。

用法：
  python scripts/people_label.py 2026-10-30_half --players 甲,乙,丙 [--port 8765]

只綁 127.0.0.1，畫面不會離開這台電腦。每次點選自動存到 datasets/people/<場次>/labels.json。
"""

import argparse
import json
import os
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

ML_ROOT = Path(__file__).resolve().parents[1]
PAGE = Path(__file__).with_name("people_label.html")


def rank_similar(records: list[dict], X, labels: dict, player: str, limit: int) -> list[str]:
    """還沒指定的人框裡，最像 player 已確認那幾張的排前面。回傳 crop 檔名。"""
    resolved = [labels["crops"].get(r["crop"]) for r in records]
    positives = [i for i, name in enumerate(resolved) if name == player]
    if not positives:
        return []
    rejected = set(labels.get("not", {}).get(player, []))
    negatives = [
        i for i, r in enumerate(records)
        if r["crop"] in rejected or resolved[i] not in (None, player)
    ]
    # 取最像的幾張平均，同一個人正面、背面差很多，不能跟全部比
    top = min(3, len(positives))
    score = np.sort(X @ X[positives].T, axis=1)[:, -top:].mean(1)
    if negatives:
        score -= 0.5 * (X @ X[negatives].T).max(1)

    # 同一張畫面裡一個人只會出現一次
    used_frames = {records[i]["frame"] for i in positives}
    result = []
    for i in np.argsort(-score):
        r = records[i]
        if resolved[i] is None and r["crop"] not in rejected and r["frame"] not in used_frames:
            used_frames.add(r["frame"])
            result.append(r["crop"])
            if len(result) == limit:
                break
    return result


def make_handler(root: Path, players: list[str]):
    labels_path = root / "labels.json"
    records = json.loads((root / "people.json").read_text(encoding="utf-8"))
    X = np.load(root / "features.npy")

    def load_labels() -> dict:
        if labels_path.exists():
            return json.loads(labels_path.read_text(encoding="utf-8"))
        return {"crops": {}, "not": {}}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def send_body(self, body: bytes, content_type: str, status: int = 200) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            path = self.path.split("?")[0]
            if path == "/":
                self.send_body(PAGE.read_bytes(), "text/html; charset=utf-8")
            elif path == "/api/data":
                data = {
                    "session": root.name,
                    "players": players,
                    "people": records,
                    "labels": load_labels(),
                }
                self.send_body(json.dumps(data, ensure_ascii=False).encode("utf-8"), "application/json")
            elif path.startswith(("/crops/", "/frames/")):
                folder, name = path[1:].split("/", 1)
                file = root / folder / Path(name).name  # 只取檔名，不能跳出資料夾
                if file.is_file():
                    self.send_body(file.read_bytes(), "image/jpeg")
                else:
                    self.send_body(b"not found", "text/plain", 404)
            else:
                self.send_body(b"not found", "text/plain", 404)

        def do_POST(self) -> None:
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path == "/api/similar":
                crops = rank_similar(records, X, body["labels"], body["player"], body["limit"])
                self.send_body(json.dumps(crops, ensure_ascii=False).encode("utf-8"), "application/json")
                return
            if self.path != "/api/labels":
                self.send_body(b"not found", "text/plain", 404)
                return
            labels = body
            # 先寫暫存檔再換名，存到一半關掉也不會把指認結果弄壞
            tmp = labels_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(labels, ensure_ascii=False, indent=1), encoding="utf-8")
            os.replace(tmp, labels_path)
            self.send_body(b"{}", "application/json")

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", help="datasets/people/ 底下的場次資料夾，例如 2026-10-30_half")
    parser.add_argument("--players", required=True, help="要指認的人，逗號分隔；不寫死在程式裡，repo 是公開的")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    root = ML_ROOT / "datasets" / "people" / args.session
    if not (root / "people.json").exists():
        sys.exit(f"找不到 {root / 'people.json'}，先跑 people_extract.py")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(root, args.players.split(",")))
    url = f"http://127.0.0.1:{args.port}/"
    print(f"指認介面：{url}（Ctrl+C 結束）", flush=True)
    if not args.no_browser:
        webbrowser.open(url)
    server.serve_forever()


if __name__ == "__main__":
    main()
