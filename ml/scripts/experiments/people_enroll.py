"""模擬開打前登記：每人只給 k 張人框（完全沒有路人範例），比相似度門檻，測其他所有人框。重複 30 次取平均。"""
import json
import numpy as np
P = 'datasets/people/2026-10-30_half/'
recs = json.load(open(P + 'people.json', encoding='utf-8'))
X = np.load(P + 'features.npy'); L = json.load(open(P + 'labels.json', encoding='utf-8'))['crops']
y = np.array([L[r['crop']] for r in recs]); T = np.array([r['t'] for r in recs]); V = np.array([r['video'] for r in recs])
PL = ['我', 'Dennis', 'Spark']; rng = np.random.default_rng(0)
print('每人張數 門檻  我們被認出  認對是誰  路人被誤認')
for k in (3, 5, 10, 20):
    for th in (0.75, 0.80, 0.83, 0.86):
        rec, right, fp = [], [], []
        for _ in range(30):
            en = {n: rng.choice(np.where(y == n)[0], k, replace=False) for n in PL}
            used = np.concatenate(list(en.values())); mask = np.ones(len(y), bool); mask[used] = False
            sims = np.stack([(X[mask] @ X[en[n]].T).max(1) for n in PL], 1); pick = sims.argmax(1); best = sims.max(1); yt = y[mask]
            ours = yt != '路人'; hit = best >= th
            rec.append((hit & ours).sum() / ours.sum())
            right.append(((hit & ours) & (np.array(PL)[pick] == yt)).sum() / max((hit & ours).sum(), 1))
            fp.append((hit & ~ours).sum() / (~ours).sum())
        print(f"{k:>4}  {th:.2f}   {np.mean(rec):5.0%}     {np.mean(right):5.0%}     {np.mean(fp):5.1%}")
