//! `slingfall_replay::main::main` for `cairo1-run --append_return_values` (lot E3a, the Atlantic
//! lane): `cairo1-run` only proves a `main` of one `Array<felt252>` returning `Array<felt252>`.
//! The argument is the felts of `main`'s two arguments, `[len(L), L..., len(I), I...]` (what
//! `tracec.py args` writes); the return value is the 10 felts of `Outputs`. The public output of
//! the run is `[0, 10, outputs..., len(args), args...]` (panic flag, return value, then the
//! argument).

use slingfall_game::errors;
use slingfall_game::play::{NoopObserver, decode, play};
use slingfall_level::inputs::Inputs;
use slingfall_level::level::Level;
use slingfall_level::outputs::OutputsTrait;

fn main(args: Array<felt252>) -> Array<felt252> {
    let mut span = args.span();
    let level: Array<felt252> = Serde::deserialize(ref span).expect(errors::LEVEL);
    let inputs: Array<felt252> = Serde::deserialize(ref span).expect(errors::INPUTS);
    assert(span.is_empty(), errors::INPUTS);
    let level: Level = decode(level.span(), errors::LEVEL);
    let inputs: Inputs = decode(inputs.span(), errors::INPUTS);
    let mut obs: NoopObserver = Default::default();
    play(@level, @inputs, ref obs).to_felts()
}
