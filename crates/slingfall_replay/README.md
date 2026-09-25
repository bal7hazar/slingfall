# slingfall_replay

The replay executables (`docs/DESIGN.md` D1): the proof build `main(level, inputs) -> outputs`, the
trace build `main_trace` whose observer prints poses and events for the client, and the chunked
build `init` / `step_chunk` on `rapier2d::WorldState` that the browser worker runs. A nested
package with its own `[workspace]`, outside the root one: executables need `enable-gas = false`,
which `snforge` refuses, so tests run under the gas-enabled `snforge` profile. Modules `main`,
`trace`, `chunk` are stubs until lot G4 (`main` returns no outputs). From this directory:
`scarb build`, `scarb execute --arguments 0,0 --print-program-output`,
`snforge test --profile snforge`.
