#!/usr/bin/env python3
"""Arc-vs-flight images from a `qa.mjs ... arc` result: the aim screenshot (white dots) lightened with
the scrubbed frames (the pebble every 2 ticks), cropped around the flight."""
import json, sys
from PIL import Image, ImageChops, ImageDraw
r = json.load(open(sys.argv[1])); prefix = sys.argv[2]
for a in r['arcs']:
    base = Image.open(a['aim']).convert('RGB')
    comp = base.copy()
    for f in a['frames']:
        comp = ImageChops.lighter(comp, Image.open(f).convert('RGB'))
    dpr = base.size[0] / r['viewport']['width']
    ax, ay = a['pointer']['anchor']['x'], a['pointer']['anchor']['y']
    box = [int(max(0, ax - 60) * dpr), int(max(0, ay - 280) * dpr), int(min(r['viewport']['width'], ax + 560) * dpr), int(min(r['viewport']['height'] - 44, ay + 70) * dpr)]
    c = comp.crop(box)
    ImageDraw.Draw(c).text((10, 10), f"{r['browser']} {a['level']} pull {tuple(a['releasedPull'])}: arc dots + pebble every 2 ticks; {a['freeFlightTicksBitExact']} free-flight ticks bit-exact", fill=(255, 255, 255))
    out = f"{prefix}-{a['name']}.png"
    c.save(out, optimize=True)
    print(out, c.size)
