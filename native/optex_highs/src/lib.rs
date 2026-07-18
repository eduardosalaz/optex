//! The HiGHS binding: dirty NIFs that hand a fully-formed model to HiGHS
//! via Highs_passModel and return solutions, statistics, and diagnostics.
//!
//! Safety requirements (each prevents a VM-wide crash or a leak):
//! 1. every array length is validated before any pointer crosses into C;
//! 2. the Highs instance is destroyed on every exit path after creation;
//! 3. output buffers are preallocated to their exact (or exact-upper-bound)
//!    size;
//! 4. input Vecs and the callback context stay owned by locals for the whole
//!    call, so pointers handed to HiGHS remain valid while it uses them.

use rustler::{Atom, Encoder, LocalPid, NifResult, NifStruct, OwnedEnv, Resource, ResourceArc, Term};
use std::sync::atomic::{AtomicBool, Ordering};

mod atoms {
    rustler::atoms! { min, max, infinity, neg_infinity, ok, optex_highs_log, le, ge, eq }
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

/// Cooperative cancellation flag for a running solve. Created before the
/// solve, held by the caller; the HiGHS interrupt callback polls it.
pub struct CancelToken {
    flag: AtomicBool,
}

#[rustler::resource_impl]
impl Resource for CancelToken {}

/// Wire form of a native indicator row; HiGHS cannot solve these, so the
/// binding rejects any input carrying them (the Elixir layer already does;
/// this is the firewall backstop).
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Indicator"]
struct IndicatorRow {
    bin_col: i32,
    active_value: i32,
    cols: Vec<i32>,
    coefs: Vec<f64>,
    sense: Atom,
    rhs: f64,
}

#[derive(NifStruct)]
#[module = "Optex.SolverInput"]
struct SolverInput {
    num_vars: i32,
    num_cons: i32,
    sense: Atom,
    obj: Vec<f64>,
    obj_offset: f64,
    col_lb: Vec<Bound>,
    col_ub: Vec<Bound>,
    col_type: Vec<i32>, // pre-mapped HiGHS vartype ints (binding-layer mapping)
    col_start: Vec<i32>,
    row_index: Vec<i32>,
    values: Vec<f64>,
    row_lb: Vec<Bound>,
    row_ub: Vec<Bound>,
    indicators: Vec<IndicatorRow>,
    abs_defs: Vec<(i32, i32)>,
    pwl_defs: Vec<PwlDef>,
    minmax_defs: Vec<MinMaxDef>,
    cones: Vec<ConeRow>,
    soss: Vec<SosRow>,
    // quadratic objective as COO triplets, literal coefficients, normalized
    // to q_cols[k] <= q_rows[k]
    q_cols: Vec<i32>,
    q_rows: Vec<i32>,
    q_vals: Vec<f64>,
    // quadratic constraints; HiGHS cannot solve these, rejected below
    qconstraints: Vec<QConstraintRow>,
}

#[derive(NifStruct)]
#[module = "Optex.SolverInput.QConstraint"]
struct QConstraintRow {
    lin_cols: Vec<i32>,
    lin_coefs: Vec<f64>,
    q_cols: Vec<i32>,
    q_rows: Vec<i32>,
    q_vals: Vec<f64>,
    sense: Atom,
    rhs: f64,
}

#[derive(NifStruct)]
#[module = "Optex.SolverInput.Pwl"]
struct PwlDef {
    res_col: i32,
    arg_col: i32,
    xs: Vec<f64>,
    ys: Vec<f64>,
}

// HiGHS cannot solve min/max general constraints either; rejected below
#[derive(NifStruct)]
#[module = "Optex.SolverInput.MinMax"]
struct MinMaxDef {
    res_col: i32,
    op: Atom,
    arg_cols: Vec<i32>,
    constant: Option<f64>,
}

// HiGHS has neither cones nor SOS; both are rejected below
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Cone"]
struct ConeRow {
    cone_type: Atom,
    head_cols: Vec<i32>,
    member_cols: Vec<i32>,
}

#[derive(NifStruct)]
#[module = "Optex.SolverInput.Sos"]
struct SosRow {
    sos_type: Atom,
    cols: Vec<i32>,
    weights: Vec<f64>,
}

/// Solver options pre-grouped by HiGHS value type on the Elixir side; the
/// binding module owns the neutral-name to HiGHS-name mapping. log_pid
/// streams solver log lines as messages; cancel is polled by the interrupt
/// callback.
#[derive(NifStruct)]
#[module = "Optex.Solver.HiGHS.Options"]
struct SolveOptions {
    bool_opts: Vec<(String, bool)>,
    int_opts: Vec<(String, i32)>,
    double_opts: Vec<(String, f64)>,
    log_pid: Option<LocalPid>,
    cancel: Option<ResourceArc<CancelToken>>,
}

#[derive(NifStruct)]
#[module = "Optex.SolveResult"]
struct SolveResult {
    status: i32, // raw kHighsModelStatus; decoded on the Elixir side
    // None when HiGHS reports a non-finite value (no incumbent after an
    // interrupt, infeasible, ...); Erlang floats cannot encode infinities
    objective: Option<f64>,
    values: Vec<f64>,
    col_duals: Vec<f64>, // reduced costs; meaningful only when dual_status says so
    row_duals: Vec<f64>, // constraint duals; same caveat
    dual_status: i32,    // raw kHighsSolutionStatus; decoded on the Elixir side
    // always None: HiGHS has no quadratic constraints; the field exists so
    // the shared Optex.SolveResult struct encodes with all keys present
    qcon_duals: Option<Vec<f64>>,
    solve_time: f64,
    simplex_iterations: i32,
    nodes: i64,
    // None when HiGHS reports a non-finite gap (always for pure LPs);
    // Erlang floats cannot encode infinities
    mip_gap: Option<f64>,
}

#[derive(NifStruct)]
#[module = "Optex.IisResult"]
struct IisResult {
    // indices of original columns/rows in the IIS, with their raw
    // IisBoundStatus per member; decoded on the Elixir side. The construct
    // fields exist for the shared struct shape; HiGHS never fills them.
    cols: Vec<i32>,
    col_statuses: Vec<i32>,
    rows: Vec<i32>,
    row_statuses: Vec<i32>,
    indicators: Vec<i32>,
    abs_defs: Vec<i32>,
    minmax_defs: Vec<i32>,
    pwl_defs: Vec<i32>,
    qconstraints: Vec<i32>,
    cones: Vec<i32>,
    soss: Vec<i32>,
}

// kHighsCallback* types, verified against HiGHS 1.15.0 highs_c_api.h.
const CB_LOGGING: i32 = 0;
const CB_SIMPLEX_INTERRUPT: i32 = 1;
const CB_IPM_INTERRUPT: i32 = 2;
const CB_MIP_INTERRUPT: i32 = 6;

/// Owned by the solve NIF's stack frame for the duration of the call (4).
/// Log lines cannot be sent from the callback directly: it runs on the dirty
/// scheduler thread, where rustler forbids OwnedEnv::send_and_clear (and a
/// panic in an extern "C" frame aborts the whole VM). The callback only
/// pushes into the channel; a dedicated unmanaged thread does the sending.
struct CallbackCtx {
    cancel: Option<ResourceArc<CancelToken>>,
    log_tx: Option<std::sync::mpsc::Sender<String>>,
}

/// Spawn the sender thread for streamed log lines. It exits when the ctx
/// (and with it the Sender) is dropped at the end of the solve.
fn spawn_log_sender(pid: LocalPid) -> (std::sync::mpsc::Sender<String>, std::thread::JoinHandle<()>) {
    let (tx, rx) = std::sync::mpsc::channel::<String>();

    let handle = std::thread::spawn(move || {
        while let Ok(line) = rx.recv() {
            let mut env = OwnedEnv::new();
            let _ = env.send_and_clear(&pid, |e| (atoms::optex_highs_log(), line.as_str()).encode(e));
        }
    });

    (tx, handle)
}

/// Runs on HiGHS's solver thread. Only touches the atomic flag, the
/// interrupt field of data_in, and the log channel; must never panic.
unsafe extern "C" fn solve_callback(
    cb_type: std::os::raw::c_int,
    message: *const std::os::raw::c_char,
    _data_out: *const highs_sys::HighsCallbackDataOut,
    data_in: *mut highs_sys::HighsCallbackDataIn,
    user_data: *mut std::os::raw::c_void,
) {
    if user_data.is_null() {
        return;
    }
    let ctx = &*(user_data as *const CallbackCtx);

    match cb_type {
        CB_LOGGING => {
            if let Some(tx) = &ctx.log_tx {
                if !message.is_null() {
                    let text = std::ffi::CStr::from_ptr(message)
                        .to_string_lossy()
                        .trim_end()
                        .to_string();

                    if !text.is_empty() {
                        let _ = tx.send(text);
                    }
                }
            }
        }
        CB_SIMPLEX_INTERRUPT | CB_IPM_INTERRUPT | CB_MIP_INTERRUPT => {
            if let Some(token) = &ctx.cancel {
                if token.flag.load(Ordering::Relaxed) && !data_in.is_null() {
                    (*data_in).user_interrupt = 1;
                }
            }
        }
        _ => {}
    }
}

#[rustler::nif]
fn cancel_token() -> ResourceArc<CancelToken> {
    ResourceArc::new(CancelToken {
        flag: AtomicBool::new(false),
    })
}

#[rustler::nif]
fn cancel(token: ResourceArc<CancelToken>) -> Atom {
    token.flag.store(true, Ordering::Relaxed);
    atoms::ok()
}

// (1) length firewall - before any unsafe pointer use. HiGHS reads exactly
// num_col/num_row/num_nz elements with no bounds checking of its own.
fn validate(input: &SolverInput) -> Result<(usize, usize, usize), String> {
    if input.num_vars < 0 || input.num_cons < 0 {
        return Err("negative dimension".into());
    }

    let n = input.num_vars as usize;
    let m = input.num_cons as usize;
    let nnz = input.values.len();

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

    if !input.indicators.is_empty()
        || !input.abs_defs.is_empty()
        || !input.pwl_defs.is_empty()
        || !input.minmax_defs.is_empty()
        || !input.cones.is_empty()
        || !input.soss.is_empty()
        || !input.qconstraints.is_empty()
    {
        return Err("HiGHS does not support native general or quadratic constraints".into());
    }

    if input.q_cols.len() != input.q_vals.len()
        || input.q_rows.len() != input.q_vals.len()
        || input
            .q_cols
            .iter()
            .zip(input.q_rows.iter())
            .any(|(c, r)| *c < 0 || *r < *c || *r as usize >= n)
        || input.q_vals.iter().any(|v| !v.is_finite())
    {
        return Err("invalid quadratic objective".into());
    }

    Ok((n, m, nnz))
}

// kHighsHessianFormatTriangular, verified against HiGHS 1.15.0
const HESSIAN_FORMAT_TRIANGULAR: i32 = 1;

/// Build the lower-triangular Hessian CSC HiGHS expects. HiGHS's objective
/// convention is c'x + 1/2 x'Qx, so literal coefficients convert as
/// Q_ii = 2*c_ii on the diagonal and Q_ij = c_ij off it (the symmetric pair
/// contributes both halves). q_start has length num_col (not num_col + 1).
fn build_hessian(input: &SolverInput, n: usize) -> (Vec<i32>, Vec<i32>, Vec<f64>) {
    let mut triplets: Vec<(i32, i32, f64)> = input
        .q_cols
        .iter()
        .zip(input.q_rows.iter())
        .zip(input.q_vals.iter())
        .map(|((c, r), v)| (*c, *r, if c == r { 2.0 * v } else { *v }))
        .collect();

    triplets.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));

    let mut start = Vec::with_capacity(n);
    let mut index = Vec::with_capacity(triplets.len());
    let mut value = Vec::with_capacity(triplets.len());
    let mut k = 0usize;

    for col in 0..n as i32 {
        start.push(index.len() as i32);
        while k < triplets.len() && triplets[k].0 == col {
            index.push(triplets[k].1);
            value.push(triplets[k].2);
            k += 1;
        }
    }

    (start, index, value)
}

/// Pass the whole model into a fresh Highs instance. Returns the resolved
/// bound Vecs so the caller keeps them alive as long as it needs (HiGHS
/// copies during passModel, so function scope is sufficient) - requirement
/// (4). On error the instance is already destroyed.
unsafe fn pass_model(
    highs: *mut std::os::raw::c_void,
    input: &SolverInput,
    nnz: usize,
) -> Result<(), String> {
    let inf = highs_sys::Highs_getInfinity(highs);

    let col_lb: Vec<f64> = input.col_lb.iter().map(|b| b.resolve(inf)).collect();
    let col_ub: Vec<f64> = input.col_ub.iter().map(|b| b.resolve(inf)).collect();
    let row_lb: Vec<f64> = input.row_lb.iter().map(|b| b.resolve(inf)).collect();
    let row_ub: Vec<f64> = input.row_ub.iter().map(|b| b.resolve(inf)).collect();

    let sense = if input.sense == atoms::min() {
        highs_sys::OBJECTIVE_SENSE_MINIMIZE
    } else {
        highs_sys::OBJECTIVE_SENSE_MAXIMIZE
    };

    // (4) hessian arrays live for the whole call alongside the bound Vecs
    let (q_start, q_index, q_value) = build_hessian(input, input.num_vars as usize);
    let q_nnz = q_value.len() as i32;

    let status = highs_sys::Highs_passModel(
        highs,
        input.num_vars,
        input.num_cons,
        nnz as i32,
        q_nnz,
        highs_sys::MATRIX_FORMAT_COLUMN_WISE,
        if q_nnz > 0 { HESSIAN_FORMAT_TRIANGULAR } else { 0 },
        sense,
        input.obj_offset,
        input.obj.as_ptr(),
        col_lb.as_ptr(),
        col_ub.as_ptr(),
        row_lb.as_ptr(),
        row_ub.as_ptr(),
        input.col_start.as_ptr(),
        input.row_index.as_ptr(),
        input.values.as_ptr(),
        if q_nnz > 0 { q_start.as_ptr() } else { std::ptr::null() },
        if q_nnz > 0 { q_index.as_ptr() } else { std::ptr::null() },
        if q_nnz > 0 { q_value.as_ptr() } else { std::ptr::null() },
        input.col_type.as_ptr(),
    );

    // kHighsStatus: 0 ok, 1 warning, -1 error. A warning still leaves a
    // usable model; only a hard error aborts.
    if status == highs_sys::STATUS_ERROR {
        highs_sys::Highs_destroy(highs); // (2) free on error
        return Err("passModel failed".into());
    }

    Ok(())
}

unsafe fn silence(highs: *mut std::os::raw::c_void) {
    if let Ok(flag) = std::ffi::CString::new("output_flag") {
        highs_sys::Highs_setBoolOptionValue(highs, flag.as_ptr(), 0);
    }
}

unsafe fn double_info(highs: *mut std::os::raw::c_void, name: &str) -> f64 {
    let mut out = 0.0_f64;
    if let Ok(c) = std::ffi::CString::new(name) {
        highs_sys::Highs_getDoubleInfoValue(highs, c.as_ptr(), &mut out);
    }
    out
}

unsafe fn int_info(highs: *mut std::os::raw::c_void, name: &str) -> i32 {
    let mut out = 0_i32;
    if let Ok(c) = std::ffi::CString::new(name) {
        highs_sys::Highs_getIntInfoValue(highs, c.as_ptr(), &mut out);
    }
    out
}

#[rustler::nif(schedule = "DirtyCpu")]
fn solve(input: SolverInput, options: SolveOptions) -> Result<SolveResult, String> {
    let (n, m, nnz) = validate(&input)?;

    let (log_tx, log_handle) = match &options.log_pid {
        Some(pid) => {
            let (tx, handle) = spawn_log_sender(pid.clone());
            (Some(tx), Some(handle))
        }
        None => (None, None),
    };

    // owned by this stack frame for the whole call - requirement (4)
    let ctx = CallbackCtx {
        cancel: options.cancel.clone(),
        log_tx,
    };

    unsafe {
        let highs = highs_sys::Highs_create();
        if highs.is_null() {
            return Err("Highs_create failed".into());
        }

        // silence solver logging by default; user options applied afterwards
        // may turn it back on
        silence(highs);

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

        if ctx.cancel.is_some() || ctx.log_tx.is_some() {
            highs_sys::Highs_setCallback(
                highs,
                Some(solve_callback),
                &ctx as *const CallbackCtx as *mut std::os::raw::c_void,
            );

            if ctx.log_tx.is_some() {
                highs_sys::Highs_startCallback(highs, CB_LOGGING);
            }

            if ctx.cancel.is_some() {
                highs_sys::Highs_startCallback(highs, CB_SIMPLEX_INTERRUPT);
                highs_sys::Highs_startCallback(highs, CB_IPM_INTERRUPT);
                highs_sys::Highs_startCallback(highs, CB_MIP_INTERRUPT);
            }
        }

        pass_model(highs, &input, nnz)?;

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
        let dual_status = int_info(highs, "dual_solution_status");

        let raw_objective = double_info(highs, "objective_function_value");
        let objective = if raw_objective.is_finite() {
            Some(raw_objective)
        } else {
            None
        };
        let raw_gap = double_info(highs, "mip_gap");
        let mip_gap = if raw_gap.is_finite() { Some(raw_gap) } else { None };
        let simplex_iterations = int_info(highs, "simplex_iteration_count");

        let mut nodes = 0_i64;
        if let Ok(c) = std::ffi::CString::new("mip_node_count") {
            highs_sys::Highs_getInt64InfoValue(highs, c.as_ptr(), &mut nodes);
        }

        let solve_time = highs_sys::Highs_getRunTime(highs);

        highs_sys::Highs_destroy(highs); // (2) free on success

        // drop the Sender so the log thread's recv loop ends, then wait for
        // it to flush; guarantees all lines are delivered before we return
        drop(ctx);
        if let Some(handle) = log_handle {
            let _ = handle.join();
        }

        Ok(SolveResult {
            status: model_status,
            objective,
            values: col_value,
            col_duals: col_dual,
            row_duals: row_dual,
            dual_status,
            qcon_duals: None,
            solve_time,
            simplex_iterations,
            nodes,
            mip_gap,
        })
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn iis(input: SolverInput) -> Result<IisResult, String> {
    let (n, m, nnz) = validate(&input)?;

    unsafe {
        let highs = highs_sys::Highs_create();
        if highs.is_null() {
            return Err("Highs_create failed".into());
        }

        silence(highs);

        // the default "light" iis_strategy only finds trivial and single-row
        // infeasibilities; kHighsIisStrategyFromLpRowPriority = 6 forces the
        // full irreducible computation (verified against HiGHS 1.15.0)
        if let Ok(opt) = std::ffi::CString::new("iis_strategy") {
            highs_sys::Highs_setIntOptionValue(highs, opt.as_ptr(), 6);
        }

        pass_model(highs, &input, nnz)?;

        // (3) the IIS is a subset of the original columns/rows, so n and m
        // are exact upper bounds for the member buffers
        let mut num_col = 0_i32;
        let mut num_row = 0_i32;
        let mut col_index = vec![0_i32; n];
        let mut row_index = vec![0_i32; m];
        let mut col_bound = vec![0_i32; n];
        let mut row_bound = vec![0_i32; m];
        let mut col_status = vec![0_i32; n];
        let mut row_status = vec![0_i32; m];

        let status = highs_sys::Highs_getIis(
            highs,
            &mut num_col,
            &mut num_row,
            col_index.as_mut_ptr(),
            row_index.as_mut_ptr(),
            col_bound.as_mut_ptr(),
            row_bound.as_mut_ptr(),
            col_status.as_mut_ptr(),
            row_status.as_mut_ptr(),
        );

        highs_sys::Highs_destroy(highs); // (2) single exit after this point

        if status == highs_sys::STATUS_ERROR {
            return Err("getIis failed".into());
        }

        if num_col < 0 || num_col as usize > n || num_row < 0 || num_row as usize > m {
            return Err("getIis returned out-of-range counts".into());
        }

        col_index.truncate(num_col as usize);
        col_bound.truncate(num_col as usize);
        row_index.truncate(num_row as usize);
        row_bound.truncate(num_row as usize);

        Ok(IisResult {
            cols: col_index,
            col_statuses: col_bound,
            rows: row_index,
            row_statuses: row_bound,
            indicators: vec![],
            abs_defs: vec![],
            minmax_defs: vec![],
            pwl_defs: vec![],
            qconstraints: vec![],
            cones: vec![],
            soss: vec![],
        })
    }
}

rustler::init!("Elixir.Optex.Solver.HiGHS.Native");
