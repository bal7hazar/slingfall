//! wasm-bindgen surface (client/vm/README.md):
//! `new Runner(executableJson)`, `runner.run(args, { reserveCells, onPrint })`
//! -> `{ steps, memoryCells, returned }`; `wasmMemoryBytes()`.
use js_sys::{Array, Function, Object, Reflect};
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;

fn js_err(e: String) -> JsError {
    JsError::new(&e)
}

fn set(obj: &Object, key: &str, value: JsValue) -> Result<(), JsError> {
    Reflect::set(obj, &key.into(), &value)
        .map(|_| ())
        .map_err(|_| JsError::new("cannot build the report"))
}

/// A loaded executable; one per worker, reused by every run.
#[wasm_bindgen]
pub struct Runner {
    loaded: crate::Loaded,
}

#[wasm_bindgen]
impl Runner {
    /// Parses `executable.json` (the text of scarb's `target/dev/<name>.executable.json`).
    #[wasm_bindgen(constructor)]
    pub fn new(executable_json: &str) -> Result<Runner, JsError> {
        Ok(Runner {
            loaded: crate::load(executable_json).map_err(js_err)?,
        })
    }

    /// Runs `main` once. `args`: whitespace-separated decimal felts (negative = `P - x`).
    /// `options.reserveCells` (number, default 0) pre-sizes the execution segment;
    /// `options.onPrint(text)` is called synchronously for every `println!`.
    /// Returns `{ steps, memoryCells, execCells, execCapacity, returned: string[] }`, `returned`
    /// being `main`'s `Array<felt252>` as decimal felts.
    pub fn run(&self, args: &str, options: &JsValue) -> Result<Object, JsError> {
        let args = crate::parse_args(args).map_err(js_err)?;
        let (reserve_cells, on_print) = if options.is_object() {
            let reserve = Reflect::get(options, &"reserveCells".into())
                .ok()
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0);
            let print = Reflect::get(options, &"onPrint".into())
                .ok()
                .and_then(|v| v.dyn_into::<Function>().ok());
            (reserve.max(0.0) as usize, print)
        } else {
            (0, None)
        };
        let mut cb = |f: &[crate::Felt252]| {
            if let Some(print) = &on_print {
                let _ = print.call1(
                    &JsValue::NULL,
                    &JsValue::from_str(&crate::felts_to_debug(f)),
                );
            }
        };
        let r = crate::run(
            &self.loaded,
            args,
            crate::RunOpts { reserve_cells },
            &mut cb,
        )
        .map_err(js_err)?;
        let returned: Array = crate::returned_array(&r.output)
            .map_err(js_err)?
            .iter()
            .map(|f| JsValue::from_str(&f.to_string()))
            .collect();
        let report = Object::new();
        set(&report, "steps", (r.steps as f64).into())?;
        set(&report, "memoryCells", (r.memory_cells as f64).into())?;
        set(&report, "execCells", (r.exec_segment.0 as f64).into())?;
        set(&report, "execCapacity", (r.exec_segment.1 as f64).into())?;
        set(&report, "returned", returned.into())?;
        Ok(report)
    }

    /// Felts of bytecode in the loaded program.
    #[wasm_bindgen(getter, js_name = bytecodeLen)]
    pub fn bytecode_len(&self) -> usize {
        self.loaded.bytecode_len
    }
}

/// Size of this instance's linear memory, in bytes (it only grows: the peak so far).
#[wasm_bindgen(js_name = wasmMemoryBytes)]
pub fn wasm_memory_bytes() -> f64 {
    (core::arch::wasm32::memory_size(0) * 65536) as f64
}
