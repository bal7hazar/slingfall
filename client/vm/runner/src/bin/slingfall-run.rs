//! Native driver: `slingfall-run <executable.json> "<args>" [--reserve=CELLS] [--quiet-prints]`.
//! Prints every `println!`, then `returned: <felts>` (main's `Array<felt252>`, decimal, one line)
//! and a summary on stderr. Used to cross-check the wasm build and to regenerate golden states.
use std::time::Instant;

use slingfall_vm_runner::{
    felts_to_debug, load, parse_args, returned_array, run, Felt252, RunOpts,
};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 {
        eprintln!(
            "usage: slingfall-run <executable.json> \"<args>\" [--reserve=CELLS] [--quiet-prints]"
        );
        std::process::exit(64);
    }
    let quiet = a.iter().any(|x| x == "--quiet-prints");
    let reserve_cells = a
        .iter()
        .find_map(|x| x.strip_prefix("--reserve="))
        .map(|v| v.parse().expect("--reserve=CELLS"))
        .unwrap_or(0);
    let t0 = Instant::now();
    let json = std::fs::read_to_string(&a[1]).expect("read the executable");
    let loaded = load(&json).expect("load");
    drop(json);
    let t_load = t0.elapsed();
    let args = parse_args(&a[2]).expect("args");
    let mut prints = 0usize;
    let t1 = Instant::now();
    let mut on_print = |f: &[Felt252]| {
        prints += 1;
        if !quiet {
            println!("{}", felts_to_debug(f));
        }
    };
    let r = run(&loaded, args, RunOpts { reserve_cells }, &mut on_print).expect("run");
    let t_run = t1.elapsed();
    let returned = returned_array(&r.output).expect("output");
    println!(
        "returned: {}",
        returned
            .iter()
            .map(|f| f.to_string())
            .collect::<Vec<_>>()
            .join(" ")
    );
    eprintln!(
        "bytecode {} felts | load {:.3}s | run {:.3}s | steps {} | {:.2}M steps/s | prints {} | memory cells {} | exec segment {:?}",
        loaded.bytecode_len,
        t_load.as_secs_f64(),
        t_run.as_secs_f64(),
        r.steps,
        r.steps as f64 / t_run.as_secs_f64() / 1e6,
        prints,
        r.memory_cells,
        r.exec_segment,
    );
}
