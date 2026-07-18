//! The COPT (Cardinal Optimizer) binding: dirty NIFs mirroring the other
//! crates' contract. FFI declarations are hand-rolled against the installed
//! COPT 8.0.5 copt.h (every signature and constant verified, originally
//! against 7.2.11 and re-verified byte-identical on the 8.0.5 upgrade; see
//! DECISIONS.md). Same four safety requirements: length firewall, free
//! env/prob on every exit path, exact-size output buffers, inputs owned by
//! locals for the whole call.
//!
//! COPT peculiarities handled here: every function is __stdcall on Windows
//! (extern "system"); parameters are string-named and set on the PROBLEM,
//! not the env; COPT_Solve dispatches LP/QP/QCP/MIP automatically; LP and
//! MIP status enumerations overlap numerically and are decoded on the
//! Elixir side with the MIP flag; COPT_INFINITY (1e30) and COPT_UNDEFINED
//! (1e40) are FINITE floats, so sentinel filtering is by magnitude, not
//! is_finite; cancellation calls COPT_Interrupt through a prob pointer the
//! token holds under a mutex only while the solve is running.

use rustler::{
    Atom, Encoder, LocalPid, NifResult, NifStruct, OwnedEnv, Resource, ResourceArc, Term,
};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

mod atoms {
    rustler::atoms! { min, max, infinity, neg_infinity, ok, optex_copt_log, le, ge, eq, quad, rquad, sos1, sos2, optex_progress, optex_incumbent_raw, best_obj, best_bound, gap, nodes, time }
}

// ---------------------------------------------------------------------------
// FFI (verified against COPT 8.0.5 copt.h; line references in comments)
// ---------------------------------------------------------------------------

#[allow(non_camel_case_types)]
pub enum copt_env {}
#[allow(non_camel_case_types)]
pub enum copt_prob {}

// copt.h:36-41
const COPT_MINIMIZE: c_int = 1;
const COPT_MAXIMIZE: c_int = -1;
const COPT_INFINITY: f64 = 1.0e30;
// copt.h:44
const COPT_BUFFSIZE: usize = 1000;
// LP statuses (copt.h:111-120) and MIP statuses (copt.h:123-131) that mean
// "infeasible family" for the IIS flow: LP INFEASIBLE 2; MIP INFEASIBLE 2,
// INF_OR_UNB 4
const IIS_WORTHY_STATUSES: [c_int; 2] = [2, 4];

// COPT_CALL is __stdcall on Windows and empty elsewhere (copt.h:4-8);
// extern "system" matches both.
extern "system" {
    // lifecycle (copt.h:402-424)
    fn COPT_GetRetcodeMsg(code: c_int, buff: *mut c_char, buffSize: c_int) -> c_int;
    fn COPT_CreateEnv(p_env: *mut *mut copt_env) -> c_int;
    fn COPT_DeleteEnv(p_env: *mut *mut copt_env) -> c_int;
    fn COPT_CreateProb(env: *mut copt_env, p_prob: *mut *mut copt_prob) -> c_int;
    fn COPT_DeleteProb(p_prob: *mut *mut copt_prob) -> c_int;

    // column-wise batch load (copt.h:426-443); beg+cnt CSC layout, sense
    // chars with rowBound as the rhs (rowBound/rowUpper as the pair for 'R')
    fn COPT_LoadProb(
        prob: *mut copt_prob,
        nCol: c_int,
        nRow: c_int,
        iObjSense: c_int,
        dObjConst: f64,
        colObj: *const f64,
        colMatBeg: *const c_int,
        colMatCnt: *const c_int,
        colMatIdx: *const c_int,
        colMatElem: *const f64,
        colType: *const c_char,
        colLower: *const f64,
        colUpper: *const f64,
        rowSense: *const c_char,
        rowBound: *const f64,
        rowUpper: *const f64,
        colNames: *const *const c_char,
        rowNames: *const *const c_char,
    ) -> c_int;

    // indicator constraint (copt.h:634-641); binColVal is the activating
    // value, i.e. our active_value directly (no complement flip)
    fn COPT_AddIndicator(
        prob: *mut copt_prob,
        binColIdx: c_int,
        binColVal: c_int,
        nRowMatCnt: c_int,
        rowMatIdx: *const c_int,
        rowMatElem: *const f64,
        cRowSense: c_char,
        dRowBound: f64,
    ) -> c_int;

    // second-order cones (copt.h:544-549); types COPT_CONE_QUAD 1 /
    // COPT_CONE_RQUAD 2 (copt.h:68-69); idx lists heads first
    fn COPT_AddCones(
        prob: *mut copt_prob,
        nAddCone: c_int,
        coneType: *const c_int,
        coneBeg: *const c_int,
        coneCnt: *const c_int,
        coneIdx: *const c_int,
    ) -> c_int;

    // special ordered sets (copt.h:536-542); types COPT_SOS_TYPE1 1 /
    // COPT_SOS_TYPE2 2 (copt.h:59-60)
    fn COPT_AddSOSs(
        prob: *mut copt_prob,
        nAddSOS: c_int,
        sosType: *const c_int,
        sosMatBeg: *const c_int,
        sosMatCnt: *const c_int,
        sosMatIdx: *const c_int,
        sosMatWt: *const f64,
    ) -> c_int;

    // quadratic objective triplets (copt.h:833); literal coefficients
    // (no 1/2 convention), pinned empirically by the analytic QP tests
    fn COPT_SetQuadObj(
        prob: *mut copt_prob,
        num: c_int,
        qRow: *const c_int,
        qCol: *const c_int,
        qElem: *const f64,
    ) -> c_int;

    // quadratic constraint (copt.h:572-582); single sense char + bound
    fn COPT_AddQConstr(
        prob: *mut copt_prob,
        nRowMatCnt: c_int,
        rowMatIdx: *const c_int,
        rowMatElem: *const f64,
        nQMatCnt: c_int,
        qMatRow: *const c_int,
        qMatCol: *const c_int,
        qMatElem: *const f64,
        cRowsense: c_char,
        dRowBound: f64,
        name: *const c_char,
    ) -> c_int;

    // solving (copt.h:948, 1065)
    fn COPT_Solve(prob: *mut copt_prob) -> c_int;
    fn COPT_Interrupt(prob: *mut copt_prob) -> c_int;

    // params, string-named, set on the problem (copt.h:967, 973)
    fn COPT_SetIntParam(prob: *mut copt_prob, paramName: *const c_char, intParam: c_int) -> c_int;
    fn COPT_SetDblParam(prob: *mut copt_prob, paramName: *const c_char, dblParam: f64) -> c_int;

    // attributes (copt.h:982-983)
    fn COPT_GetIntAttr(prob: *mut copt_prob, attrName: *const c_char, p_intAttr: *mut c_int)
        -> c_int;
    fn COPT_GetDblAttr(prob: *mut copt_prob, attrName: *const c_char, p_dblAttr: *mut f64)
        -> c_int;

    // bulk primal values (copt.h:957)
    fn COPT_GetSolution(prob: *mut copt_prob, colVal: *mut f64) -> c_int;
    // name-driven per-object info (copt.h:995, 997, 998)
    fn COPT_GetColInfo(
        prob: *mut copt_prob,
        infoName: *const c_char,
        num: c_int,
        list: *const c_int,
        info: *mut f64,
    ) -> c_int;
    fn COPT_GetRowInfo(
        prob: *mut copt_prob,
        infoName: *const c_char,
        num: c_int,
        list: *const c_int,
        info: *mut f64,
    ) -> c_int;
    // NOTE: COPT_GetQConstrInfo (copt.h:998) is deliberately NOT declared:
    // it rejects the "Dual" info name with RETCODE_INVALID (only slacks
    // exist for qconstraints), so nothing here can use it.

    // logging (copt.h:1028); callback is __stdcall on Windows too
    fn COPT_SetLogCallback(
        prob: *mut copt_prob,
        logcb: extern "system" fn(msg: *mut c_char, userdata: *mut c_void),
        userdata: *mut c_void,
    ) -> c_int;

    // solve callback (copt.h:1030-1034); cbctx is a mask of
    // COPT_CBCONTEXT_MIPNODE 0x4 / COPT_CBCONTEXT_INCUMBENT 0x8
    // (copt.h:134-137); info values by name string (copt.h:140-148)
    fn COPT_SetCallback(
        prob: *mut copt_prob,
        cb: extern "system" fn(*mut copt_prob, *mut c_void, c_int, *mut c_void) -> c_int,
        cbctx: c_int,
        userdata: *mut c_void,
    ) -> c_int;
    fn COPT_GetCallbackInfo(
        cbdata: *mut c_void,
        cbinfo: *const c_char,
        p_val: *mut c_void,
    ) -> c_int;

    // IIS (copt.h:950, 1010-1013); per-bound membership flags
    fn COPT_ComputeIIS(prob: *mut copt_prob) -> c_int;
    fn COPT_GetColLowerIIS(
        prob: *mut copt_prob,
        num: c_int,
        list: *const c_int,
        colLowerIIS: *mut c_int,
    ) -> c_int;
    fn COPT_GetColUpperIIS(
        prob: *mut copt_prob,
        num: c_int,
        list: *const c_int,
        colUpperIIS: *mut c_int,
    ) -> c_int;
    fn COPT_GetRowLowerIIS(
        prob: *mut copt_prob,
        num: c_int,
        list: *const c_int,
        rowLowerIIS: *mut c_int,
    ) -> c_int;
    fn COPT_GetRowUpperIIS(
        prob: *mut copt_prob,
        num: c_int,
        list: *const c_int,
        rowUpperIIS: *mut c_int,
    ) -> c_int;
}

// ---------------------------------------------------------------------------
// Wire structs (Elixir modules shared with the other backend crates)
// ---------------------------------------------------------------------------

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

/// Cancellation token. COPT_Interrupt needs the live prob pointer, so the
/// solve NIF parks it here (as usize) for exactly the duration of the
/// solve, clearing it under the same mutex before the prob is freed; cancel
/// then either interrupts a running solve or just flags a not-yet-started
/// one.
pub struct CancelToken {
    cancelled: AtomicBool,
    prob: Mutex<usize>,
}

#[rustler::resource_impl]
impl Resource for CancelToken {}

/// Wire form of a native indicator row, mapped onto COPT_AddIndicator
/// (binColVal takes active_value directly).
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
    col_type: Vec<i32>, // pre-mapped by the binding module: 0 cont, 1 int, 2 bin
    col_start: Vec<i32>,
    row_index: Vec<i32>,
    values: Vec<f64>,
    row_lb: Vec<Bound>,
    row_ub: Vec<Bound>,
    indicators: Vec<IndicatorRow>,
    abs_defs: Vec<(i32, i32)>, // rejected: COPT has no abs general constraint
    pwl_defs: Vec<PwlDef>,     // rejected: COPT has no PWL constraint
    minmax_defs: Vec<MinMaxDef>, // rejected: COPT has no min/max constraint
    cones: Vec<ConeRow>,
    soss: Vec<SosRow>,
    // quadratic objective as COO triplets, literal coefficients, normalized
    // q_cols[k] <= q_rows[k]; passed straight to COPT_SetQuadObj
    q_cols: Vec<i32>,
    q_rows: Vec<i32>,
    q_vals: Vec<f64>,
    // quadratic constraints, mapped onto COPT_AddQConstr (literal)
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

// present only so the shared Optex.SolverInput decodes; COPT cannot solve
// these and the firewall rejects them
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Pwl"]
struct PwlDef {
    res_col: i32,
    arg_col: i32,
    xs: Vec<f64>,
    ys: Vec<f64>,
}

#[derive(NifStruct)]
#[module = "Optex.SolverInput.MinMax"]
struct MinMaxDef {
    res_col: i32,
    op: Atom,
    arg_cols: Vec<i32>,
    constant: Option<f64>,
}

/// Wire form of a second-order cone (heads guaranteed lb >= 0 by the model
/// layer), mapped onto COPT's native cone API (COPT_AddCones, heads first
/// in the index list).
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Cone"]
struct ConeRow {
    cone_type: Atom, // :quad | :rquad
    head_cols: Vec<i32>,
    member_cols: Vec<i32>,
}

/// Wire form of a special ordered set, mapped onto COPT_AddSOSs.
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Sos"]
struct SosRow {
    sos_type: Atom, // :sos1 | :sos2
    cols: Vec<i32>,
    weights: Vec<f64>,
}

#[derive(NifStruct)]
#[module = "Optex.Solver.COPT.Options"]
struct SolveOptions {
    // COPT parameters are string-named like Gurobi's
    int_params: Vec<(String, i32)>,
    dbl_params: Vec<(String, f64)>,
    log_pid: Option<LocalPid>,
    cancel: Option<ResourceArc<CancelToken>>,
    // kept for wire-shape symmetry with the Gurobi options; COPT cannot
    // honor it (see qcon_duals below) and the Elixir side never sets it
    #[allow(dead_code)]
    qcp_duals: bool,
    // MIP progress/incumbent streaming (throttle applies to progress only)
    progress_pid: Option<LocalPid>,
    progress_every_ms: u64,
    incumbent_pid: Option<LocalPid>,
}

#[derive(NifStruct)]
#[module = "Optex.SolveResult"]
struct SolveResult {
    status: i32, // raw LpStatus or MipStatus; decoded on the Elixir side with the MIP flag
    objective: Option<f64>,
    values: Vec<f64>,
    col_duals: Vec<f64>,
    row_duals: Vec<f64>,
    dual_status: i32,
    qcon_duals: Option<Vec<f64>>,
    solve_time: f64,
    simplex_iterations: i32,
    nodes: i64,
    mip_gap: Option<f64>,
}

#[derive(NifStruct)]
#[module = "Optex.IisResult"]
struct IisResult {
    cols: Vec<i32>,
    col_statuses: Vec<i32>, // 2 lower, 3 upper, 4 boxed (shared convention)
    rows: Vec<i32>,
    row_statuses: Vec<i32>,
    // construct positions exist for the shared struct shape; COPT's IIS
    // reports rows/cols only here, so they stay empty
    indicators: Vec<i32>,
    abs_defs: Vec<i32>,
    minmax_defs: Vec<i32>,
    pwl_defs: Vec<i32>,
    qconstraints: Vec<i32>,
    cones: Vec<i32>,
    soss: Vec<i32>,
}

// ---------------------------------------------------------------------------
// Log streaming (same rules as the other crates: the log callback runs on
// the solving thread, so it only pushes into an mpsc channel; an unmanaged
// thread does the sending)
// ---------------------------------------------------------------------------

struct LogCtx {
    tx: Option<std::sync::mpsc::Sender<String>>,
    cancel: Option<ResourceArc<CancelToken>>,
    prob: usize,
}

fn spawn_log_sender(
    pid: LocalPid,
) -> (std::sync::mpsc::Sender<String>, std::thread::JoinHandle<()>) {
    let (tx, rx) = std::sync::mpsc::channel::<String>();

    let handle = std::thread::spawn(move || {
        while let Ok(line) = rx.recv() {
            let mut env = OwnedEnv::new();
            let _ =
                env.send_and_clear(&pid, |e| (atoms::optex_copt_log(), line.as_str()).encode(e));
        }
    });

    (tx, handle)
}

// Runs on the solver thread: forward log lines and poll cancellation (this
// doubles as the cooperative cancel hook alongside the direct
// COPT_Interrupt from the token; nothing here can panic).
extern "system" fn log_cb(msg: *mut c_char, userdata: *mut c_void) {
    if userdata.is_null() {
        return;
    }
    let ctx = unsafe { &*(userdata as *const LogCtx) };

    if let Some(token) = &ctx.cancel {
        if token.cancelled.load(Ordering::SeqCst) && ctx.prob != 0 {
            unsafe { COPT_Interrupt(ctx.prob as *mut copt_prob) };
        }
    }

    if let (Some(tx), false) = (&ctx.tx, msg.is_null()) {
        let text = unsafe { std::ffi::CStr::from_ptr(msg) }
            .to_string_lossy()
            .trim_end()
            .to_string();

        if !text.is_empty() {
            let _ = tx.send(text);
        }
    }
}

// COPT_CBCONTEXT_* masks, verified against copt.h 8.0.5 lines 134-137
const COPT_CBCONTEXT_MIPNODE: c_int = 0x4;
const COPT_CBCONTEXT_INCUMBENT: c_int = 0x8;

/// Progress/incumbent events, drained by one unmanaged sender thread; same
/// shapes as the other crates. COPT's callback info exposes no node count
/// or time, so those progress fields stay nil.
enum StreamEvent {
    Progress {
        best_obj: Option<f64>,
        best_bound: Option<f64>,
        gap: Option<f64>,
        nodes: Option<i64>,
        time: Option<f64>,
    },
    Incumbent {
        objective: f64,
        values: Vec<f64>,
    },
}

fn spawn_event_sender(
    progress_pid: Option<LocalPid>,
    incumbent_pid: Option<LocalPid>,
) -> (std::sync::mpsc::Sender<StreamEvent>, std::thread::JoinHandle<()>) {
    let (tx, rx) = std::sync::mpsc::channel::<StreamEvent>();

    let handle = std::thread::spawn(move || {
        while let Ok(event) = rx.recv() {
            match event {
                StreamEvent::Progress {
                    best_obj,
                    best_bound,
                    gap,
                    nodes,
                    time,
                } => {
                    if let Some(pid) = &progress_pid {
                        let mut env = OwnedEnv::new();
                        let _ = env.send_and_clear(pid, |e| {
                            let keys = [
                                atoms::best_obj().encode(e),
                                atoms::best_bound().encode(e),
                                atoms::gap().encode(e),
                                atoms::nodes().encode(e),
                                atoms::time().encode(e),
                            ];
                            let vals = [
                                best_obj.encode(e),
                                best_bound.encode(e),
                                gap.encode(e),
                                nodes.encode(e),
                                time.encode(e),
                            ];

                            match Term::map_from_arrays(e, &keys, &vals) {
                                Ok(map) => (atoms::optex_progress(), map).encode(e),
                                Err(_) => atoms::ok().encode(e),
                            }
                        });
                    }
                }
                StreamEvent::Incumbent { objective, values } => {
                    if let Some(pid) = &incumbent_pid {
                        let mut env = OwnedEnv::new();
                        let _ = env.send_and_clear(pid, |e| {
                            (atoms::optex_incumbent_raw(), objective, values.as_slice()).encode(e)
                        });
                    }
                }
            }
        }
    });

    (tx, handle)
}

struct StreamCtx {
    tx: std::sync::mpsc::Sender<StreamEvent>,
    want_progress: bool,
    want_incumbents: bool,
    progress_every_ms: u64,
    last_progress_ms: std::sync::atomic::AtomicU64,
    started: std::time::Instant,
    n: usize,
}

// Runs on COPT's solver thread; nothing here can panic (CString::new on
// static names cannot fail, but is still matched, never unwrapped).
extern "system" fn copt_solve_callback(
    _prob: *mut copt_prob,
    cbdata: *mut c_void,
    cbctx: c_int,
    userdata: *mut c_void,
) -> c_int {
    if userdata.is_null() || cbdata.is_null() {
        return 0;
    }
    let ctx = unsafe { &*(userdata as *const StreamCtx) };

    // COPT's 1e30 infinity is a FINITE sentinel: filter by magnitude
    let info_dbl = |name: &str| -> Option<f64> {
        let c = std::ffi::CString::new(name).ok()?;
        let mut v = 0.0_f64;
        let rc =
            unsafe { COPT_GetCallbackInfo(cbdata, c.as_ptr(), &mut v as *mut f64 as *mut c_void) };

        if rc == 0 && v.is_finite() && v.abs() < COPT_INFINITY {
            Some(v)
        } else {
            None
        }
    };

    if cbctx == COPT_CBCONTEXT_MIPNODE && ctx.want_progress {
        let now = ctx.started.elapsed().as_millis() as u64;
        let last = ctx.last_progress_ms.load(Ordering::Relaxed);

        if last == u64::MAX || now.saturating_sub(last) >= ctx.progress_every_ms {
            ctx.last_progress_ms.store(now, Ordering::Relaxed);

            let _ = ctx.tx.send(StreamEvent::Progress {
                best_obj: info_dbl("BestObj"),
                best_bound: info_dbl("BestBnd"),
                // COPT's callback info exposes neither gap nor node count;
                // time is elapsed-since-start measured here
                gap: None,
                nodes: None,
                time: Some(now as f64 / 1000.0),
            });
        }
    }

    if cbctx == COPT_CBCONTEXT_INCUMBENT && ctx.want_incumbents && ctx.n > 0 {
        let has_name = match std::ffi::CString::new("HasIncumbent") {
            Ok(c) => c,
            Err(_) => return 0,
        };
        let inc_name = match std::ffi::CString::new("Incumbent") {
            Ok(c) => c,
            Err(_) => return 0,
        };

        let mut has: c_int = 0;
        let rc = unsafe {
            COPT_GetCallbackInfo(cbdata, has_name.as_ptr(), &mut has as *mut c_int as *mut c_void)
        };

        if rc == 0 && has != 0 {
            // (3) exact-size buffer for the incumbent's column values
            let mut values = vec![0.0_f64; ctx.n];
            let rc = unsafe {
                COPT_GetCallbackInfo(cbdata, inc_name.as_ptr(), values.as_mut_ptr() as *mut c_void)
            };

            if rc == 0 {
                if let Some(objective) = info_dbl("BestObj") {
                    let _ = ctx.tx.send(StreamEvent::Incumbent { objective, values });
                }
            }
        }
    }

    0
}

#[rustler::nif]
fn cancel_token() -> ResourceArc<CancelToken> {
    ResourceArc::new(CancelToken {
        cancelled: AtomicBool::new(false),
        prob: Mutex::new(0),
    })
}

#[rustler::nif]
fn cancel(token: ResourceArc<CancelToken>) -> Atom {
    token.cancelled.store(true, Ordering::SeqCst);

    // interrupt a running solve directly; the pointer is nonzero exactly
    // while the solve NIF holds the prob alive
    let guard = token.prob.lock().unwrap();
    if *guard != 0 {
        unsafe { COPT_Interrupt(*guard as *mut copt_prob) };
    }

    atoms::ok()
}

// ---------------------------------------------------------------------------
// Validation and array building
// ---------------------------------------------------------------------------

// (1) length firewall - identical to the other crates'
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

    for ind in &input.indicators {
        if ind.cols.len() != ind.coefs.len()
            || ind.bin_col < 0
            || ind.bin_col as usize >= n
            || !(ind.active_value == 0 || ind.active_value == 1)
            || ind.cols.iter().any(|c| *c < 0 || *c as usize >= n)
        {
            return Err("invalid indicator row".into());
        }
    }

    if !input.abs_defs.is_empty() || !input.pwl_defs.is_empty() || !input.minmax_defs.is_empty() {
        return Err("COPT does not support abs, pwl, or min/max general constraints".into());
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

    for qc in &input.qconstraints {
        if qc.lin_cols.len() != qc.lin_coefs.len()
            || qc.lin_cols.iter().any(|c| *c < 0 || *c as usize >= n)
            || qc.q_cols.len() != qc.q_vals.len()
            || qc.q_rows.len() != qc.q_vals.len()
            || qc
                .q_cols
                .iter()
                .zip(qc.q_rows.iter())
                .any(|(c, r)| *c < 0 || *r < *c || *r as usize >= n)
            || qc
                .lin_coefs
                .iter()
                .chain(qc.q_vals.iter())
                .any(|v| !v.is_finite())
            || !qc.rhs.is_finite()
        {
            return Err("invalid quadratic constraint".into());
        }
    }

    validate_cones_soss(&input.cones, &input.soss, n)?;

    Ok((n, m, nnz))
}

// Shared structural firewall for cones (head count by type, ranges, no
// duplicate participants) and SOS (>= 2 members, distinct finite weights,
// no duplicate members).
fn validate_cones_soss(cones: &[ConeRow], soss: &[SosRow], n: usize) -> Result<(), String> {
    for cone in cones {
        let heads = if cone.cone_type == atoms::quad() {
            1
        } else if cone.cone_type == atoms::rquad() {
            2
        } else {
            return Err("unknown cone type".into());
        };

        let mut all: Vec<i32> = cone
            .head_cols
            .iter()
            .chain(cone.member_cols.iter())
            .copied()
            .collect();
        all.sort_unstable();

        if cone.head_cols.len() != heads
            || cone.member_cols.is_empty()
            || all.iter().any(|c| *c < 0 || *c as usize >= n)
            || all.windows(2).any(|w| w[0] == w[1])
        {
            return Err("invalid cone".into());
        }
    }

    for sos in soss {
        if sos.sos_type != atoms::sos1() && sos.sos_type != atoms::sos2() {
            return Err("unknown sos type".into());
        }

        let mut cols = sos.cols.clone();
        cols.sort_unstable();
        let mut weights = sos.weights.clone();
        weights.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

        if sos.cols.len() != sos.weights.len()
            || sos.cols.len() < 2
            || cols.iter().any(|c| *c < 0 || *c as usize >= n)
            || cols.windows(2).any(|w| w[0] == w[1])
            || sos.weights.iter().any(|v| !v.is_finite())
            || weights.windows(2).any(|w| w[0] == w[1])
        {
            return Err("invalid sos".into());
        }
    }

    Ok(())
}

fn sense_char(sense: Atom) -> Result<u8, String> {
    // COPT_LESS_EQUAL 'L', COPT_GREATER_EQUAL 'G', COPT_EQUAL 'E'
    // (copt.h:47-49)
    if sense == atoms::le() {
        Ok(b'L')
    } else if sense == atoms::ge() {
        Ok(b'G')
    } else if sense == atoms::eq() {
        Ok(b'E')
    } else {
        Err("unknown constraint sense".into())
    }
}

/// Owns every array COPT_LoadProb reads for the duration of the call (4).
struct ModelArrays {
    obj: Vec<f64>,
    matbeg: Vec<c_int>,
    matcnt: Vec<c_int>,
    matind: Vec<c_int>,
    matval: Vec<f64>,
    ctype: Vec<c_char>,
    lb: Vec<f64>,
    ub: Vec<f64>,
    sense: Vec<c_char>,
    bound: Vec<f64>,
    upper: Vec<f64>,
    is_mip: bool,
}

/// COPT rows are sense + rowBound, with native ranged rows: sense 'R'
/// bounds the activity to [rowBound, rowUpper] (copt.h:47-51, 439-441).
/// Every SolverInput row maps, including genuine two-sided ranges.
fn to_arrays(input: &SolverInput, n: usize, m: usize) -> Result<ModelArrays, String> {
    let mut sense = Vec::with_capacity(m);
    let mut bound = Vec::with_capacity(m);
    let mut upper = vec![0.0_f64; m];

    for i in 0..m {
        let (s, b) = match (input.row_lb[i], input.row_ub[i]) {
            (Bound::NegInf, Bound::Num(u)) => (b'L', u),
            (Bound::Num(l), Bound::PosInf) => (b'G', l),
            (Bound::Num(l), Bound::Num(u)) if l == u => (b'E', l),
            (Bound::Num(l), Bound::Num(u)) if l < u => {
                upper[i] = u;
                (b'R', l)
            }
            (Bound::NegInf, Bound::PosInf) => (b'N', 0.0),
            _ => return Err("inconsistent row bounds".into()),
        };

        sense.push(s as c_char);
        bound.push(b);
    }

    let mut ctype = Vec::with_capacity(n);
    let mut is_mip = false;
    for t in &input.col_type {
        // COPT_CONTINUOUS 'C', COPT_BINARY 'B', COPT_INTEGER 'I'
        // (copt.h:54-56)
        ctype.push(match t {
            0 => b'C' as c_char,
            1 => {
                is_mip = true;
                b'I' as c_char
            }
            2 => {
                is_mip = true;
                b'B' as c_char
            }
            _ => return Err("unknown variable type".into()),
        });
    }

    // indicators require a binary, so is_mip is already true whenever they
    // exist; SOS sets force the MIP path even over continuous columns
    let is_mip = is_mip || !input.indicators.is_empty() || !input.soss.is_empty();

    let matcnt = (0..n)
        .map(|j| input.col_start[j + 1] - input.col_start[j])
        .collect();

    Ok(ModelArrays {
        obj: input.obj.clone(),
        matbeg: input.col_start[..n].to_vec(),
        matcnt,
        matind: input.row_index.clone(),
        matval: input.values.clone(),
        ctype,
        lb: input
            .col_lb
            .iter()
            .map(|b| b.resolve(COPT_INFINITY))
            .collect(),
        ub: input
            .col_ub
            .iter()
            .map(|b| b.resolve(COPT_INFINITY))
            .collect(),
        sense,
        bound,
        upper,
        is_mip,
    })
}

fn retcode_error(code: c_int, context: &str) -> String {
    let mut buffer = [0 as c_char; COPT_BUFFSIZE];
    let rc = unsafe { COPT_GetRetcodeMsg(code, buffer.as_mut_ptr(), COPT_BUFFSIZE as c_int) };
    if rc != 0 {
        format!("{context} (code {code})")
    } else {
        let msg = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) }.to_string_lossy();
        format!("{context}: {}", msg.trim_end())
    }
}

unsafe fn close_all(env: *mut copt_env, prob: *mut copt_prob) {
    let mut prob = prob;
    COPT_DeleteProb(&mut prob);
    let mut env = env;
    COPT_DeleteEnv(&mut env);
}

unsafe fn set_int_param(prob: *mut copt_prob, name: &str, v: c_int) -> Result<(), String> {
    let c = std::ffi::CString::new(name).map_err(|_| "bad param name".to_string())?;
    if COPT_SetIntParam(prob, c.as_ptr(), v) != 0 {
        return Err(format!("invalid solver option (param {name})"));
    }
    Ok(())
}

unsafe fn set_dbl_param(prob: *mut copt_prob, name: &str, v: f64) -> Result<(), String> {
    let c = std::ffi::CString::new(name).map_err(|_| "bad param name".to_string())?;
    if COPT_SetDblParam(prob, c.as_ptr(), v) != 0 {
        return Err(format!("invalid solver option (param {name})"));
    }
    Ok(())
}

unsafe fn int_attr(prob: *mut copt_prob, name: &str) -> Option<c_int> {
    let c = std::ffi::CString::new(name).ok()?;
    let mut out: c_int = 0;
    if COPT_GetIntAttr(prob, c.as_ptr(), &mut out) == 0 {
        Some(out)
    } else {
        None
    }
}

// COPT_INFINITY (1e30) and COPT_UNDEFINED (1e40) are finite f64 sentinels;
// only magnitudes below the infinity threshold are real values
unsafe fn dbl_attr(prob: *mut copt_prob, name: &str) -> Option<f64> {
    let c = std::ffi::CString::new(name).ok()?;
    let mut out = 0.0_f64;
    if COPT_GetDblAttr(prob, c.as_ptr(), &mut out) == 0 && out.is_finite() && out.abs() < COPT_INFINITY
    {
        Some(out)
    } else {
        None
    }
}

/// Open the env (license check happens here), create and load the problem,
/// apply params, add constructs. On error everything created so far is
/// freed.
unsafe fn open_model(
    input: &SolverInput,
    arrays: &ModelArrays,
    n: usize,
    m: usize,
    int_params: &[(String, i32)],
    dbl_params: &[(String, f64)],
) -> Result<(*mut copt_env, *mut copt_prob), String> {
    let mut env: *mut copt_env = std::ptr::null_mut();
    let rc = COPT_CreateEnv(&mut env);
    if rc != 0 || env.is_null() {
        if !env.is_null() {
            COPT_DeleteEnv(&mut env);
        }
        return Err(retcode_error(rc, "COPT_CreateEnv failed (license?)"));
    }

    let mut prob: *mut copt_prob = std::ptr::null_mut();
    let rc = COPT_CreateProb(env, &mut prob);
    if rc != 0 || prob.is_null() {
        if !prob.is_null() {
            COPT_DeleteProb(&mut prob);
        }
        COPT_DeleteEnv(&mut env);
        return Err(retcode_error(rc, "COPT_CreateProb failed"));
    }

    // silent by default; user params applied afterwards may override
    let setup = set_int_param(prob, "Logging", 0)
        .and_then(|_| {
            int_params
                .iter()
                .try_for_each(|(k, v)| set_int_param(prob, k, *v))
        })
        .and_then(|_| {
            dbl_params
                .iter()
                .try_for_each(|(k, v)| set_dbl_param(prob, k, *v))
        });

    if let Err(e) = setup {
        close_all(env, prob);
        return Err(e);
    }

    let objsense = if input.sense == atoms::min() {
        COPT_MINIMIZE
    } else {
        COPT_MAXIMIZE
    };

    let rc = COPT_LoadProb(
        prob,
        n as c_int,
        m as c_int,
        objsense,
        input.obj_offset,
        arrays.obj.as_ptr(),
        arrays.matbeg.as_ptr(),
        arrays.matcnt.as_ptr(),
        arrays.matind.as_ptr(),
        arrays.matval.as_ptr(),
        arrays.ctype.as_ptr(),
        arrays.lb.as_ptr(),
        arrays.ub.as_ptr(),
        arrays.sense.as_ptr(),
        arrays.bound.as_ptr(),
        arrays.upper.as_ptr(),
        std::ptr::null(),
        std::ptr::null(),
    );

    if rc != 0 {
        let e = retcode_error(rc, "COPT_LoadProb failed");
        close_all(env, prob);
        return Err(e);
    }

    // native constructs, range-checked by the firewall
    for ind in &input.indicators {
        let sense = match sense_char(ind.sense) {
            Ok(s) => s,
            Err(e) => {
                close_all(env, prob);
                return Err(e);
            }
        };

        let rc = COPT_AddIndicator(
            prob,
            ind.bin_col,
            ind.active_value,
            ind.cols.len() as c_int,
            ind.cols.as_ptr(),
            ind.coefs.as_ptr(),
            sense as c_char,
            ind.rhs,
        );

        if rc != 0 {
            let e = retcode_error(rc, "COPT_AddIndicator failed");
            close_all(env, prob);
            return Err(e);
        }
    }

    if !input.q_vals.is_empty() {
        let rc = COPT_SetQuadObj(
            prob,
            input.q_vals.len() as c_int,
            input.q_rows.as_ptr(),
            input.q_cols.as_ptr(),
            input.q_vals.as_ptr(),
        );

        if rc != 0 {
            let e = retcode_error(rc, "COPT_SetQuadObj failed");
            close_all(env, prob);
            return Err(e);
        }
    }

    for qc in &input.qconstraints {
        let sense = match sense_char(qc.sense) {
            Ok(s) => s,
            Err(e) => {
                close_all(env, prob);
                return Err(e);
            }
        };

        let rc = COPT_AddQConstr(
            prob,
            qc.lin_cols.len() as c_int,
            qc.lin_cols.as_ptr(),
            qc.lin_coefs.as_ptr(),
            qc.q_vals.len() as c_int,
            qc.q_rows.as_ptr(),
            qc.q_cols.as_ptr(),
            qc.q_vals.as_ptr(),
            sense as c_char,
            qc.rhs,
            std::ptr::null(),
        );

        if rc != 0 {
            let e = retcode_error(rc, "COPT_AddQConstr failed");
            close_all(env, prob);
            return Err(e);
        }
    }

    // second-order cones, batch call (types 1/2 per copt.h:68-69); the
    // per-cone index list is heads first, then members (pinned by the
    // analytic quad and rotated tests)
    if !input.cones.is_empty() {
        let mut types: Vec<c_int> = Vec::with_capacity(input.cones.len());
        let mut beg: Vec<c_int> = Vec::with_capacity(input.cones.len());
        let mut cnt: Vec<c_int> = Vec::with_capacity(input.cones.len());
        let mut idx: Vec<c_int> = vec![];

        for cone in &input.cones {
            types.push(if cone.cone_type == atoms::quad() { 1 } else { 2 });
            beg.push(idx.len() as c_int);
            cnt.push((cone.head_cols.len() + cone.member_cols.len()) as c_int);
            idx.extend_from_slice(&cone.head_cols);
            idx.extend_from_slice(&cone.member_cols);
        }

        let rc = COPT_AddCones(
            prob,
            input.cones.len() as c_int,
            types.as_ptr(),
            beg.as_ptr(),
            cnt.as_ptr(),
            idx.as_ptr(),
        );

        if rc != 0 {
            let e = retcode_error(rc, "COPT_AddCones failed");
            close_all(env, prob);
            return Err(e);
        }
    }

    // SOS sets, batch call (types 1/2 per copt.h:59-60)
    if !input.soss.is_empty() {
        let mut types: Vec<c_int> = Vec::with_capacity(input.soss.len());
        let mut beg: Vec<c_int> = Vec::with_capacity(input.soss.len());
        let mut cnt: Vec<c_int> = Vec::with_capacity(input.soss.len());
        let mut idx: Vec<c_int> = vec![];
        let mut wt: Vec<f64> = vec![];

        for sos in &input.soss {
            types.push(if sos.sos_type == atoms::sos1() { 1 } else { 2 });
            beg.push(idx.len() as c_int);
            cnt.push(sos.cols.len() as c_int);
            idx.extend_from_slice(&sos.cols);
            wt.extend_from_slice(&sos.weights);
        }

        let rc = COPT_AddSOSs(
            prob,
            input.soss.len() as c_int,
            types.as_ptr(),
            beg.as_ptr(),
            cnt.as_ptr(),
            idx.as_ptr(),
            wt.as_ptr(),
        );

        if rc != 0 {
            let e = retcode_error(rc, "COPT_AddSOSs failed");
            close_all(env, prob);
            return Err(e);
        }
    }

    Ok((env, prob))
}

// ---------------------------------------------------------------------------
// NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn solve(input: SolverInput, options: SolveOptions) -> Result<SolveResult, String> {
    let (n, m, _nnz) = validate(&input)?;
    let arrays = to_arrays(&input, n, m)?;

    let (log_tx, log_handle) = match &options.log_pid {
        Some(pid) => {
            let (tx, handle) = spawn_log_sender(pid.clone());
            (Some(tx), Some(handle))
        }
        None => (None, None),
    };

    let want_progress = options.progress_pid.is_some();
    let want_incumbents = options.incumbent_pid.is_some();

    let (stream_tx, event_handle) = if want_progress || want_incumbents {
        let (tx, handle) =
            spawn_event_sender(options.progress_pid.clone(), options.incumbent_pid.clone());
        (Some(tx), Some(handle))
    } else {
        (None, None)
    };

    unsafe {
        let (env, prob) = open_model(
            &input,
            &arrays,
            n,
            m,
            &options.int_params,
            &options.dbl_params,
        )?;

        // owned by this stack frame for the whole call (4); the callback
        // also polls cancellation, so it is installed (with logging forced
        // on) whenever either logging or a cancel token is present
        let log_ctx = Box::new(LogCtx {
            tx: log_tx,
            cancel: options.cancel.clone(),
            prob: prob as usize,
        });

        if log_ctx.tx.is_some() || log_ctx.cancel.is_some() {
            if log_ctx.tx.is_none() {
                // cancel-only: log lines must be generated for the poll
                // hook to run, but none are forwarded and none hit the
                // console (LogToConsole first, so enabling Logging does
                // not echo the parameter change to the console)
                let _ = set_int_param(prob, "LogToConsole", 0);
                let _ = set_int_param(prob, "Logging", 1);
            }
            COPT_SetLogCallback(prob, log_cb, log_ctx.as_ref() as *const LogCtx as *mut c_void);
        }

        // progress/incumbent streaming (4: the Box outlives the solve)
        let stream_ctx = stream_tx.map(|tx| {
            Box::new(StreamCtx {
                tx,
                want_progress,
                want_incumbents,
                progress_every_ms: options.progress_every_ms,
                last_progress_ms: std::sync::atomic::AtomicU64::new(u64::MAX),
                started: std::time::Instant::now(),
                n,
            })
        });

        if let Some(sc) = &stream_ctx {
            let mask = if sc.want_progress {
                COPT_CBCONTEXT_MIPNODE
            } else {
                0
            } | if sc.want_incumbents {
                COPT_CBCONTEXT_INCUMBENT
            } else {
                0
            };

            COPT_SetCallback(
                prob,
                copt_solve_callback,
                mask,
                sc.as_ref() as *const StreamCtx as *mut c_void,
            );
        }

        // park the prob pointer in the token so cancel/1 can interrupt from
        // another thread; cleared under the same lock before the free below
        let pre_cancelled = match &options.cancel {
            Some(token) => {
                *token.prob.lock().unwrap() = prob as usize;
                token.cancelled.load(Ordering::SeqCst)
            }
            None => false,
        };

        // a token cancelled before the solve starts skips it entirely:
        // COPT_Interrupt does not persist across a solve start (verified
        // empirically; a pre-solve interrupt still ran to optimality), so
        // the interrupted outcome is synthesized with the shared status
        // code 10 (INTERRUPTED in BOTH the Lp and Mip tables)
        let started = std::time::Instant::now();
        let rc = if pre_cancelled { 0 } else { COPT_Solve(prob) };
        let solve_time = started.elapsed().as_secs_f64();

        if let Some(token) = &options.cancel {
            *token.prob.lock().unwrap() = 0;
        }

        if rc != 0 {
            let e = retcode_error(rc, "COPT_Solve failed");
            close_all(env, prob); // (2)
            return Err(e);
        }

        // LP and MIP statuses live in different attributes with overlapping
        // codes; the Elixir side decodes with the MIP flag it already has
        let status = if pre_cancelled {
            10
        } else if arrays.is_mip {
            int_attr(prob, "MipStatus").unwrap_or(0)
        } else {
            int_attr(prob, "LpStatus").unwrap_or(0)
        };

        // (3) exact-size output buffers; unavailable arrays report zeros
        let mut values = vec![0.0_f64; n];
        let has_sol = if arrays.is_mip {
            int_attr(prob, "HasMipSol") == Some(1)
        } else {
            int_attr(prob, "HasLpSol") == Some(1)
        };
        if !(n > 0 && has_sol && COPT_GetSolution(prob, values.as_mut_ptr()) == 0) {
            values = vec![0.0; n];
        }

        // duals exist only for continuous problems with an LP solution
        let mut dual_status = 0;
        let mut row_duals = vec![0.0_f64; m];
        let mut col_duals = vec![0.0_f64; n];

        if !arrays.is_mip && int_attr(prob, "HasLpSol") == Some(1) {
            let dual_name = std::ffi::CString::new("Dual").unwrap();
            let redcost_name = std::ffi::CString::new("RedCost").unwrap();
            let row_list: Vec<c_int> = (0..m as c_int).collect();
            let col_list: Vec<c_int> = (0..n as c_int).collect();

            let pi_ok = m == 0
                || COPT_GetRowInfo(
                    prob,
                    dual_name.as_ptr(),
                    m as c_int,
                    row_list.as_ptr(),
                    row_duals.as_mut_ptr(),
                ) == 0;
            let dj_ok = n == 0
                || COPT_GetColInfo(
                    prob,
                    redcost_name.as_ptr(),
                    n as c_int,
                    col_list.as_ptr(),
                    col_duals.as_mut_ptr(),
                ) == 0;

            if pi_ok && dj_ok {
                dual_status = 2;
            } else {
                row_duals = vec![0.0; m];
                col_duals = vec![0.0; n];
            }
        }

        // always None: COPT_GetQConstrInfo rejects the "Dual" info name
        // with RETCODE_INVALID (verified empirically on 8.0.5; "Slack"
        // works), so like CPLEX the C API exposes qconstraint slacks but
        // no dual multipliers. The Elixir side rejects qcp_duals: true
        // pre-NIF; options.qcp_duals therefore never arrives set.
        let qcon_duals: Option<Vec<f64>> = None;

        let objective = if arrays.is_mip {
            dbl_attr(prob, "BestObj")
        } else {
            dbl_attr(prob, "LpObjval")
        };

        let simplex_iterations = int_attr(prob, "SimplexIter").unwrap_or(0);
        let (nodes, mip_gap) = if arrays.is_mip {
            (
                int_attr(prob, "NodeCnt").unwrap_or(0) as i64,
                dbl_attr(prob, "BestGap"),
            )
        } else {
            (0, None)
        };

        close_all(env, prob); // (2) free on success

        drop(log_ctx);
        if let Some(handle) = log_handle {
            let _ = handle.join();
        }
        drop(stream_ctx);
        if let Some(handle) = event_handle {
            let _ = handle.join();
        }

        Ok(SolveResult {
            status,
            objective,
            values,
            col_duals,
            row_duals,
            dual_status,
            qcon_duals,
            solve_time,
            simplex_iterations,
            nodes,
            mip_gap,
        })
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn iis(input: SolverInput) -> Result<IisResult, String> {
    let (n, m, _nnz) = validate(&input)?;
    let arrays = to_arrays(&input, n, m)?;

    unsafe {
        let (env, prob) = open_model(&input, &arrays, n, m, &[], &[])?;

        let rc = COPT_Solve(prob);
        if rc != 0 {
            let e = retcode_error(rc, "COPT_Solve failed");
            close_all(env, prob); // (2)
            return Err(e);
        }

        let status = if arrays.is_mip {
            int_attr(prob, "MipStatus").unwrap_or(0)
        } else {
            int_attr(prob, "LpStatus").unwrap_or(0)
        };

        if !IIS_WORTHY_STATUSES.contains(&status) {
            close_all(env, prob); // (2)
            return Ok(IisResult {
                cols: vec![],
                col_statuses: vec![],
                rows: vec![],
                row_statuses: vec![],
                indicators: vec![],
                abs_defs: vec![],
                minmax_defs: vec![],
                pwl_defs: vec![],
                qconstraints: vec![],
                cones: vec![],
                soss: vec![],
            });
        }

        let rc = COPT_ComputeIIS(prob);
        if rc != 0 {
            let e = retcode_error(rc, "COPT_ComputeIIS failed");
            close_all(env, prob); // (2)
            return Err(e);
        }

        if int_attr(prob, "HasIIS") != Some(1) {
            close_all(env, prob); // (2)
            return Ok(IisResult {
                cols: vec![],
                col_statuses: vec![],
                rows: vec![],
                row_statuses: vec![],
                indicators: vec![],
                abs_defs: vec![],
                minmax_defs: vec![],
                pwl_defs: vec![],
                qconstraints: vec![],
                cones: vec![],
                soss: vec![],
            });
        }

        // (3) per-bound membership flags, exact-size buffers
        let col_list: Vec<c_int> = (0..n as c_int).collect();
        let row_list: Vec<c_int> = (0..m as c_int).collect();
        let mut col_lower = vec![0 as c_int; n];
        let mut col_upper = vec![0 as c_int; n];
        let mut row_lower = vec![0 as c_int; m];
        let mut row_upper = vec![0 as c_int; m];

        let ok = (n == 0
            || (COPT_GetColLowerIIS(prob, n as c_int, col_list.as_ptr(), col_lower.as_mut_ptr())
                == 0
                && COPT_GetColUpperIIS(
                    prob,
                    n as c_int,
                    col_list.as_ptr(),
                    col_upper.as_mut_ptr(),
                ) == 0))
            && (m == 0
                || (COPT_GetRowLowerIIS(
                    prob,
                    m as c_int,
                    row_list.as_ptr(),
                    row_lower.as_mut_ptr(),
                ) == 0
                    && COPT_GetRowUpperIIS(
                        prob,
                        m as c_int,
                        row_list.as_ptr(),
                        row_upper.as_mut_ptr(),
                    ) == 0));

        close_all(env, prob); // (2) single exit after this point

        if !ok {
            return Err("COPT IIS retrieval failed".into());
        }

        // shared member-status convention: 2 lower, 3 upper, 4 boxed
        let mut cols = vec![];
        let mut col_statuses = vec![];
        for j in 0..n {
            match (col_lower[j] != 0, col_upper[j] != 0) {
                (true, true) => {
                    cols.push(j as i32);
                    col_statuses.push(4);
                }
                (true, false) => {
                    cols.push(j as i32);
                    col_statuses.push(2);
                }
                (false, true) => {
                    cols.push(j as i32);
                    col_statuses.push(3);
                }
                (false, false) => {}
            }
        }

        let mut rows = vec![];
        let mut row_statuses = vec![];
        for i in 0..m {
            match (row_lower[i] != 0, row_upper[i] != 0) {
                (true, true) => {
                    rows.push(i as i32);
                    row_statuses.push(4);
                }
                (true, false) => {
                    rows.push(i as i32);
                    row_statuses.push(2);
                }
                (false, true) => {
                    rows.push(i as i32);
                    row_statuses.push(3);
                }
                (false, false) => {}
            }
        }

        Ok(IisResult {
            cols,
            col_statuses,
            rows,
            row_statuses,
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

rustler::init!("Elixir.Optex.Solver.COPT.Native");
