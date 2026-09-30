# Orchestration of `slingfall` (game track)

The game track follows the standard roles of Nexus and the project's operating document (`OPERATIONS.md` at the
root: models, budgets, launchers, domain rules, merge gates, audit lenses). This file adds what is specific to the
game track.

- **Owner of the shared files**: the orchestrator alone edits `docs/PLAN.md`, `docs/DESIGN.md`, root and crate
  `Scarb.toml`, every `lib.cairo`, `.tool-versions`, `scripts/**`, `.github/**`, `client/package.json`; executors
  list their needs under "Escalations" in `REPORT.md`.
- **Model by lot**: Sonnet 5.5 for mechanical lots (converters, fixtures, renderer on recorded traces, bumps with no
  numeric change); Opus 5.5 for rules, replay, contract, worker integration, class layouts; Fable sparingly.
- **After each merge** the orchestrator updates `docs/PLAN.md` (status line, lot table), `docs/DESIGN.md` when a
  decision changes, re-exports and step ceilings, then pushes to `main`.
- **Dependencies** by registry version only (`rapier2d` pre-release pinned exactly); a bump is its own lot and re-pins
  the proven program on Sepolia when its hash changes (contract v2: `pin_program` with a grace period).
- **Escalations** to the project manager go through `docs/PLAN.md` first, then one message; never sideways to
  sibling repositories.

## The Codex review on this track

The standard says how a review is asked, read and answered (skill `nexus-agents`). Specific to this track:

- Launch: `nexus review --project slingfall --task <id> --repository slingfall --branch feat/<id> --brief docs/briefs/<id>.md`,
  then `nexus wait slingfall/review-<id>` as a background task titled with the reviewer's model.
- A `minor` finding may be deferred only with an entry in `docs/PLAN.md`; a fix is made by resuming the executor,
  which fixes what it is given and nothing else.
- Never merged without the review: a lot that touches the rules, the replay, the contract, a proof or a deployment.
  A merge without the review (documents, briefs, plan) says `Codex review: none — <reason>` in the pull request.
