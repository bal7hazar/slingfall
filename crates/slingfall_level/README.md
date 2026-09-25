# slingfall_level

The level format of Slingfall: the `Level` a replay runs (materials, bodies, sling, bounds), the
player's `Inputs` (one quantised pull per shot), the 10-felt `Outputs` a proof commits to, and the
Poseidon hashes `level_hash` / `inputs_hash` over their `Serde` felt layouts (`docs/DESIGN.md`
D2-D4). Pure Cairo, no `starknet` dependency. Modules `level`, `inputs`, `outputs`, `hash`,
`errors` are stubs until lot G2. Test: `snforge test -p slingfall_level`.
