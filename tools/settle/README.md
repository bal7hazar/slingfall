# settle

Pre-settles a Slingfall level (`docs/DESIGN.md` D2: dynamic bodies are stored settled and asleep) and
serves `levelc.py check --rules`. Python 3 standard library and `scarb execute` on the replay
executables (`scarb --manifest-path crates/slingfall_replay/Scarb.toml build` first, or omit
`--no-build`). Nothing is added to Cairo. The method, its limits and the measured numbers are in
[`docs/levels.md`](../../docs/levels.md); the module docstring of `settle.py` is the reference.

```sh
python3 tools/settle/settle.py fixtures/levels/tower.json --ticks 120 --out tower.settled.json [--no-build]
python3 tools/settle/test_settle.py                                   # unit tests, no Cairo
SETTLE_ROUND_TRIP=fixtures/levels/tower.json python3 tools/settle/test_settle.py   # + settling a settled level moves nothing
```

| file | role |
|---|---|
| `settle.py` | piles, wake position, probe run, snapping, rounds; the CLI |
| `replay.py` | `scarb execute` of `main` / `main_trace` through `tools/golden/golden.py`, trace lines into a `Run` |
| `test_settle.py` | unit tests (geometry, snapping) and the opt-in round trip |

The probe is `main_trace` on a copy of the level with `shots = 1`, `tick_cap = N`, the sling anchor
next to the pile and a pebble rolling away from it at about 1 m/s: the pebble wakes the pile's
island, the pile settles and sleeps, the last frame's poses (raw felts) are written back after a
rounding to 1 mm / 0.1 degree, and rounds repeat until nothing moves. Exit status 1 when no fixed
point is reached.
