//! The CPLEX binding: dirty NIFs mirroring the HiGHS and Gurobi crates'
//! contract. FFI declarations are hand-rolled against the installed CPLEX
//! 22.1.1 cplex.h/cpxconst.h (every signature and constant verified; see
//! DECISIONS.md). Same four safety requirements: length firewall, free
//! env/prob on every exit path, exact-size output buffers, inputs owned by
//! locals for the whole call.
//!
//! CPLEX peculiarities handled here: LP and MIP have separate optimize
//! calls and disjoint status tables (decoded on the Elixir side; the code
//! spaces do not overlap); ranged rows are supported natively via sense 'R'
//! with rngval; cancellation uses CPXsetterminate polling an int the token
//! owns; parameters are numeric ids.

use rustler::{Atom, Encoder, LocalPid, NifResult, NifStruct, OwnedEnv, Resource, ResourceArc, Term};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicI32, Ordering};

mod atoms {
    rustler::atoms! { min, max, infinity, neg_infinity, ok, optex_cplex_log, le, ge, eq, quad, rquad, sos1, sos2 }
}

// ---------------------------------------------------------------------------
// FFI (verified against CPLEX 22.1.1 cplex.h / cpxconst.h)
// ---------------------------------------------------------------------------

#[allow(non_camel_case_types)]
pub enum CPXenv {}
#[allow(non_camel_case_types)]
pub enum CPXlp {}
#[allow(non_camel_case_types)]
pub enum CPXchannel {}

const CPX_INFBOUND: f64 = 1.0e20;
const CPX_MIN: c_int = 1;
const CPX_MAX: c_int = -1;
// infeasible-family statuses that justify running the conflict refiner:
// CPX_STAT_INFEASIBLE 3, CPX_STAT_INForUNBD 4, CPXMIP_INFEASIBLE 103,
// CPXMIP_INForUNBD 119
const INFEASIBLE_STATUSES: [c_int; 4] = [3, 4, 103, 119];
// conflict member statuses: CPX_CONFLICT_MEMBER 3, _LB 4, _UB 5
const CONFLICT_MEMBER: c_int = 3;
const CONFLICT_LB: c_int = 4;
const CONFLICT_UB: c_int = 5;
const CPXMESSAGEBUFSIZE: usize = 1024;

extern "C" {
    fn CPXopenCPLEX(status_p: *mut c_int) -> *mut CPXenv;
    fn CPXcloseCPLEX(env_p: *mut *mut CPXenv) -> c_int;
    fn CPXgeterrorstring(env: *mut CPXenv, errcode: c_int, buffer: *mut c_char) -> *const c_char;

    fn CPXcreateprob(env: *mut CPXenv, status_p: *mut c_int, probname: *const c_char)
        -> *mut CPXlp;
    fn CPXfreeprob(env: *mut CPXenv, lp_p: *mut *mut CPXlp) -> c_int;

    fn CPXcopylp(
        env: *mut CPXenv,
        lp: *mut CPXlp,
        numcols: c_int,
        numrows: c_int,
        objsense: c_int,
        objective: *const f64,
        rhs: *const f64,
        sense: *const c_char,
        matbeg: *const c_int,
        matcnt: *const c_int,
        matind: *const c_int,
        matval: *const f64,
        lb: *const f64,
        ub: *const f64,
        rngval: *const f64,
    ) -> c_int;
    fn CPXcopyctype(env: *mut CPXenv, lp: *mut CPXlp, xctype: *const c_char) -> c_int;
    fn CPXchgobjoffset(env: *mut CPXenv, lp: *mut CPXlp, offset: f64) -> c_int;

    fn CPXsetintparam(env: *mut CPXenv, whichparam: c_int, newvalue: c_int) -> c_int;
    fn CPXsetdblparam(env: *mut CPXenv, whichparam: c_int, newvalue: f64) -> c_int;
    fn CPXsetterminate(env: *mut CPXenv, terminate_p: *mut c_int) -> c_int;

    fn CPXgetchannels(
        env: *mut CPXenv,
        cpxresults_p: *mut *mut CPXchannel,
        cpxwarning_p: *mut *mut CPXchannel,
        cpxerror_p: *mut *mut CPXchannel,
        cpxlog_p: *mut *mut CPXchannel,
    ) -> c_int;
    fn CPXaddfuncdest(
        env: *mut CPXenv,
        channel: *mut CPXchannel,
        handle: *mut c_void,
        msgfunction: extern "C" fn(*mut c_void, *const c_char),
    ) -> c_int;

    fn CPXlpopt(env: *mut CPXenv, lp: *mut CPXlp) -> c_int;
    fn CPXmipopt(env: *mut CPXenv, lp: *mut CPXlp) -> c_int;
    fn CPXqpopt(env: *mut CPXenv, lp: *mut CPXlp) -> c_int;
    fn CPXbaropt(env: *mut CPXenv, lp: *mut CPXlp) -> c_int;
    // quadratic constraint; both parts use literal coefficients (the 1/2
    // convention applies only to the objective)
    fn CPXaddqconstr(
        env: *mut CPXenv,
        lp: *mut CPXlp,
        linnzcnt: c_int,
        quadnzcnt: c_int,
        rhs: f64,
        sense: c_int,
        linind: *const c_int,
        linval: *const f64,
        quadrow: *const c_int,
        quadcol: *const c_int,
        quadval: *const f64,
        lname_str: *const c_char,
    ) -> c_int;
    // full symmetric Q in CSC; objective convention is c'x + 1/2 x'Qx
    fn CPXcopyquad(
        env: *mut CPXenv,
        lp: *mut CPXlp,
        qmatbeg: *const c_int,
        qmatcnt: *const c_int,
        qmatind: *const c_int,
        qmatval: *const f64,
    ) -> c_int;
    fn CPXgetstat(env: *mut CPXenv, lp: *mut CPXlp) -> c_int;
    fn CPXgetobjval(env: *mut CPXenv, lp: *mut CPXlp, objval_p: *mut f64) -> c_int;
    fn CPXgetx(env: *mut CPXenv, lp: *mut CPXlp, x: *mut f64, begin: c_int, end: c_int) -> c_int;
    fn CPXgetpi(env: *mut CPXenv, lp: *mut CPXlp, pi: *mut f64, begin: c_int, end: c_int)
        -> c_int;
    fn CPXgetdj(env: *mut CPXenv, lp: *mut CPXlp, dj: *mut f64, begin: c_int, end: c_int)
        -> c_int;
    fn CPXgetitcnt(env: *mut CPXenv, lp: *mut CPXlp) -> c_int;
    fn CPXgetmipitcnt(env: *mut CPXenv, lp: *mut CPXlp) -> c_int;
    fn CPXgetnodecnt(env: *mut CPXenv, lp: *mut CPXlp) -> c_int;
    fn CPXgetmiprelgap(env: *mut CPXenv, lp: *mut CPXlp, gap_p: *mut f64) -> c_int;

    fn CPXaddindconstr(
        env: *mut CPXenv,
        lp: *mut CPXlp,
        indvar: c_int,
        complemented: c_int,
        nzcnt: c_int,
        rhs: f64,
        sense: c_int,
        linind: *const c_int,
        linval: *const f64,
        indname_str: *const c_char,
    ) -> c_int;
    // special ordered sets, batch form (types are chars '1'/'2')
    fn CPXaddsos(
        env: *mut CPXenv,
        lp: *mut CPXlp,
        numsos: c_int,
        numsosnz: c_int,
        sostype: *const c_char,
        sosbeg: *const c_int,
        sosind: *const c_int,
        soswt: *const f64,
        sosname: *mut *mut c_char,
    ) -> c_int;
    fn CPXaddpwl(
        env: *mut CPXenv,
        lp: *mut CPXlp,
        vary: c_int,
        varx: c_int,
        preslope: f64,
        postslope: f64,
        nbreaks: c_int,
        breakx: *const f64,
        breaky: *const f64,
        pwlname: *const c_char,
    ) -> c_int;

    fn CPXrefineconflict(
        env: *mut CPXenv,
        lp: *mut CPXlp,
        confnumrows_p: *mut c_int,
        confnumcols_p: *mut c_int,
    ) -> c_int;
    fn CPXgetconflict(
        env: *mut CPXenv,
        lp: *mut CPXlp,
        confstat_p: *mut c_int,
        rowind: *mut c_int,
        rowbdstat: *mut c_int,
        confnumrows_p: *mut c_int,
        colind: *mut c_int,
        colbdstat: *mut c_int,
        confnumcols_p: *mut c_int,
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

/// Cancellation token: CPXsetterminate polls the int this resource owns.
pub struct CancelToken {
    flag: AtomicI32,
}

#[rustler::resource_impl]
impl Resource for CancelToken {}

/// Wire form of a native indicator row, mapped onto CPXaddindconstr
/// (active_value 0 maps to the complemented form).
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
    abs_defs: Vec<(i32, i32)>, // (result_col, argument_col)
    pwl_defs: Vec<PwlDef>,
    minmax_defs: Vec<MinMaxDef>,
    cones: Vec<ConeRow>,
    soss: Vec<SosRow>,
    // quadratic objective as COO triplets, literal coefficients, normalized
    // q_cols[k] <= q_rows[k]; converted to CPLEX's full symmetric 1/2 x'Qx
    q_cols: Vec<i32>,
    q_rows: Vec<i32>,
    q_vals: Vec<f64>,
    // quadratic constraints, mapped onto CPXaddqconstr (literal, no 1/2)
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

/// Wire form of a piecewise-linear definition, mapped onto CPXaddpwl with
/// pre/post slopes computed from the first/last segments (matching the
/// neutral end-segment extension semantics and Gurobi's native behavior).
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Pwl"]
struct PwlDef {
    res_col: i32,
    arg_col: i32,
    xs: Vec<f64>,
    ys: Vec<f64>,
}

// CPLEX has no min/max general constraint; any input carrying one is
// rejected by the firewall (the Elixir capability check already refuses it;
// this is the backstop)
#[derive(NifStruct)]
#[module = "Optex.SolverInput.MinMax"]
struct MinMaxDef {
    res_col: i32,
    op: Atom,
    arg_cols: Vec<i32>,
    constant: Option<f64>,
}

/// Wire form of a second-order cone (heads guaranteed lb >= 0 by the model
/// layer), mapped onto a SOC-shaped CPXaddqconstr.
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Cone"]
struct ConeRow {
    cone_type: Atom, // :quad | :rquad
    head_cols: Vec<i32>,
    member_cols: Vec<i32>,
}

/// Wire form of a special ordered set, mapped onto CPXaddsos.
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Sos"]
struct SosRow {
    sos_type: Atom, // :sos1 | :sos2
    cols: Vec<i32>,
    weights: Vec<f64>,
}

#[derive(NifStruct)]
#[module = "Optex.Solver.CPLEX.Options"]
struct SolveOptions {
    // CPLEX parameters are numeric ids; the binding module owns the mapping
    int_params: Vec<(i32, i32)>,
    dbl_params: Vec<(i32, f64)>,
    log_pid: Option<LocalPid>,
    cancel: Option<ResourceArc<CancelToken>>,
}

#[derive(NifStruct)]
#[module = "Optex.SolveResult"]
struct SolveResult {
    status: i32, // raw CPXgetstat code; decoded on the Elixir side
    objective: Option<f64>,
    values: Vec<f64>,
    col_duals: Vec<f64>,
    row_duals: Vec<f64>,
    dual_status: i32,
    // always None: the CPLEX C API exposes qconstraint slacks but no dual
    // multipliers; the field exists so Optex.SolveResult encodes fully
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
    // construct positions exist for the shared struct shape; the conflict
    // refiner here reports rows/cols only, so CPLEX never fills them
    indicators: Vec<i32>,
    abs_defs: Vec<i32>,
    minmax_defs: Vec<i32>,
    pwl_defs: Vec<i32>,
    qconstraints: Vec<i32>,
    cones: Vec<i32>,
    soss: Vec<i32>,
}

// ---------------------------------------------------------------------------
// Log streaming (same rules as the other crates: the channel message
// function runs on the solving thread, so it only pushes into an mpsc
// channel; an unmanaged thread does the sending)
// ---------------------------------------------------------------------------

struct LogCtx {
    tx: std::sync::mpsc::Sender<String>,
}

fn spawn_log_sender(
    pid: LocalPid,
) -> (std::sync::mpsc::Sender<String>, std::thread::JoinHandle<()>) {
    let (tx, rx) = std::sync::mpsc::channel::<String>();

    let handle = std::thread::spawn(move || {
        while let Ok(line) = rx.recv() {
            let mut env = OwnedEnv::new();
            let _ =
                env.send_and_clear(&pid, |e| (atoms::optex_cplex_log(), line.as_str()).encode(e));
        }
    });

    (tx, handle)
}

extern "C" fn channel_msg(handle: *mut c_void, message: *const c_char) {
    if handle.is_null() || message.is_null() {
        return;
    }
    let ctx = unsafe { &*(handle as *const LogCtx) };

    let text = unsafe { std::ffi::CStr::from_ptr(message) }
        .to_string_lossy()
        .trim_end()
        .to_string();

    if !text.is_empty() {
        let _ = ctx.tx.send(text);
    }
}

#[rustler::nif]
fn cancel_token() -> ResourceArc<CancelToken> {
    ResourceArc::new(CancelToken {
        flag: AtomicI32::new(0),
    })
}

#[rustler::nif]
fn cancel(token: ResourceArc<CancelToken>) -> Atom {
    token.flag.store(1, Ordering::Relaxed);
    atoms::ok()
}

// ---------------------------------------------------------------------------
// Shared setup
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

    for (res, arg) in &input.abs_defs {
        if *res < 0 || *res as usize >= n || *arg < 0 || *arg as usize >= n {
            return Err("invalid abs definition".into());
        }
    }

    if !input.minmax_defs.is_empty() {
        return Err("CPLEX does not support min/max general constraints".into());
    }

    for pwl in &input.pwl_defs {
        // non-decreasing xs; a repeated x is a jump: exactly two points,
        // different ys, interior only (the end segments must be real
        // segments because the pre/post slopes divide by their width).
        // Mirrors Optex.Model.validate_points!.
        if pwl.res_col < 0
            || pwl.res_col as usize >= n
            || pwl.arg_col < 0
            || pwl.arg_col as usize >= n
            || pwl.xs.len() != pwl.ys.len()
            || pwl.xs.len() < 2
            || pwl.xs.windows(2).any(|w| w[0] > w[1])
            || pwl.xs.windows(3).any(|w| w[0] == w[1] && w[1] == w[2])
            || (0..pwl.xs.len() - 1)
                .any(|i| pwl.xs[i] == pwl.xs[i + 1] && pwl.ys[i] == pwl.ys[i + 1])
            || pwl.xs[0] == pwl.xs[1]
            || pwl.xs[pwl.xs.len() - 2] == pwl.xs[pwl.xs.len() - 1]
            || pwl.xs.iter().chain(pwl.ys.iter()).any(|v| !v.is_finite())
        {
            return Err("invalid pwl definition".into());
        }
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

/// Build CPLEX's full symmetric Q in CSC form. CPLEX's objective is
/// c'x + 1/2 x'Qx, so literal coefficients convert as Q_ii = 2*c_ii on the
/// diagonal and Q_ij = Q_ji = c_ij off it.
fn build_full_quad(input: &SolverInput, n: usize) -> (Vec<c_int>, Vec<c_int>, Vec<c_int>, Vec<f64>) {
    let mut cols: Vec<Vec<(c_int, f64)>> = vec![Vec::new(); n];

    for ((c, r), v) in input
        .q_cols
        .iter()
        .zip(input.q_rows.iter())
        .zip(input.q_vals.iter())
        .map(|((c, r), v)| ((*c, *r), *v))
    {
        if c == r {
            cols[c as usize].push((r, 2.0 * v));
        } else {
            cols[c as usize].push((r, v));
            cols[r as usize].push((c, v));
        }
    }

    let mut qmatbeg = Vec::with_capacity(n);
    let mut qmatcnt = Vec::with_capacity(n);
    let mut qmatind = Vec::new();
    let mut qmatval = Vec::new();

    for col in cols.iter_mut() {
        col.sort_by_key(|(r, _)| *r);
        qmatbeg.push(qmatind.len() as c_int);
        qmatcnt.push(col.len() as c_int);

        for (r, v) in col.iter() {
            qmatind.push(*r);
            qmatval.push(*v);
        }
    }

    (qmatbeg, qmatcnt, qmatind, qmatval)
}

fn sense_char(sense: Atom) -> Result<u8, String> {
    if sense == atoms::le() {
        Ok(b'L')
    } else if sense == atoms::ge() {
        Ok(b'G')
    } else if sense == atoms::eq() {
        Ok(b'E')
    } else {
        Err("unknown indicator sense".into())
    }
}

/// Owns every array CPXcopylp reads for the duration of the call (4).
struct ModelArrays {
    obj: Vec<f64>,
    rhs: Vec<f64>,
    sense: Vec<c_char>,
    rngval: Vec<f64>,
    matbeg: Vec<c_int>,
    matcnt: Vec<c_int>,
    matind: Vec<c_int>,
    matval: Vec<f64>,
    lb: Vec<f64>,
    ub: Vec<f64>,
    ctype: Vec<c_char>,
    is_mip: bool,
}

/// CPLEX rows are sense+rhs, with native ranged rows: sense 'R' bounds the
/// activity to [rhs, rhs + rngval]. Every SolverInput row maps, including
/// genuine two-sided ranges (unlike the Gurobi backend).
fn to_arrays(input: &SolverInput, n: usize, m: usize) -> Result<ModelArrays, String> {
    let mut sense = Vec::with_capacity(m);
    let mut rhs = Vec::with_capacity(m);
    let mut rngval = vec![0.0_f64; m];

    for i in 0..m {
        let (s, r) = match (input.row_lb[i], input.row_ub[i]) {
            (Bound::NegInf, Bound::Num(u)) => (b'L', u),
            (Bound::Num(l), Bound::PosInf) => (b'G', l),
            (Bound::Num(l), Bound::Num(u)) if l == u => (b'E', l),
            (Bound::Num(l), Bound::Num(u)) if l < u => {
                rngval[i] = u - l;
                (b'R', l)
            }
            (Bound::NegInf, Bound::PosInf) => (b'L', CPX_INFBOUND),
            _ => return Err("inconsistent row bounds".into()),
        };

        sense.push(s as c_char);
        rhs.push(r);
    }

    let mut ctype = Vec::with_capacity(n);
    let mut is_mip = false;
    for t in &input.col_type {
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

    // indicator, PWL, and SOS constructs force the MIP optimizer even for
    // all-continuous columns (CPXlpopt cannot handle them)
    let is_mip = is_mip
        || !input.indicators.is_empty()
        || !input.abs_defs.is_empty()
        || !input.pwl_defs.is_empty()
        || !input.soss.is_empty();

    let matcnt = (0..n)
        .map(|j| input.col_start[j + 1] - input.col_start[j])
        .collect();

    Ok(ModelArrays {
        obj: input.obj.clone(),
        rhs,
        sense,
        rngval,
        matbeg: input.col_start[..n].to_vec(),
        matcnt,
        matind: input.row_index.clone(),
        matval: input.values.clone(),
        lb: input.col_lb.iter().map(|b| b.resolve(CPX_INFBOUND)).collect(),
        ub: input.col_ub.iter().map(|b| b.resolve(CPX_INFBOUND)).collect(),
        ctype,
        is_mip,
    })
}

unsafe fn cpx_error(env: *mut CPXenv, code: c_int, context: &str) -> String {
    let mut buffer = [0 as c_char; CPXMESSAGEBUFSIZE];
    let ptr = CPXgeterrorstring(env, code, buffer.as_mut_ptr());
    if ptr.is_null() {
        format!("{context} (code {code})")
    } else {
        format!(
            "{context}: {}",
            std::ffi::CStr::from_ptr(ptr).to_string_lossy().trim_end()
        )
    }
}

unsafe fn close_all(env: *mut CPXenv, lp: *mut CPXlp) {
    let mut lp = lp;
    CPXfreeprob(env, &mut lp);
    let mut env = env;
    CPXcloseCPLEX(&mut env);
}

/// Open the env (license check happens here), apply params, create the
/// problem, and copy the whole model. On error everything created so far is
/// freed.
unsafe fn open_model(
    input: &SolverInput,
    arrays: &ModelArrays,
    n: usize,
    m: usize,
    int_params: &[(i32, i32)],
    dbl_params: &[(i32, f64)],
) -> Result<(*mut CPXenv, *mut CPXlp), String> {
    if !input.cones.is_empty() {
        // temporary backstop: removed when the cone mapping lands
        return Err("cones not yet mapped on this backend".into());
    }

    let mut status: c_int = 0;
    let env = CPXopenCPLEX(&mut status);
    if env.is_null() {
        return Err(format!(
            "CPXopenCPLEX failed (code {status}); is the CPLEX license valid?"
        ));
    }

    for (id, v) in int_params {
        if CPXsetintparam(env, *id, *v) != 0 {
            let e = format!("invalid solver option (param {id})");
            let mut env = env;
            CPXcloseCPLEX(&mut env);
            return Err(e);
        }
    }

    for (id, v) in dbl_params {
        if CPXsetdblparam(env, *id, *v) != 0 {
            let e = format!("invalid solver option (param {id})");
            let mut env = env;
            CPXcloseCPLEX(&mut env);
            return Err(e);
        }
    }

    let name = std::ffi::CString::new("optex").unwrap();
    let lp = CPXcreateprob(env, &mut status, name.as_ptr());
    if lp.is_null() {
        let e = cpx_error(env, status, "CPXcreateprob failed");
        let mut env = env;
        CPXcloseCPLEX(&mut env);
        return Err(e);
    }

    let objsense = if input.sense == atoms::min() {
        CPX_MIN
    } else {
        CPX_MAX
    };

    let rc = CPXcopylp(
        env,
        lp,
        n as c_int,
        m as c_int,
        objsense,
        arrays.obj.as_ptr(),
        arrays.rhs.as_ptr(),
        arrays.sense.as_ptr(),
        arrays.matbeg.as_ptr(),
        arrays.matcnt.as_ptr(),
        arrays.matind.as_ptr(),
        arrays.matval.as_ptr(),
        arrays.lb.as_ptr(),
        arrays.ub.as_ptr(),
        arrays.rngval.as_ptr(),
    );

    if rc != 0 {
        let e = cpx_error(env, rc, "CPXcopylp failed");
        close_all(env, lp);
        return Err(e);
    }

    if input.obj_offset != 0.0 {
        let rc = CPXchgobjoffset(env, lp, input.obj_offset);
        if rc != 0 {
            let e = cpx_error(env, rc, "CPXchgobjoffset failed");
            close_all(env, lp);
            return Err(e);
        }
    }

    // copying a ctype array makes the problem a MIP even if all-continuous,
    // which would break CPXlpopt; only copy it when integrality exists
    if arrays.is_mip {
        let rc = CPXcopyctype(env, lp, arrays.ctype.as_ptr());
        if rc != 0 {
            let e = cpx_error(env, rc, "CPXcopyctype failed");
            close_all(env, lp);
            return Err(e);
        }
    }

    // native general constraints, mapped onto CPXaddindconstr and abs as a
    // native piecewise-linear (slopes -1/+1, single breakpoint at the
    // origin); all range-checked by the firewall
    for ind in &input.indicators {
        let sense = match sense_char(ind.sense) {
            Ok(s) => s,
            Err(e) => {
                close_all(env, lp);
                return Err(e);
            }
        };

        let rc = CPXaddindconstr(
            env,
            lp,
            ind.bin_col,
            1 - ind.active_value,
            ind.cols.len() as c_int,
            ind.rhs,
            sense as c_int,
            ind.cols.as_ptr(),
            ind.coefs.as_ptr(),
            std::ptr::null(),
        );

        if rc != 0 {
            let e = cpx_error(env, rc, "CPXaddindconstr failed");
            close_all(env, lp);
            return Err(e);
        }
    }

    let origin = [0.0_f64];
    for (res, arg) in &input.abs_defs {
        let rc = CPXaddpwl(
            env,
            lp,
            *res,
            *arg,
            -1.0,
            1.0,
            1,
            origin.as_ptr(),
            origin.as_ptr(),
            std::ptr::null(),
        );

        if rc != 0 {
            let e = cpx_error(env, rc, "CPXaddpwl failed");
            close_all(env, lp);
            return Err(e);
        }
    }

    if !input.q_vals.is_empty() {
        let (qmatbeg, qmatcnt, qmatind, qmatval) = build_full_quad(input, n);
        let rc = CPXcopyquad(
            env,
            lp,
            qmatbeg.as_ptr(),
            qmatcnt.as_ptr(),
            qmatind.as_ptr(),
            qmatval.as_ptr(),
        );

        if rc != 0 {
            let e = cpx_error(env, rc, "CPXcopyquad failed");
            close_all(env, lp);
            return Err(e);
        }
    }

    for qc in &input.qconstraints {
        let sense = match sense_char(qc.sense) {
            Ok(s) => s,
            Err(e) => {
                close_all(env, lp);
                return Err(e);
            }
        };

        let rc = CPXaddqconstr(
            env,
            lp,
            qc.lin_cols.len() as c_int,
            qc.q_vals.len() as c_int,
            qc.rhs,
            sense as c_int,
            qc.lin_cols.as_ptr(),
            qc.lin_coefs.as_ptr(),
            qc.q_rows.as_ptr(),
            qc.q_cols.as_ptr(),
            qc.q_vals.as_ptr(),
            std::ptr::null(),
        );

        if rc != 0 {
            let e = cpx_error(env, rc, "CPXaddqconstr failed");
            close_all(env, lp);
            return Err(e);
        }
    }

    for pwl in &input.pwl_defs {
        // end-segment extension: pre/post slopes come from the first and
        // last segments (the firewall guarantees those two are real
        // segments, never jumps, so the divisions are safe; interior
        // repeated xs are CPXaddpwl's own discontinuity encoding)
        let k = pwl.xs.len();
        let preslope = (pwl.ys[1] - pwl.ys[0]) / (pwl.xs[1] - pwl.xs[0]);
        let postslope = (pwl.ys[k - 1] - pwl.ys[k - 2]) / (pwl.xs[k - 1] - pwl.xs[k - 2]);

        let rc = CPXaddpwl(
            env,
            lp,
            pwl.res_col,
            pwl.arg_col,
            preslope,
            postslope,
            k as c_int,
            pwl.xs.as_ptr(),
            pwl.ys.as_ptr(),
            std::ptr::null(),
        );

        if rc != 0 {
            let e = cpx_error(env, rc, "CPXaddpwl failed");
            close_all(env, lp);
            return Err(e);
        }
    }

    // SOS sets, batch call (types are the chars '1'/'2', CPX_TYPE_SOS1/2)
    if !input.soss.is_empty() {
        let mut types: Vec<c_char> = Vec::with_capacity(input.soss.len());
        let mut beg: Vec<c_int> = Vec::with_capacity(input.soss.len());
        let mut ind: Vec<c_int> = vec![];
        let mut wt: Vec<f64> = vec![];

        for sos in &input.soss {
            types.push(if sos.sos_type == atoms::sos1() {
                b'1' as c_char
            } else {
                b'2' as c_char
            });
            beg.push(ind.len() as c_int);
            ind.extend_from_slice(&sos.cols);
            wt.extend_from_slice(&sos.weights);
        }

        let rc = CPXaddsos(
            env,
            lp,
            input.soss.len() as c_int,
            ind.len() as c_int,
            types.as_ptr(),
            beg.as_ptr(),
            ind.as_ptr(),
            wt.as_ptr(),
            std::ptr::null_mut(),
        );

        if rc != 0 {
            let e = cpx_error(env, rc, "CPXaddsos failed");
            close_all(env, lp);
            return Err(e);
        }
    }

    Ok((env, lp))
}

unsafe fn optimize(
    env: *mut CPXenv,
    lp: *mut CPXlp,
    is_mip: bool,
    has_quad_obj: bool,
    has_qcon: bool,
) -> c_int {
    if is_mip {
        CPXmipopt(env, lp)
    } else if has_qcon {
        // continuous quadratically constrained problems use the barrier
        CPXbaropt(env, lp)
    } else if has_quad_obj {
        // a continuous quadratic objective needs the QP optimizer
        CPXqpopt(env, lp)
    } else {
        CPXlpopt(env, lp)
    }
}

// ---------------------------------------------------------------------------
// NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn solve(input: SolverInput, options: SolveOptions) -> Result<SolveResult, String> {
    let (n, m, _nnz) = validate(&input)?;
    let arrays = to_arrays(&input, n, m)?;

    let (log_ctx, log_handle) = match &options.log_pid {
        Some(pid) => {
            let (tx, handle) = spawn_log_sender(pid.clone());
            (Some(Box::new(LogCtx { tx })), Some(handle))
        }
        None => (None, None),
    };

    unsafe {
        let (env, lp) = open_model(
            &input,
            &arrays,
            n,
            m,
            &options.int_params,
            &options.dbl_params,
        )?;

        // hook every message channel; the ctx Box outlives the env (4)
        if let Some(ctx) = &log_ctx {
            let mut results: *mut CPXchannel = std::ptr::null_mut();
            let mut warning: *mut CPXchannel = std::ptr::null_mut();
            let mut error: *mut CPXchannel = std::ptr::null_mut();
            let mut log: *mut CPXchannel = std::ptr::null_mut();

            if CPXgetchannels(env, &mut results, &mut warning, &mut error, &mut log) == 0 {
                for ch in [results, warning, error, log] {
                    if !ch.is_null() {
                        CPXaddfuncdest(env, ch, ctx.as_ref() as *const LogCtx as *mut c_void, channel_msg);
                    }
                }
            }
        }

        // the token's int outlives the call via the ResourceArc in options
        if let Some(token) = &options.cancel {
            CPXsetterminate(env, token.flag.as_ptr());
        }

        let started = std::time::Instant::now();
        let rc = optimize(env, lp, arrays.is_mip, !input.q_vals.is_empty(), !input.qconstraints.is_empty());
        let solve_time = started.elapsed().as_secs_f64();

        if rc != 0 {
            let e = cpx_error(env, rc, "optimize failed");
            close_all(env, lp); // (2)
            return Err(e);
        }

        let status = CPXgetstat(env, lp);

        // (3) exact-size output buffers; unavailable arrays report zeros
        let mut values = vec![0.0_f64; n];
        if n > 0 && CPXgetx(env, lp, values.as_mut_ptr(), 0, n as c_int - 1) != 0 {
            values = vec![0.0; n];
        }

        // duals exist only for pure LPs with a solved basis
        let mut dual_status = 0;
        let mut row_duals = vec![0.0_f64; m];
        let mut col_duals = vec![0.0_f64; n];

        if !arrays.is_mip {
            let pi_ok = m == 0 || CPXgetpi(env, lp, row_duals.as_mut_ptr(), 0, m as c_int - 1) == 0;
            let dj_ok = n == 0 || CPXgetdj(env, lp, col_duals.as_mut_ptr(), 0, n as c_int - 1) == 0;

            if pi_ok && dj_ok {
                dual_status = 2;
            } else {
                row_duals = vec![0.0; m];
                col_duals = vec![0.0; n];
            }
        }

        let mut raw_obj = f64::NAN;
        let objective = if CPXgetobjval(env, lp, &mut raw_obj) == 0 && raw_obj.is_finite() {
            Some(raw_obj)
        } else {
            None
        };

        let (simplex_iterations, nodes, mip_gap) = if arrays.is_mip {
            let mut gap = f64::NAN;
            let gap = if CPXgetmiprelgap(env, lp, &mut gap) == 0 && gap.is_finite() {
                Some(gap)
            } else {
                None
            };
            (
                CPXgetmipitcnt(env, lp),
                CPXgetnodecnt(env, lp) as i64,
                gap,
            )
        } else {
            (CPXgetitcnt(env, lp), 0, None)
        };

        close_all(env, lp); // (2) free on success

        drop(log_ctx);
        if let Some(handle) = log_handle {
            let _ = handle.join();
        }

        Ok(SolveResult {
            status,
            objective,
            values,
            col_duals,
            row_duals,
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
    let (n, m, _nnz) = validate(&input)?;
    let arrays = to_arrays(&input, n, m)?;

    unsafe {
        let (env, lp) = open_model(&input, &arrays, n, m, &[], &[])?;

        let rc = optimize(env, lp, arrays.is_mip, !input.q_vals.is_empty(), !input.qconstraints.is_empty());
        if rc != 0 {
            let e = cpx_error(env, rc, "optimize failed");
            close_all(env, lp); // (2)
            return Err(e);
        }

        if !INFEASIBLE_STATUSES.contains(&CPXgetstat(env, lp)) {
            close_all(env, lp); // (2)
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

        let mut confnumrows: c_int = 0;
        let mut confnumcols: c_int = 0;
        let rc = CPXrefineconflict(env, lp, &mut confnumrows, &mut confnumcols);
        if rc != 0 {
            let e = cpx_error(env, rc, "CPXrefineconflict failed");
            close_all(env, lp); // (2)
            return Err(e);
        }

        // (3) the conflict is a subset of the original rows/cols, so n and m
        // are exact upper bounds
        let mut confstat: c_int = 0;
        let mut rowind = vec![0 as c_int; m];
        let mut rowbdstat = vec![0 as c_int; m];
        let mut nrows: c_int = 0;
        let mut colind = vec![0 as c_int; n];
        let mut colbdstat = vec![0 as c_int; n];
        let mut ncols: c_int = 0;

        let rc = CPXgetconflict(
            env,
            lp,
            &mut confstat,
            rowind.as_mut_ptr(),
            rowbdstat.as_mut_ptr(),
            &mut nrows,
            colind.as_mut_ptr(),
            colbdstat.as_mut_ptr(),
            &mut ncols,
        );

        close_all(env, lp); // (2) single exit after this point

        if rc != 0 {
            return Err("CPXgetconflict failed".into());
        }

        if nrows < 0 || nrows as usize > m || ncols < 0 || ncols as usize > n {
            return Err("CPXgetconflict returned out-of-range counts".into());
        }

        // shared member-status convention: 2 lower, 3 upper, 4 boxed; row
        // involvement follows the row's own sense
        let mut rows = vec![];
        let mut row_statuses = vec![];
        for k in 0..nrows as usize {
            if rowbdstat[k] >= CONFLICT_MEMBER {
                rows.push(rowind[k]);
                let i = rowind[k] as usize;
                row_statuses.push(match arrays.sense.get(i).map(|c| *c as u8) {
                    Some(b'L') => 3,
                    Some(b'G') => 2,
                    _ => 4,
                });
            }
        }

        let mut cols = vec![];
        let mut col_statuses = vec![];
        for k in 0..ncols as usize {
            let s = colbdstat[k];
            if s >= CONFLICT_MEMBER {
                cols.push(colind[k]);
                col_statuses.push(match s {
                    CONFLICT_LB => 2,
                    CONFLICT_UB => 3,
                    _ => 4,
                });
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

rustler::init!("Elixir.Optex.Solver.CPLEX.Native");
