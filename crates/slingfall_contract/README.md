# slingfall_contract

The Starknet contract (`docs/DESIGN.md` D9): the level registry, `simulate(level_hash, inputs)`
executed in the SNIP-36 virtual OS and emitting the outputs as an L2 to L1 message, `submit` which
checks the proof facts, `player == caller` and the nullifier before recording the best score, and
the `Verifier` interface stubbed until lot E2. The only crate that depends on `starknet`. Modules
`registry`, `simulate`, `submit`, `verifier` are stubs until lot G7. Test:
`snforge test -p slingfall_contract`.
