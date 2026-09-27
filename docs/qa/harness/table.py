#!/usr/bin/env python3
"""Markdown rows (one per shot) from `qa.mjs ... shots` results: browser, case, pulls, result, figures."""
import json, os, re, sys
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
OWNER = {'score': 5300, 'ticks': 106, 'fsh': 0x52d1076e0dc51f1c02fd74481aeeacd930f79fa4a99f075f70ee1b5487ab673}
print('| browser | case | pull | level result | vs expected | shot | first frame | ticks | Cairo steps | VM time | playback | slow motion | wasm peak |')
print('|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|')
for f in sys.argv[1:]:
    r = json.load(open(f))
    br = f"{r['browser']} {r['version'].split('.')[0]}"
    for c in r['cases']:
        name = c['name'].split('-', 1)[1]
        if name == 'pile10-owner': continue  # the screenshot run; `pile10-owner-nocapture` is the clean one
        out = [int(x) for x in (c.get('outputsLog') or '').split(': ', 1)[-1].split()]
        g = os.path.join(REPO, 'fixtures/golden', name + '.json')
        if os.path.exists(g):
            ok = [int(x, 16) for x in json.load(open(g))['outputs']] == out
            vs = 'golden: 10/10 felts' if ok else 'golden: DIFF'
        else:
            ok = out[5] == OWNER['score'] and out[8] == OWNER['ticks'] and out[9] == OWNER['fsh']
            vs = 'owner: 5300 / 106 / 0x52d1…b673' if ok else 'owner: DIFF'
        res = re.sub(r'^level over: ', '', c['levelOver'])
        for i, s in enumerate(c['shots']):
            m = re.match(r'shot (\d+): first frame (\d+) ms, (\d+) ticks, ([\d.]+)M steps, ([\d.]+) s, .* wasm (\d+) MB', s['figures'])
            pull = ','.join(map(str, c['pulls'][i]))
            print(f"| {br} | {name} | {pull} | {res if i == 0 else ''} | {vs if i == 0 else ''} | {m[1]} | {m[2]} ms | {m[3]} | {m[4]}M | {m[5]} s | {s['playbackMs']/1000:.2f} s | {s['slowMotionMs']/1000:.2f} s | {m[6]} MB |")
