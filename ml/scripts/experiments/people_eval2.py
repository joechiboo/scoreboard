"""留一支影片：每個人的準度，以及「我們三人 / 路人」二分的準度。"""
import json, collections
import numpy as np
P = 'datasets/people/2026-10-30_half/'
recs = json.load(open(P + 'people.json', encoding='utf-8'))
X = np.load(P + 'features.npy'); L = json.load(open(P + 'labels.json', encoding='utf-8'))['crops']
names = [L[r['crop']] for r in recs]; vids = np.array([r['video'] for r in recs]); names_a = np.array(names)
pred = []
for i in range(len(recs)):
    tr = np.where(vids != vids[i])[0]; k = tr[np.argsort(-(X[tr] @ X[i]))[:7]]
    pred.append(collections.Counter(names_a[k]).most_common(1)[0][0])
pred = np.array(pred)
PLAYERS = sorted(set(names) - {'路人'})
for n in PLAYERS + ['路人']:
    tp = ((pred == n) & (names_a == n)).sum()
    print(f"{n}: 實際 {(names_a==n).sum()}，抓到 {tp}（{tp/(names_a==n).sum():.0%}），認成他的裡面真的是他 {tp/max((pred==n).sum(),1):.0%}")
ours = names_a != '路人'; po = pred != '路人'
print('我們三人 抓到', f"{(ours&po).sum()}/{ours.sum()}", '路人被當成我們', f"{(~ours&po).sum()}/{(~ours).sum()}")
# 同一秒內的兩張不算獨立：另外看「不同影片」已是最嚴格的切法
print('出現的影片數：', {n: len(set(vids[names_a == n])) for n in PLAYERS})
