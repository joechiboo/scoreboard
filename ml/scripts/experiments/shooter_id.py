"""用衣著認 15 位出手者：找最像的已指認人框，太不像就算「其他人」。輸出檢查用的圖。"""
import collections, json, sys
from pathlib import Path
import cv2, numpy as np
from ultralytics import YOLO
sys.path.insert(0, 'scripts')
from people_extract import clothing_feature
S = Path(sys.argv[1]); P = 'datasets/people/2026-10-30_half/'; V = Path('datasets/videos/2026-10-30_half')
recs = json.load(open(P + 'people.json', encoding='utf-8'))
X = np.load(P + 'features.npy'); L = json.load(open(P + 'labels.json', encoding='utf-8'))['crops']
idx = {r['crop']: i for i, r in enumerate(recs)}
items = [(idx[c], n) for c, n in L.items() if c in idx]
A = X[[i for i, _ in items]]; names = [n for _, n in items]
vid = lambda i: recs[i]['video']
# 門檻參考：已指認的人（比其他影片）與未指認人框的最高相似度
lab = []
for k, (i, n) in enumerate(items):
    mask = [j for j, (m, _) in enumerate(items) if vid(m) != vid(i)]
    if mask: lab.append(float((A[mask] @ X[i]).max()))
un = [float((A @ X[i]).max()) for i in range(len(recs)) if recs[i]['crop'] not in L]
print('已指認 相似度 p10/p50', np.round(np.percentile(lab, [10, 50]), 3), ' 未指認 p50/p90', np.round(np.percentile(un, [50, 90]), 3))
m = YOLO('yolo11n-seg.pt'); tiles = []
for h in json.loads((S / 'hits.json').read_text()):
    cap = cv2.VideoCapture(str(V / (h['clip'] + '.mp4'))); cap.set(cv2.CAP_PROP_POS_MSEC, h['t'] * 1000); ok, f = cap.read()
    r = m.predict(f, imgsz=1920, conf=0.25, classes=[0], verbose=False, retina_masks=True)[0]
    bx = h['box']; best, bi = None, 0
    if r.masks is not None:
        for n, b in enumerate(r.boxes.xyxy.cpu().numpy().astype(int).tolist()):
            ix = max(0, min(b[2], bx[2]) - max(b[0], bx[0])); iy = max(0, min(b[3], bx[3]) - max(b[1], bx[1])); inter = ix * iy
            u = (b[2]-b[0])*(b[3]-b[1]) + (bx[2]-bx[0])*(bx[3]-bx[1]) - inter
            if inter / max(u, 1) > bi: bi, best = inter / max(u, 1), (n, b)
    if best is None: print(h['clip'][-6:], round(h['goal']), '分割失敗'); continue
    n, (x1, y1, x2, y2) = best
    crop = f[y1:y2, x1:x2]; mk = (r.masks.data.cpu().numpy()[n] > 0.5)[y1:y2, x1:x2].astype(np.uint8)
    q = clothing_feature(crop, mk); sim = A @ q; top = np.argsort(-sim)[:5]
    v = collections.Counter(names[i] for i in top).most_common(1)[0][0]
    others = sum(1 for b in r.boxes.xyxy.cpu().numpy().astype(int).tolist() if b != [x1, y1, x2, y2] and max(0, min(b[2], x2) - max(b[0], x1)) * max(0, min(b[3], y2) - max(b[1], y1)) > 0.1 * (x2-x1)*(y2-y1))
    print(h['clip'][-6:], f"{h['goal']:6.0f}s", v, f"相似度 {sim[top[0]]:.3f}", f"重疊 {others} 人")
    th = cv2.resize(crop, (int(300 * crop.shape[1] / crop.shape[0]), 300)); pad = np.zeros((340, 220, 3), np.uint8)
    pad[40:340, 0:min(220, th.shape[1])] = th[:, :220]
    from PIL import Image, ImageDraw, ImageFont
    im = Image.fromarray(pad[..., ::-1]); d = ImageDraw.Draw(im); ft = ImageFont.truetype(r'C:\Windows\Fonts\msjh.ttc', 15)
    d.text((2, 0), f"{h['clip'][-6:]} {h['goal']:.0f}s", font=ft, fill=(255, 255, 255)); d.text((2, 18), f"{v} {sim[top[0]]:.2f}", font=ft, fill=(255, 255, 0))
    tiles.append(np.array(im)[..., ::-1])
while len(tiles) % 8: tiles.append(np.zeros_like(tiles[0]))
cv2.imwrite(str(S / 'shooter_id.jpg'), np.vstack([np.hstack(tiles[k:k + 8]) for k in range(0, len(tiles), 8)]))
