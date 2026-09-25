# tracec

Arguments of the replay executables, and their trace lines to trace format v1 JSON (lot G4).
Python 3 standard library only.

```
python3 tools/tracec/tracec.py args  fixtures/levels/pile10.felts.json --shot=-600,-392 [--shot=PX,PY,DELAY]... [--player FELT] [--out args.json]
python3 tools/tracec/tracec.py trace lines.txt [--out trace.json]      # `-` reads stdin
```

- `args` writes the `scarb execute --arguments-file` of `main` / `main_trace` (`0x` felts:
  `[len(level), level..., len(inputs), inputs...]`); the player defaults to `'player'`. Write
  negative pulls as `--shot=-600,-392` (argparse reads `--shot -600` as an option).
- `trace` reads what `main_trace` prints (the lines of `crates/slingfall_replay/README.md`,
  "Trace lines v1"; other lines, such as scarb's, are ignored) and writes trace format v1
  (`client/README.md`): material names from the D7 score (50 timber, 100 frost, 150 slate,
  1000 core, static = ground), a tick-0 frame with every dynamic body asleep at its level pose,
  then one frame per tick.

The reference trace of the client:

```sh
python3 tools/tracec/tracec.py args fixtures/levels/pile10.felts.json --shot=-600,-392 --out /tmp/args.json
scarb --manifest-path crates/slingfall_replay/Scarb.toml execute --executable-name main_trace \
  --arguments-file /tmp/args.json --print-program-output > /tmp/lines.txt
python3 tools/tracec/tracec.py trace /tmp/lines.txt --out fixtures/traces/pile10-reference.json
```
