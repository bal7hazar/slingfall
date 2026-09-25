//! Runs a scarb 2.19 `executable.json` (CASM + hints) on cairo-vm 3.2, natively and in wasm32.
//!
//! Promoted from the spike `pm/spikes/wasm-vm/g1-runner` (docs/research/03 and 04).
//! `cairo1-run` cannot be used: it compiles Sierra with cairo-lang 2.12, which rejects scarb
//! 2.19's Sierra. The executable artifact is already CASM, so only a hint processor is needed:
//! core hints go to cairo-vm's `Cairo1HintProcessor`; the executable wrapper's hints
//! (`WriteRunParam`, `AddMarker`, `AddRelocationRule`) and `DebugPrint` (`println!`) are handled
//! here. `DebugPrint` is forwarded to a callback: the streaming hook.

use std::any::Any;
use std::collections::HashMap;
use std::sync::Arc;

use cairo_lang_casm::hints::Hint;
use cairo_lang_casm::operand::{CellRef, DerefOrImmediate, Operation, Register, ResOperand};
use cairo_vm::hint_processor::cairo_1_hint_processor::hint_processor::Cairo1HintProcessor;
use cairo_vm::hint_processor::hint_processor_definition::{HintProcessorLogic, HintReference};
use cairo_vm::serde::deserialize_program::{
    ApTracking, FlowTrackingData, HintParams, ReferenceManager,
};
use cairo_vm::types::builtin_name::BuiltinName;
use cairo_vm::types::exec_scope::ExecutionScopes;
use cairo_vm::types::layout_name::LayoutName;
use cairo_vm::types::program::Program;
use cairo_vm::types::relocatable::{MaybeRelocatable, Relocatable};
use cairo_vm::vm::errors::hint_errors::HintError;
use cairo_vm::vm::errors::vm_errors::VirtualMachineError;
use cairo_vm::vm::errors::vm_exception::VmException;
use cairo_vm::vm::runners::cairo_runner::{CairoRunner, ResourceTracker, RunResources};
use cairo_vm::vm::vm_core::VirtualMachine;
pub use cairo_vm::Felt252;
use serde_json::Value;

#[cfg(target_arch = "wasm32")]
mod wasm;

/// One hint of the executable, split between what cairo-vm handles and what we handle.
#[derive(Clone, Debug)]
enum ExecHint {
    Core(Hint),
    WriteRunParam { index: ResOperand, dst: CellRef },
    AddMarker { start: ResOperand, end: ResOperand },
    AddRelocationRule { src: ResOperand, dst: ResOperand },
    DebugPrint { start: ResOperand, end: ResOperand },
}

/// A parsed executable, reusable across runs.
pub struct Loaded {
    program: Program,
    hints: Vec<(usize, Vec<ExecHint>)>,
    pub bytecode_len: usize,
}

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn field<T: serde::de::DeserializeOwned>(v: &Value, k: &str) -> Result<T, String> {
    serde_json::from_value(v.get(k).cloned().ok_or(format!("missing {k}"))?).map_err(err)
}

fn parse_hint(v: &Value) -> Result<ExecHint, String> {
    let (name, body) = v
        .as_object()
        .and_then(|o| o.iter().next())
        .ok_or("bad hint")?;
    Ok(match name.as_str() {
        "WriteRunParam" => ExecHint::WriteRunParam {
            index: field(body, "index")?,
            dst: field(body, "dst")?,
        },
        "AddMarker" => ExecHint::AddMarker {
            start: field(body, "start")?,
            end: field(body, "end")?,
        },
        "AddRelocationRule" => ExecHint::AddRelocationRule {
            src: field(body, "src")?,
            dst: field(body, "dst")?,
        },
        "DebugPrint" => ExecHint::DebugPrint {
            start: field(body, "start")?,
            end: field(body, "end")?,
        },
        _ => ExecHint::Core(serde_json::from_value(v.clone()).map_err(|e| format!("{name}: {e}"))?),
    })
}

/// Parses a signed hex felt: bytecode immediates may be negative (`"-0xc"`), which
/// `Felt252::from_hex` rejects.
fn felt_from_signed_hex(s: &str) -> Result<Felt252, String> {
    match s.strip_prefix('-') {
        Some(pos) => Felt252::from_hex(pos).map(|f| -f),
        None => Felt252::from_hex(s),
    }
    .map_err(err)
}

/// Parses `executable.json` and builds the program of its `Bootloader` entrypoint (plain
/// execution: `main`'s returned array goes to the output builtin as `[len, values..]`).
pub fn load(json: &str) -> Result<Loaded, String> {
    let v: Value = serde_json::from_str(json).map_err(err)?;
    let prog = &v["program"];
    let data: Vec<MaybeRelocatable> = prog["bytecode"]
        .as_array()
        .ok_or("no bytecode")?
        .iter()
        .map(|x| {
            felt_from_signed_hex(x.as_str().ok_or("bad bytecode")?).map(MaybeRelocatable::from)
        })
        .collect::<Result<_, _>>()?;
    let mut hints = Vec::new();
    let mut hint_params = HashMap::new();
    for entry in prog["hints"].as_array().ok_or("no hints")? {
        let pc = entry[0].as_u64().ok_or("bad pc")? as usize;
        let hs = entry[1]
            .as_array()
            .ok_or("bad hints")?
            .iter()
            .map(parse_hint)
            .collect::<Result<Vec<_>, _>>()?;
        hints.push((pc, hs));
        // The hint "code" is its pc: `compile_hint` looks the parsed hints up by it.
        hint_params.insert(
            pc,
            vec![HintParams {
                code: pc.to_string(),
                accessible_scopes: vec![],
                flow_tracking_data: FlowTrackingData {
                    ap_tracking: ApTracking::default(),
                    reference_ids: HashMap::new(),
                },
            }],
        );
    }
    let ep = v["entrypoints"]
        .as_array()
        .ok_or("no entrypoints")?
        .iter()
        .find(|e| e["kind"] == "Bootloader")
        .ok_or("no Bootloader entrypoint")?;
    let offset = ep["offset"].as_u64().ok_or("bad entrypoint offset")? as usize;
    let builtins: Vec<BuiltinName> = ep["builtins"]
        .as_array()
        .ok_or("bad entrypoint builtins")?
        .iter()
        .map(|b| {
            b.as_str()
                .and_then(BuiltinName::from_str)
                .ok_or("unknown builtin")
        })
        .collect::<Result<_, _>>()?;
    let bytecode_len = data.len();
    let program = Program::new(
        builtins,
        data,
        Some(offset),
        hint_params,
        ReferenceManager { references: vec![] },
        HashMap::new(),
        vec![],
        None,
    )
    .map_err(err)?;
    Ok(Loaded {
        program,
        hints,
        bytecode_len,
    })
}

/// Hint processor: cairo-vm's Cairo 1 processor + the executable-wrapper hints + a print sink.
struct ExecHintProcessor<'a> {
    inner: Cairo1HintProcessor,
    hints: HashMap<usize, Vec<ExecHint>>,
    user_args: Vec<Felt252>,
    markers: Vec<Vec<Felt252>>,
    on_print: &'a mut dyn FnMut(&[Felt252]),
}

fn cell_addr(vm: &VirtualMachine, c: &CellRef) -> Result<Relocatable, HintError> {
    let base = match c.register {
        Register::AP => vm.get_ap(),
        Register::FP => vm.get_fp(),
    };
    Ok((base + c.offset as i32)?)
}

fn get_val(vm: &VirtualMachine, r: &ResOperand) -> Result<MaybeRelocatable, HintError> {
    let cell = |c: &CellRef| -> Result<MaybeRelocatable, HintError> {
        let a = cell_addr(vm, c)?;
        vm.get_maybe(&a).ok_or_else(|| {
            HintError::from(VirtualMachineError::InvalidMemoryValueTemporaryAddress(
                Box::new(a),
            ))
        })
    };
    Ok(match r {
        ResOperand::Deref(c) => cell(c)?,
        ResOperand::Immediate(x) => MaybeRelocatable::from(Felt252::from(&x.value)),
        ResOperand::BinOp(op) => {
            let a = cell(&op.a)?;
            let b = match &op.b {
                DerefOrImmediate::Deref(c) => cell(c)?,
                DerefOrImmediate::Immediate(x) => MaybeRelocatable::from(Felt252::from(&x.value)),
            };
            match op.op {
                Operation::Add => a
                    .add(&b)
                    .map_err(|e| HintError::CustomHint(e.to_string().into()))?,
                Operation::Mul => {
                    let (MaybeRelocatable::Int(a), MaybeRelocatable::Int(b)) = (a, b) else {
                        return Err(HintError::CustomHint("mul on pointers".into()));
                    };
                    MaybeRelocatable::from(a * b)
                }
            }
        }
        ResOperand::DoubleDeref(c, off) => {
            let p = vm.get_relocatable(cell_addr(vm, c)?)?;
            let a = (p + *off as i32)?;
            vm.get_maybe(&a)
                .ok_or(HintError::CustomHint("double deref".into()))?
        }
    })
}

fn get_ptr(vm: &VirtualMachine, r: &ResOperand) -> Result<Relocatable, HintError> {
    match get_val(vm, r)? {
        MaybeRelocatable::RelocatableValue(p) => Ok(p),
        _ => Err(HintError::CustomHint("expected pointer".into())),
    }
}

fn read_felts(
    vm: &VirtualMachine,
    start: &ResOperand,
    end: &ResOperand,
) -> Result<Vec<Felt252>, HintError> {
    let (mut s, e) = (get_ptr(vm, start)?, get_ptr(vm, end)?);
    let mut out = vec![];
    while s != e {
        out.push(*vm.get_integer(s)?);
        s += 1;
    }
    Ok(out)
}

impl ExecHintProcessor<'_> {
    fn exec(
        &mut self,
        vm: &mut VirtualMachine,
        scopes: &mut ExecutionScopes,
        h: &ExecHint,
    ) -> Result<(), HintError> {
        match h {
            ExecHint::Core(h) => self.inner.execute(vm, scopes, h),
            ExecHint::WriteRunParam { index, dst } => {
                // `user_args = [[Array(args)]]` as in cairo-execute: index 0 is one array
                // argument, written as (start, end) of a fresh segment holding the felts.
                if get_val(vm, index)? != MaybeRelocatable::from(0) {
                    return Err(HintError::CustomHint("only run param 0 supported".into()));
                }
                let seg = vm.add_memory_segment();
                for (i, a) in self.user_args.iter().enumerate() {
                    vm.insert_value((seg + i)?, *a)?;
                }
                let d = cell_addr(vm, dst)?;
                vm.insert_value(d, seg)?;
                vm.insert_value((d + 1)?, (seg + self.user_args.len())?)?;
                Ok(())
            }
            ExecHint::AddMarker { start, end } => {
                let m = read_felts(vm, start, end)?;
                self.markers.push(m);
                Ok(())
            }
            ExecHint::AddRelocationRule { src, dst } => {
                let (s, d) = (get_ptr(vm, src)?, get_ptr(vm, dst)?);
                vm.add_relocation_rule(s, d)?;
                Ok(())
            }
            ExecHint::DebugPrint { start, end } => {
                let felts = read_felts(vm, start, end)?;
                (self.on_print)(&felts);
                Ok(())
            }
        }
    }
}

impl HintProcessorLogic for ExecHintProcessor<'_> {
    fn compile_hint(
        &self,
        hint_code: &str,
        _: &ApTracking,
        _: &HashMap<String, usize>,
        _: &[HintReference],
        _: &[String],
        _: Arc<HashMap<String, Felt252>>,
    ) -> Result<Box<dyn Any>, VirtualMachineError> {
        let pc: usize = hint_code
            .parse()
            .map_err(|_| VirtualMachineError::Unexpected)?;
        let hs = self
            .hints
            .get(&pc)
            .cloned()
            .ok_or(VirtualMachineError::Unexpected)?;
        Ok(Box::new(hs))
    }

    fn execute_hint(
        &mut self,
        vm: &mut VirtualMachine,
        scopes: &mut ExecutionScopes,
        data: &Box<dyn Any>,
    ) -> Result<(), HintError> {
        let hs: &Vec<ExecHint> = data.downcast_ref().ok_or(HintError::WrongHintData)?;
        for h in hs {
            self.exec(vm, scopes, h)?;
        }
        Ok(())
    }
}

impl ResourceTracker for ExecHintProcessor<'_> {}

/// What one run produced.
pub struct RunReport {
    /// Cairo steps (the entry-point wrapper included; `scarb execute` reports 3 more).
    pub steps: usize,
    /// Output builtin contents: `[len, values..]` (a Cairo panic aborts the run instead).
    pub output: Vec<Felt252>,
    /// Cells used across all segments (effective sizes).
    pub memory_cells: usize,
    /// `(len, capacity)` of the execution segment at the end of the run, in cells.
    pub exec_segment: (usize, usize),
}

/// Run options.
#[derive(Clone, Copy, Debug, Default)]
pub struct RunOpts {
    /// Cells to reserve in the execution segment before running, so that it grows without
    /// `Vec` doubling copies (docs/research/04: +13 % steps/s, 710 -> 320 MB); 0 = none.
    pub reserve_cells: usize,
}

/// Runs `loaded` in execution mode with `args`, the felts of `main`'s single `Array<felt252>`
/// run parameter (for `main(a: u8, .., s: Array<felt252>)`: the flattened `Serde` form).
/// `on_print` receives the raw felts of every `println!`.
pub fn run(
    loaded: &Loaded,
    args: Vec<Felt252>,
    opts: RunOpts,
    on_print: &mut dyn FnMut(&[Felt252]),
) -> Result<RunReport, String> {
    let core: Vec<(usize, Vec<Hint>)> = loaded
        .hints
        .iter()
        .map(|(pc, hs)| {
            let core = hs.iter().filter_map(|h| {
                if let ExecHint::Core(c) = h {
                    Some(c.clone())
                } else {
                    None
                }
            });
            (*pc, core.collect())
        })
        .collect();
    let mut hp = ExecHintProcessor {
        // `true`: dictionaries after the first live in temporary segments, as in
        // cairo-lang-runner; the wrapper's segment-arena loop relocates them with
        // `AddRelocationRule` (with `false` that hint fails).
        inner: Cairo1HintProcessor::new(&core, RunResources::default(), true),
        hints: loaded.hints.iter().cloned().collect(),
        user_args: args,
        markers: vec![],
        on_print,
    };
    // `cairo_run_program` inlined, so that the execution segment can be reserved between
    // `initialize` and `run_until_pc`.
    let mut runner = CairoRunner::new(
        &loaded.program,
        LayoutName::all_cairo,
        None,
        false,
        false,
        false,
    )
    .map_err(err)?;
    let end = runner.initialize(false).map_err(err)?;
    if opts.reserve_cells > 0
        && !runner
            .vm
            .segments
            .memory
            .reserve_segment(1, opts.reserve_cells)
    {
        return Err(format!("cannot reserve {} cells", opts.reserve_cells));
    }
    if let Err(e) = runner.run_until_pc(end, &mut hp) {
        let panic = hp
            .markers
            .last()
            .map(|m| format!(" panic data: {}", felts_to_debug(m)))
            .unwrap_or_default();
        return Err(format!("{}{panic}", VmException::from_vm_error(&runner, e)));
    }
    runner.end_run(false, false, &mut hp, false).map_err(err)?;
    runner.read_return_values(false).map_err(err)?;
    cairo_vm::vm::security::verify_secure_runner(&runner, true, None).map_err(err)?;

    let steps = runner.get_execution_resources().map_err(err)?.n_steps;
    let mut out = String::new();
    runner.vm.write_output(&mut out).map_err(err)?;
    let output = out
        .lines()
        .map(|l| {
            l.trim()
                .parse::<num_bigint::BigInt>()
                .map(|b| Felt252::from(&b))
                .map_err(err)
        })
        .collect::<Result<_, _>>()?;
    let memory_cells = runner.vm.segments.compute_effective_sizes().iter().sum();
    let exec_segment = runner
        .vm
        .segments
        .memory
        .segment_capacities()
        .get(1)
        .copied()
        .unwrap_or_default();
    Ok(RunReport {
        steps,
        output,
        memory_cells,
        exec_segment,
    })
}

/// Decodes a `println!` payload (serialized `ByteArray`, cairo-lang's debug format) to text;
/// felts outside a `ByteArray` are written in decimal, followed by a space.
pub fn felts_to_debug(felts: &[Felt252]) -> String {
    const MAGIC: &str = "0x46a6158a16a947e5916b2a2ca68501a45e93d7110e81aa2d6438b1c57c879a3";
    let mut s = String::new();
    let mut i = 0;
    while i < felts.len() {
        if felts[i].to_hex_string() == MAGIC && i + 1 < felts.len() {
            let n = felts[i + 1].to_biguint().try_into().unwrap_or(0usize);
            let mut bytes = vec![];
            for w in &felts[i + 2..(i + 2 + n).min(felts.len())] {
                bytes.extend_from_slice(&w.to_bytes_be()[1..]);
            }
            if let (Some(pw), Some(pl)) = (felts.get(i + 2 + n), felts.get(i + 3 + n)) {
                let pl: usize = pl.to_biguint().try_into().unwrap_or(0).min(31);
                bytes.extend_from_slice(&pw.to_bytes_be()[32 - pl..]);
            }
            s.push_str(&String::from_utf8_lossy(&bytes));
            i += 4 + n;
        } else {
            s.push_str(&format!("{} ", felts[i]));
            i += 1;
        }
    }
    s
}

/// Parses whitespace-separated decimal felts; a leading `-` means `P - x` (Cairo's encoding of
/// negative integers, e.g. a raw Q32.32 `i64`).
pub fn parse_args(s: &str) -> Result<Vec<Felt252>, String> {
    s.split_whitespace()
        .map(|x| {
            let (negative, digits) = x.strip_prefix('-').map_or((false, x), |d| (true, d));
            if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                return Err(format!("not a decimal felt: {x:?}"));
            }
            let f = Felt252::from_dec_str(digits).map_err(err)?;
            Ok(if negative { -f } else { f })
        })
        .collect()
}

/// The `Array<felt252>` returned by `main`: the Bootloader entrypoint writes `[len, values..]`
/// to the output builtin.
pub fn returned_array(output: &[Felt252]) -> Result<Vec<Felt252>, String> {
    let len = output
        .first()
        .and_then(|l| usize::try_from(l.to_biguint()).ok())
        .ok_or("empty output")?;
    if output.len() != len + 1 {
        return Err(format!("output length {} != 1 + {len}", output.len()));
    }
    Ok(output[1..].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_args_accepts_negative_felts() {
        let felts = parse_args("  3 -1 0\t-4294967296 7\n").unwrap();
        assert_eq!(
            felts,
            vec![
                Felt252::from(3),
                -Felt252::ONE,
                Felt252::ZERO,
                -Felt252::from(4294967296u64),
                Felt252::from(7)
            ]
        );
        // `-x` is `P - x`: the raw i64 of a negative Q32.32 round-trips through the felt.
        assert_eq!(felts[1] + Felt252::ONE, Felt252::ZERO);
        assert_eq!(
            felts[3].to_string(),
            (-Felt252::from(4294967296u64)).to_string()
        );
        assert_eq!(parse_args("").unwrap(), vec![]);
    }

    #[test]
    fn parse_args_accepts_felts_up_to_p_minus_one() {
        let p_minus_1 =
            "3618502788666131213697322783095070105623107215331596699973092056135872020480";
        assert_eq!(parse_args(p_minus_1).unwrap(), vec![-Felt252::ONE]);
    }

    #[test]
    fn parse_args_rejects_garbage() {
        assert!(parse_args("1 x 2").is_err());
        assert!(parse_args("--1").is_err());
        assert!(parse_args("0x10").is_err());
    }

    #[test]
    fn signed_hex_immediates() {
        assert_eq!(felt_from_signed_hex("-0xc").unwrap(), -Felt252::from(12));
        assert_eq!(felt_from_signed_hex("0x10").unwrap(), Felt252::from(16));
    }

    #[test]
    fn returned_array_strips_the_length() {
        let out = [Felt252::from(2), Felt252::from(5), -Felt252::ONE];
        assert_eq!(
            returned_array(&out).unwrap(),
            vec![Felt252::from(5), -Felt252::ONE]
        );
        assert!(returned_array(&out[..2]).is_err());
        assert!(returned_array(&[]).is_err());
    }

    #[test]
    fn debug_print_decodes_a_byte_array() {
        // `println!("tick 1 y -5")`: magic, 0 full words, pending word, pending length.
        let text = b"tick 1 y -5";
        let magic =
            Felt252::from_hex("0x46a6158a16a947e5916b2a2ca68501a45e93d7110e81aa2d6438b1c57c879a3")
                .unwrap();
        let pending = Felt252::from_bytes_be_slice(text);
        let felts = [magic, Felt252::ZERO, pending, Felt252::from(text.len())];
        assert_eq!(felts_to_debug(&felts), "tick 1 y -5");
    }
}
