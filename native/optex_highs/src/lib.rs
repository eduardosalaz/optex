//! The HiGHS binding: one dirty NIF that hands a fully-formed model to HiGHS
//! via Highs_passModel and returns status + objective + primal values.
//!
//! Safety requirements (each prevents a VM-wide crash or a leak):
//! 1. every array length is validated before any pointer crosses into C;
//! 2. the Highs instance is destroyed on every exit path after creation;
//! 3. output buffers are preallocated to their exact size;
//! 4. input Vecs stay owned by `input`/locals for the whole call, so the
//!    pointers handed to HiGHS remain valid while it copies them.

use rustler::{Atom, NifResult, NifStruct, Term};

mod atoms {
    rustler::atoms! { min, max, infinity, neg_infinity }
}

/// A bound that is either a concrete number or symbolic infinity. The neutral
/// Elixir layer passes :infinity/:neg_infinity through unchanged; the concrete
/// value is substituted here, from HiGHS's own Highs_getInfinity.
#[derive(Clone, Copy)]
enum Bound {
    Num(f64),
    PosInf,
    NegInf,
}

impl<'a> rustler::Decoder<'a> for Bound {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        if let Ok(f) = term.decode::<f64>() {
            return Ok(Bound::Num(f));
        }
        if let Ok(i) = term.decode::<i64>() {
            return Ok(Bound::Num(i as f64));
        }
        let a: Atom = term.decode()?;
        if a == atoms::infinity() {
            Ok(Bound::PosInf)
        } else if a == atoms::neg_infinity() {
            Ok(Bound::NegInf)
        } else {
            Err(rustler::Error::BadArg)
        }
    }
}

// NifStruct derives both directions; encoding restores the symbolic form.
impl rustler::Encoder for Bound {
    fn encode<'a>(&self, env: rustler::Env<'a>) -> Term<'a> {
        match self {
            Bound::Num(f) => rustler::Encoder::encode(f, env),
            Bound::PosInf => rustler::Encoder::encode(&atoms::infinity(), env),
            Bound::NegInf => rustler::Encoder::encode(&atoms::neg_infinity(), env),
        }
    }
}

impl Bound {
    fn resolve(self, inf: f64) -> f64 {
        match self {
            Bound::Num(f) => f,
            Bound::PosInf => inf,
            Bound::NegInf => -inf,
        }
    }
}

#[derive(NifStruct)]
#[module = "Optex.SolverInput"]
struct SolverInput {
    num_vars: i32,
    num_cons: i32,
    sense: Atom,
    obj: Vec<f64>,
    col_lb: Vec<Bound>,
    col_ub: Vec<Bound>,
    col_type: Vec<i32>, // pre-mapped HiGHS vartype ints (binding-layer mapping)
    col_start: Vec<i32>,
    row_index: Vec<i32>,
    values: Vec<f64>,
    row_lb: Vec<Bound>,
    row_ub: Vec<Bound>,
}

/// Solver options pre-grouped by HiGHS value type on the Elixir side; the
/// binding module owns the neutral-name to HiGHS-name mapping.
#[derive(NifStruct)]
#[module = "Optex.Solver.HiGHS.Options"]
struct SolveOptions {
    bool_opts: Vec<(String, bool)>,
    int_opts: Vec<(String, i32)>,
    double_opts: Vec<(String, f64)>,
}

#[derive(NifStruct)]
#[module = "Optex.SolveResult"]
struct SolveResult {
    status: i32, // raw kHighsModelStatus; decoded on the Elixir side
    objective: f64,
    values: Vec<f64>,
    col_duals: Vec<f64>, // reduced costs; meaningful only when dual_status says so
    row_duals: Vec<f64>, // constraint duals; same caveat
    dual_status: i32,    // raw kHighsSolutionStatus; decoded on the Elixir side
}

#[rustler::nif(schedule = "DirtyCpu")]
fn solve(input: SolverInput, options: SolveOptions) -> Result<SolveResult, String> {
    if input.num_vars < 0 || input.num_cons < 0 {
        return Err("negative dimension".into());
    }

    let n = input.num_vars as usize;
    let m = input.num_cons as usize;
    let nnz = input.values.len();

    // (1) length firewall - before any unsafe pointer use. HiGHS reads exactly
    // num_col/num_row/num_nz elements with no bounds checking of its own.
    if input.obj.len() != n
        || input.col_lb.len() != n
        || input.col_ub.len() != n
        || input.col_type.len() != n
        || input.col_start.len() != n + 1
        || input.row_index.len() != nnz
        || input.row_lb.len() != m
        || input.row_ub.len() != m
        || input.col_start.last().copied() != Some(nnz as i32)
    {
        return Err("array length mismatch".into());
    }

    unsafe {
        let highs = highs_sys::Highs_create();
        if highs.is_null() {
            return Err("Highs_create failed".into());
        }

        let inf = highs_sys::Highs_getInfinity(highs);

        // substitute symbolic infinities with HiGHS's own value; these Vecs
        // (and input's) live until the end of this call - requirement (4)
        let col_lb: Vec<f64> = input.col_lb.iter().map(|b| b.resolve(inf)).collect();
        let col_ub: Vec<f64> = input.col_ub.iter().map(|b| b.resolve(inf)).collect();
        let row_lb: Vec<f64> = input.row_lb.iter().map(|b| b.resolve(inf)).collect();
        let row_ub: Vec<f64> = input.row_ub.iter().map(|b| b.resolve(inf)).collect();

        // silence solver logging by default; user options applied afterwards
        // may turn it back on
        if let Ok(flag) = std::ffi::CString::new("output_flag") {
            highs_sys::Highs_setBoolOptionValue(highs, flag.as_ptr(), 0);
        }

        for (name, value) in &options.bool_opts {
            match std::ffi::CString::new(name.as_str()) {
                Ok(c) if highs_sys::Highs_setBoolOptionValue(highs, c.as_ptr(), *value as i32)
                    != highs_sys::STATUS_ERROR => {}
                _ => {
                    highs_sys::Highs_destroy(highs); // (2)
                    return Err(format!("invalid solver option {name}"));
                }
            }
        }

        for (name, value) in &options.int_opts {
            match std::ffi::CString::new(name.as_str()) {
                Ok(c) if highs_sys::Highs_setIntOptionValue(highs, c.as_ptr(), *value)
                    != highs_sys::STATUS_ERROR => {}
                _ => {
                    highs_sys::Highs_destroy(highs); // (2)
                    return Err(format!("invalid solver option {name}"));
                }
            }
        }

        for (name, value) in &options.double_opts {
            match std::ffi::CString::new(name.as_str()) {
                Ok(c) if highs_sys::Highs_setDoubleOptionValue(highs, c.as_ptr(), *value)
                    != highs_sys::STATUS_ERROR => {}
                _ => {
                    highs_sys::Highs_destroy(highs); // (2)
                    return Err(format!("invalid solver option {name}"));
                }
            }
        }

        let sense = if input.sense == atoms::min() {
            highs_sys::OBJECTIVE_SENSE_MINIMIZE
        } else {
            highs_sys::OBJECTIVE_SENSE_MAXIMIZE
        };

        let status = highs_sys::Highs_passModel(
            highs,
            input.num_vars,
            input.num_cons,
            nnz as i32,
            0, // q_num_nz
            highs_sys::MATRIX_FORMAT_COLUMN_WISE,
            0, // q_format
            sense,
            0.0, // offset
            input.obj.as_ptr(),
            col_lb.as_ptr(),
            col_ub.as_ptr(),
            row_lb.as_ptr(),
            row_ub.as_ptr(),
            input.col_start.as_ptr(),
            input.row_index.as_ptr(),
            input.values.as_ptr(),
            std::ptr::null(), // q_start
            std::ptr::null(), // q_index
            std::ptr::null(), // q_value
            input.col_type.as_ptr(),
        );

        // kHighsStatus: 0 ok, 1 warning, -1 error. A warning still leaves a
        // usable model/solution; only a hard error aborts.
        if status == highs_sys::STATUS_ERROR {
            highs_sys::Highs_destroy(highs); // (2) free on error
            return Err("passModel failed".into());
        }

        let run_status = highs_sys::Highs_run(highs);
        if run_status == highs_sys::STATUS_ERROR {
            highs_sys::Highs_destroy(highs); // (2)
            return Err("run failed".into());
        }

        let model_status = highs_sys::Highs_getModelStatus(highs);

        // (3) preallocate to exact size; row_value is unused, pass null
        let mut col_value = vec![0.0_f64; n];
        let mut col_dual = vec![0.0_f64; n];
        let mut row_dual = vec![0.0_f64; m];
        highs_sys::Highs_getSolution(
            highs,
            col_value.as_mut_ptr(),
            col_dual.as_mut_ptr(),
            std::ptr::null_mut(),
            row_dual.as_mut_ptr(),
        );

        // kHighsSolutionStatus for the dual arrays: 0 none, 1 infeasible,
        // 2 feasible. MIPs have no duals; the Elixir side gates on this.
        let mut dual_status = 0_i32;
        if let Ok(info) = std::ffi::CString::new("dual_solution_status") {
            highs_sys::Highs_getIntInfoValue(highs, info.as_ptr(), &mut dual_status);
        }

        let mut objective = 0.0_f64;
        if let Ok(info) = std::ffi::CString::new("objective_function_value") {
            highs_sys::Highs_getDoubleInfoValue(highs, info.as_ptr(), &mut objective);
        }

        highs_sys::Highs_destroy(highs); // (2) free on success

        Ok(SolveResult {
            status: model_status,
            objective,
            values: col_value,
            col_duals: col_dual,
            row_duals: row_dual,
            dual_status,
        })
    }
}

rustler::init!("Elixir.Optex.Solver.HiGHS.Native");
