#!/usr/bin/env python3
"""Summarises a `qa.mjs ... shots` result: figures per shot, playback, memory, and the outputs
compared with fixtures/golden/<case>.json (player = the client's default 'player') or the owner's shot."""
import json, os, sys
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
FIELDS = ['version', 'level_hash', 'seed', 'player', 'inputs_hash', 'score', 'won', 'shots_used', 'ticks_run', 'final_state_hash']
OWNER = {'score': 5300, 'ticks_run': 106, 'final_state_hash': 0x52d1076e0dc51f1c02fd74481aeeacd930f79fa4a99f075f70ee1b5487ab673}
r = json.load(open(sys.argv[1]))
print(r['browser'], r['version'], r['viewport'], 'headless' if r['headless'] else 'headed', r['baseUrl'])
for c in r['cases']:
    out = (c.get('outputsLog') or '').split(': ', 1)[-1].split()
    verdict = ''
    base = c['name'].split('-', 1)[1] if c['name'].split('-', 1)[0] in ('chrome', 'firefox', 'webkit') else c['name']
    g = os.path.join(REPO, 'fixtures/golden', base + '.json')
    if out and os.path.exists(g):
        gold = [int(x, 16) for x in json.load(open(g))['outputs']]
        mine = [int(x) for x in out]
        verdict = 'golden: ' + ('all 10 felts equal' if gold == mine else 'DIFF ' + ','.join(FIELDS[i] for i in range(10) if gold[i] != mine[i]))
    elif out and base.startswith('pile10-owner'):
        mine = dict(zip(FIELDS, [int(x) for x in out]))
        verdict = 'owner: ' + ('score/ticks/final_state_hash equal' if all(mine[k] == v for k, v in OWNER.items()) else 'DIFF ' + str({k: mine[k] for k in OWNER}))
    print(f"\n## {c['name']} ({c['level']}, {c['bodies']} bodies) pulls={c['pulls']} {verdict}")
    print('  init:', ' | '.join(c['init']))
    print('  over:', c.get('levelOver'), '| panel shown %s ms before the playback end' % c.get('panelShownBeforePlaybackEndMs'))
    if out: print('  final_state_hash 0x%x' % int(out[9]))
    for s in c['shots']:
        print('  ', s['figures'])
        print('     sim %d ms, playback %d ms, rAF %s fps (p50 %s, p95 %s, max %s ms, >50 ms: %d), HUD max stall %d ms, slow motion %d ms' % (s['simulatedMs'], s['playbackMs'], s['rafFps'], s['frameMsP50'], s['frameMsP95'], s['frameMsMax'], s['framesOver50ms'], s['hudMaxStallMs'], s['slowMotionMs']))
    print('  memory:', c.get('memory'))
print('\nerrors:', r.get('errors'))
print('console (not log):', r.get('console'))
