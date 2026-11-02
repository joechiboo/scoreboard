"""靠衣著認人的準度：留一支影片當測試，用其他影片的指認結果做最近鄰。"""
import json, collections
import numpy as np
P = 'datasets/people/2026-10-30_half/'
recs = json.load(open(P + 'people.json', encoding='utf-8'))
X = np.load(P + 'features.npy'); X = X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-9)
L = json.load(open(P + 'labels.json', encoding='utf-8'))['crops']
idx = {r['crop']: i for i, r in enumerate(recs)}
names = collections.Counter(L.values()); print('指認', len(L), '/', len(recs), dict(names))
items = [(c, n) for c, n in L.items() if c in idx]
vid = lambda c: c.rsplit('_', 2)[0]
print('每支影片', dict(collections.Counter(vid(c) for c, _ in items)))
# 每人出現在哪幾支影片
per = collections.defaultdict(collections.Counter)
for c, n in items: per[n][vid(c)[-6:]] += 1
for n, v in per.items(): print(' ', n, dict(v))
def nn(test, train):
    if not train: return None
    a = X[[idx[c] for c, _ in train]]; lab = [n for _, n in train]
    s = a @ X[idx[test]]; k = np.argsort(-s)[:5]
    v = collections.Counter(lab[i] for i in k)
    return v.most_common(1)[0][0], float(s[k[0]])
for name, split in (('留一張（同影片也算）', lambda c: vid(c) + c), ('留一支影片', vid), ('前後各半（時間切）', None)):
    ok = tot = skip = 0; conf = collections.Counter()
    for c, n in items:
        if split is None: continue
        train = [(a, b) for a, b in items if split(a) != split(c)]
        if not any(b == n for _, b in train): skip += 1; continue
        p = nn(c, train); tot += 1; ok += p[0] == n
        if p[0] != n: conf[(n, p[0])] += 1
    if tot: print(f'{name}：對 {ok}/{tot}（這人在其他影片沒資料而略過 {skip}）；常見錯誤 {conf.most_common(5)}')
print('隨機猜基準', round(max(names.values()) / sum(names.values()), 2))
