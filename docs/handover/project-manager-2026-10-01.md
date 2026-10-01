# Handover note — project manager of `slingfall` (2026-10-01, owner's soft stop)

## Who I am
Project manager of `slingfall` (the game and its Cairo libraries), session "[Fable 5.1] Chef de projet Slingfall"
(earlier "Angry Birds Cairo orchestration" and "[Fable 5.1] PM - Slingfall"). Above me: "[Fable 5.1] Overseer". Below
me: "[Opus 5.5] Orchestrateur nalgebra — slingfall" (simba-cairo, nalgebra-cairo), "[Opus 5.5] Orchestrateur rapier —
slingfall" (rapier-cairo); the glam track (fixed, glam, glamx) has no session: a suggestion chip "[Opus 5.5]
Orchestrateur glam — slingfall" (task_af5ef1de, context `pm/messages/orchestrators/glam-2026-10-01.md`) waits for the
owner's click; the retired sessions keep the prefix `[Retired]`. The game track is run by the project manager as
interim orchestrator with the launcher `/home/claude/projects/pm/scripts/agent.sh` (units `pm-game-<Short>`).
The notebook `/home/claude/projects/pm` (local git): `RESUME.md` (resume point of 2026-09-29, still accurate for the
history), `STATUS.md` (dated updates, latest at the bottom), `decisions/`, `research/`, `reports/`, `messages/`.
The operating document: `slingfall/OPERATIONS.md`. Memory files: `~/.claude/projects/-home-claude-projects/memory/`.

## State (2026-10-01, ~18:00 UTC)
- **Game (slingfall)**: main green at `060341a`+; contract **v2 live on Sepolia** (`0x292f4b7d…4a02`, hosted client on
  it); contract **v3** (proven tier, SNIP-36) in code, wired on the devnet, not deployed; game on **rapier alpha.8 /
  fixed 0.4.0 / glam_core 0.4.1**; `scripts/play.sh` plays everything locally, **verified on the owner's Mac** (L2
  #50) with three UI fixes (L3 #51). Running when this note was written: lot **D1** (`pm-game-D1`, Sonnet 5.5,
  worktree `.claude/worktrees/exec-D1`, branch `feat/d1-deterministic-builds`): every hashed / sized / measured build
  on one compiler thread, a determinism check in CI; it stops and reports if `c1main`'s one-thread hash differs from
  the Sepolia pin `0x580ef5d1…edf75a`. When it ends: read its `REPORT.md`, `nexus review` its PR (Sonnet fallback),
  merge, archive the report in `pm/reports/`, remove the worktree, PLAN row.
- **nalgebra**: **0.1.1 released** (54 packages, tag v0.1.1; package rule met); PR #90 (documents: PACKAGES.md
  regenerated, CHANGELOG dated, follow-ups) in review; next the TC migration lots (simba first) on one thread.
- **rapier**: alpha.8 released; parity raw 84.6 % / in scope 94.5 %; queue idle; **TC1** (Scarb 2.20.1 / snforge
  0.64.0 migration) briefed in #246 (documents), **waiting for the owner's merge** (the session's guard refuses merges;
  escalated twice by the Overseer; the project manager does not merge in its place).
- **glam family**: fixed 0.4.0, glam 0.4.1 (split), glamx 0.4.1 published; size gates enforcing; nothing running.
- **SNIP-36 real run**: blocked on PROOF2 on Sepolia (no transaction with proof facts seen on 2026-09-28); then the
  toy round trip (research SN1 §7), then a rented ~96 GB prover machine (owner).
- `nexus progress --project slingfall` at the time of writing: only `slingfall/impl-l2` (succeeded, report written)
  and the review agents; no Nexus implementer running; the game's D1 runs through the project launcher.

## Decisions taken (since the resume point), with what reverses them
- Package size rule applied everywhere; nalgebra re-cut per exact dimension (54 packages) and released 0.1.1; a
  dimension 5-6 closure budget of 20 s / 4.5 GB (owner); reversed by the owner only.
- Game layout (e) on declared classes, world class 71,076 CASM under the 73,728 gate; contract v3 code; `play.sh`.
- Deterministic builds: one compiler thread for every hashed / sized / measured build (D1, TC lots); reversed if the
  compiler drift is fixed upstream.
- Scarb 2.20.1 migration (owner's D-180): libraries before the game; no release forced by the bump; the game last
  (re-pin with grace, classes re-measured).
- H4's deferred note (chain_intact compares height and instance, not the block hash) and L3's deferred minor (the
  normal banner variant unpictured) are in `docs/PLAN.md`.
- Pending, with recommendation: hosting of the attest / prove services (owner: standby, play locally first; recommend
  a small dedicated machine + a subdomain of bal7hazar.com when they want it public); a relayer account (recommend
  dedicated); contract v3 deployment on Sepolia only when PROOF2 is live; M6 name and assets (owner).

## Threads not closed
- Owner: rapier #246 merge (or the rapier session's permission mode); the glam chip; the LAN check of the local play
  (`PLAY_HOST=0.0.0.0 scripts/play.sh up`, then `down`) on the Mac.
- Overseer: the soft stop (this note is its answer); the compile drift's upstream issue is Grim World's.
- Orchestrators: nalgebra writes its own handover note and successor message; rapier the same.

## Next, in order
1. After the soft stop: D1's report, review, merge; then the game's TC lot (toolchain bump: pins, CI, snapshots,
   `c1main` hash re-measured on one thread, Sepolia re-pin with grace if it moved, classes against 73,728).
2. nalgebra #90 merge, then its TC lots; rapier TC1 after #246; glam's orchestrator (chip) for fixed / glam / glamx.
3. When PROOF2 is live on Sepolia: the SNIP-36 toy round trip (SN1 §7), then contract v3 deployment and a real chunk
   proof on a rented machine.
4. The owner's product decisions: hosting, relayer, name and assets.

## Traps
- `systemctl --user` in this shell needs `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus` (the desktop exports
  another bus): a false "timer stopped" alert happened.
- `~/orchestrator/capacity.json` (timer `pm-capacity`, every 2 min) is the launch rule for every orchestrator; recreate
  the timer after a reboot (`systemd-run --user --unit pm-capacity --on-active=5 --on-unit-active=120 /usr/bin/python3
  ~/projects/pm/scripts/capacity.py`). `~/orchestrator/slots/` belongs to Grim World: never touch it.
- The VPS is the largest Hostinger plan (31 GB): one heavy suite at a time; a nalgebra build peaks at 11 GB, rapier's
  whole-shot tests near 20 GB.
- A Nexus agent keeps the profile stored at its creation when resumed; the Mac worker captures PATH at its start.
- Headless agents die when their turn ends on a background command: every brief says "foreground only".
- The owner declined one background `nexus wait` in this session: check agents at the next turn instead of arming
  waits for them.
- A documents-only merge is refused by an orchestrator session's classifier ("Merge Without Review"): the owner
  merges; the project manager never merges in a session's place.
- scarbs.xyz refuses a keyword over 20 characters with a non-JSON answer (nalgebra #89).
- CI caches `target/` (setup-scarb): a prover job store restored from cache answered a fresh devnet (H4).
- The `sonnet` alias of the launcher runs Claude Sonnet 5.5 (read the model from the commit trailers).
