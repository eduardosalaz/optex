//! The Gurobi binding: dirty NIFs mirroring the HiGHS crate's contract.
//! FFI declarations are hand-rolled against the installed Gurobi 13.0
//! gurobi_c.h (every signature verified; see DECISIONS.md). The same four
//! safety requirements as the HiGHS binding apply: length firewall before
//! any pointer crosses, free env/model on every exit path, exact-size
//! output buffers, inputs owned by locals for the whole call.

use rustler::{Atom, Encoder, LocalPid, NifResult, NifStruct, OwnedEnv, Resource, ResourceArc, Term};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicBool, Ordering};

mod atoms {
    rustler::atoms! { min, max, infinity, neg_infinity, ok, optex_gurobi_log, le, ge, eq, quad, rquad, sos1, sos2 }
}

// ---------------------------------------------------------------------------
// FFI (verified against Gurobi 13.0.0 gurobi_c.h)
// ---------------------------------------------------------------------------

#[allow(non_camel_case_types)]
pub enum GRBenv {}
#[allow(non_camel_case_types)]
pub enum GRBmodel {}

// GRB_INFINITY, sense/status constants from gurobi_c.h 13.0
const GRB_INFINITY: f64 = 1e100;
const GRB_MINIMIZE: c_int = 1;
const GRB_MAXIMIZE: c_int = -1;
const GRB_STATUS_INFEASIBLE: c_int = 3;
const GRB_CB_MESSAGE: c_int = 6;
const GRB_CB_MSG_STRING: c_int = 6001;

extern "C" {
    // GRBemptyenv/GRBloadenv are macros baking in the client version; the
    // real symbol takes it explicitly. We pass the verified 13.0.0 triple.
    fn GRBemptyenvinternal(env_p: *mut *mut GRBenv, major: c_int, minor: c_int, tech: c_int)
        -> c_int;
    fn GRBstartenv(env: *mut GRBenv) -> c_int;
    fn GRBfreeenv(env: *mut GRBenv);
    fn GRBgeterrormsg(env: *mut GRBenv) -> *const c_char;

    fn GRBsetintparam(env: *mut GRBenv, paramname: *const c_char, value: c_int) -> c_int;
    fn GRBsetdblparam(env: *mut GRBenv, paramname: *const c_char, value: f64) -> c_int;

    fn GRBloadmodel(
        env: *mut GRBenv,
        model_p: *mut *mut GRBmodel,
        pname: *const c_char,
        numvars: c_int,
        numconstrs: c_int,
        objsense: c_int,
        objcon: f64,
        obj: *mut f64,
        sense: *mut c_char,
        rhs: *mut f64,
        vbeg: *mut c_int,
        vlen: *mut c_int,
        vind: *mut c_int,
        vval: *mut f64,
        lb: *mut f64,
        ub: *mut f64,
        vtype: *mut c_char,
        varnames: *mut *mut c_char,
        constrnames: *mut *mut c_char,
    ) -> c_int;
    fn GRBfreemodel(model: *mut GRBmodel) -> c_int;

    fn GRBoptimize(model: *mut GRBmodel) -> c_int;
    fn GRBterminate(model: *mut GRBmodel);
    fn GRBcomputeIIS(model: *mut GRBmodel) -> c_int;

    fn GRBaddgenconstrIndicator(
        model: *mut GRBmodel,
        name: *const c_char,
        binvar: c_int,
        binval: c_int,
        nvars: c_int,
        vars: *const c_int,
        vals: *const f64,
        sense: c_char,
        rhs: f64,
    ) -> c_int;
    fn GRBaddgenconstrAbs(
        model: *mut GRBmodel,
        name: *const c_char,
        resvar: c_int,
        argvar: c_int,
    ) -> c_int;
    fn GRBaddgenconstrPWL(
        model: *mut GRBmodel,
        name: *const c_char,
        xvar: c_int,
        yvar: c_int,
        npts: c_int,
        xpts: *const f64,
        ypts: *const f64,
    ) -> c_int;
    // resvar = max/min(vars..., constant); verified against gurobi_c.h 13.0
    fn GRBaddgenconstrMax(
        model: *mut GRBmodel,
        name: *const c_char,
        resvar: c_int,
        nvars: c_int,
        vars: *const c_int,
        constant: f64,
    ) -> c_int;
    fn GRBaddgenconstrMin(
        model: *mut GRBmodel,
        name: *const c_char,
        resvar: c_int,
        nvars: c_int,
        vars: *const c_int,
        constant: f64,
    ) -> c_int;
    // special ordered sets, batch form; verified against gurobi_c.h 13.0
    // (types are ints 1/2, weights define the order)
    fn GRBaddsos(
        model: *mut GRBmodel,
        numsos: c_int,
        nummembers: c_int,
        types: *mut c_int,
        beg: *mut c_int,
        ind: *mut c_int,
        weight: *mut f64,
    ) -> c_int;
    // objective += sum qval[k] * x[qrow[k]] * x[qcol[k]], literal
    fn GRBaddqpterms(
        model: *mut GRBmodel,
        numqnz: c_int,
        qrow: *const c_int,
        qcol: *const c_int,
        qval: *const f64,
    ) -> c_int;
    // quadratic constraint, literal coefficients on both parts
    fn GRBaddqconstr(
        model: *mut GRBmodel,
        numlnz: c_int,
        lind: *const c_int,
        lval: *const f64,
        numqnz: c_int,
        qrow: *const c_int,
        qcol: *const c_int,
        qval: *const f64,
        sense: c_char,
        rhs: f64,
        qcname: *const c_char,
    ) -> c_int;

    fn GRBsetcallbackfunc(
        model: *mut GRBmodel,
        cb: Option<
            extern "C" fn(*mut GRBmodel, *mut c_void, c_int, *mut c_void) -> c_int,
        >,
        usrdata: *mut c_void,
    ) -> c_int;
    fn GRBcbget(cbdata: *mut c_void, wherefrom: c_int, what: c_int, result_p: *mut c_void)
        -> c_int;

    fn GRBgetintattr(model: *mut GRBmodel, attrname: *const c_char, value_p: *mut c_int) -> c_int;
    fn GRBgetdblattr(model: *mut GRBmodel, attrname: *const c_char, value_p: *mut f64) -> c_int;
    fn GRBgetdblattrarray(
        model: *mut GRBmodel,
        attrname: *const c_char,
        first: c_int,
        len: c_int,
        values: *mut f64,
    ) -> c_int;
    fn GRBgetintattrarray(
        model: *mut GRBmodel,
        attrname: *const c_char,
        first: c_int,
        len: c_int,
        values: *mut c_int,
    ) -> c_int;
}

// ---------------------------------------------------------------------------
// Wire structs (shared Elixir modules with the HiGHS crate where identical)
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

pub struct CancelToken {
    flag: AtomicBool,
}

#[rustler::resource_impl]
impl Resource for CancelToken {}

/// Wire form of a native indicator row, mapped 1:1 onto
/// GRBaddgenconstrIndicator.
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
    // quadratic objective as COO triplets, literal coefficients (which is
    // exactly GRBaddqpterms' convention), normalized q_cols[k] <= q_rows[k]
    q_cols: Vec<i32>,
    q_rows: Vec<i32>,
    q_vals: Vec<f64>,
    // quadratic constraints, mapped 1:1 onto GRBaddqconstr (also literal)
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

/// Wire form of a piecewise-linear definition, mapped onto
/// GRBaddgenconstrPWL (which extends the first and last segments beyond the
/// breakpoint range, matching the neutral semantics).
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Pwl"]
struct PwlDef {
    res_col: i32,
    arg_col: i32,
    xs: Vec<f64>,
    ys: Vec<f64>,
}

/// Wire form of a min/max definition, mapped onto GRBaddgenconstrMax/Min.
/// A nil constant becomes the operation's identity (an operand that never
/// wins) so the C argument can always be passed.
#[derive(NifStruct)]
#[module = "Optex.SolverInput.MinMax"]
struct MinMaxDef {
    res_col: i32,
    op: Atom, // :min | :max, the neutral atoms
    arg_cols: Vec<i32>,
    constant: Option<f64>,
}

/// Wire form of a second-order cone (heads guaranteed lb >= 0 by the model
/// layer), mapped onto a SOC-shaped GRBaddqconstr: sum(member^2) - head^2
/// <= 0 (:quad) or sum(member^2) - 2*h1*h2 <= 0 (:rquad).
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Cone"]
struct ConeRow {
    cone_type: Atom, // :quad | :rquad
    head_cols: Vec<i32>,
    member_cols: Vec<i32>,
}

/// Wire form of a special ordered set, mapped onto GRBaddsos.
#[derive(NifStruct)]
#[module = "Optex.SolverInput.Sos"]
struct SosRow {
    sos_type: Atom, // :sos1 | :sos2
    cols: Vec<i32>,
    weights: Vec<f64>,
}

#[derive(NifStruct)]
#[module = "Optex.Solver.Gurobi.Options"]
struct SolveOptions {
    int_params: Vec<(String, i32)>,
    dbl_params: Vec<(String, f64)>,
    log_pid: Option<LocalPid>,
    cancel: Option<ResourceArc<CancelToken>>,
    // fetch QCPi after the solve; the QCPDual=1 param that makes Gurobi
    // compute them arrives through int_params like any other parameter
    qcp_duals: bool,
}

#[derive(NifStruct)]
#[module = "Optex.SolveResult"]
struct SolveResult {
    status: i32, // raw Gurobi Status attr; decoded on the Elixir side
    objective: Option<f64>,
    values: Vec<f64>,
    col_duals: Vec<f64>,
    row_duals: Vec<f64>,
    dual_status: i32, // 2 when Pi/RC were available (LP), 0 otherwise
    // QCPi per quadratic constraint, in wire order; None unless requested
    // via qcp_duals and available (continuous QCP with QCPDual=1)
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
    col_statuses: Vec<i32>, // 2 lower, 3 upper, 4 boxed (HiGHS-compatible ints)
    rows: Vec<i32>,
    row_statuses: Vec<i32>,
    // construct members of the IIS as positions in each kind's wire order
    // (IISGenConstr split by the known addition order, IISQConstr;
    // both verified against gurobi_c.h 13.0)
    indicators: Vec<i32>,
    abs_defs: Vec<i32>,
    minmax_defs: Vec<i32>,
    pwl_defs: Vec<i32>,
    qconstraints: Vec<i32>,
    cones: Vec<i32>,
    soss: Vec<i32>,
}

// ---------------------------------------------------------------------------
// Callback plumbing (same rules as the HiGHS crate: nothing that can panic,
// log lines go through a channel drained by an unmanaged thread)
// ---------------------------------------------------------------------------

struct CallbackCtx {
    cancel: Option<ResourceArc<CancelToken>>,
    log_tx: Option<std::sync::mpsc::Sender<String>>,
}

fn spawn_log_sender(
    pid: LocalPid,
) -> (std::sync::mpsc::Sender<String>, std::thread::JoinHandle<()>) {
    let (tx, rx) = std::sync::mpsc::channel::<String>();

    let handle = std::thread::spawn(move || {
        while let Ok(line) = rx.recv() {
            let mut env = OwnedEnv::new();
            let _ =
                env.send_and_clear(&pid, |e| (atoms::optex_gurobi_log(), line.as_str()).encode(e));
        }
    });

    (tx, handle)
}

extern "C" fn gurobi_callback(
    model: *mut GRBmodel,
    cbdata: *mut c_void,
    wherefrom: c_int,
    usrdata: *mut c_void,
) -> c_int {
    if usrdata.is_null() {
        return 0;
    }
    let ctx = unsafe { &*(usrdata as *const CallbackCtx) };

    if let Some(token) = &ctx.cancel {
        if token.flag.load(Ordering::Relaxed) {
            // documented as safe to call from within a callback
            unsafe { GRBterminate(model) };
        }
    }

    if wherefrom == GRB_CB_MESSAGE {
        if let Some(tx) = &ctx.log_tx {
            let mut msg: *const c_char = std::ptr::null();
            let rc = unsafe {
                GRBcbget(
                    cbdata,
                    wherefrom,
                    GRB_CB_MSG_STRING,
                    &mut msg as *mut *const c_char as *mut c_void,
                )
            };

            if rc == 0 && !msg.is_null() {
                let text = unsafe { std::ffi::CStr::from_ptr(msg) }
                    .to_string_lossy()
                    .trim_end()
                    .to_string();

                if !text.is_empty() {
                    let _ = tx.send(text);
                }
            }
        }
    }

    0
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

// ---------------------------------------------------------------------------
// Shared setup
// ---------------------------------------------------------------------------

// (1) length firewall - identical to the HiGHS crate's
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

    for mm in &input.minmax_defs {
        if mm.res_col < 0
            || mm.res_col as usize >= n
            || mm.arg_cols.is_empty()
            || mm.arg_cols.iter().any(|c| *c < 0 || *c as usize >= n)
            || mm.constant.map_or(false, |c| !c.is_finite())
        {
            return Err("invalid min/max definition".into());
        }
    }

    for pwl in &input.pwl_defs {
        // non-decreasing xs; a repeated x is a jump: exactly two points,
        // different ys, interior only (the end segments define the
        // extension slopes). Mirrors Optex.Model.validate_points!.
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

fn sense_char(sense: Atom) -> Result<u8, String> {
    if sense == atoms::le() {
        Ok(b'<')
    } else if sense == atoms::ge() {
        Ok(b'>')
    } else if sense == atoms::eq() {
        Ok(b'=')
    } else {
        Err("unknown indicator sense".into())
    }
}

/// Owns every array GRBloadmodel reads, so they stay alive for the call (4).
struct ModelArrays {
    obj: Vec<f64>,
    sense: Vec<c_char>,
    rhs: Vec<f64>,
    vbeg: Vec<c_int>,
    vlen: Vec<c_int>,
    vind: Vec<c_int>,
    vval: Vec<f64>,
    lb: Vec<f64>,
    ub: Vec<f64>,
    vtype: Vec<c_char>,
}

/// Gurobi rows are sense+rhs, not ranges. Everything Optex.Transform emits
/// maps cleanly; a genuine two-sided range (never produced by the transform
/// but representable in SolverInput) is rejected rather than silently split,
/// which would corrupt dual indexing.
fn to_arrays(input: &SolverInput, n: usize, m: usize) -> Result<ModelArrays, String> {
    let mut sense = Vec::with_capacity(m);
    let mut rhs = Vec::with_capacity(m);

    for i in 0..m {
        let (s, r) = match (input.row_lb[i], input.row_ub[i]) {
            (Bound::NegInf, Bound::Num(u)) => (b'<', u),
            (Bound::Num(l), Bound::PosInf) => (b'>', l),
            (Bound::Num(l), Bound::Num(u)) if l == u => (b'=', l),
            (Bound::NegInf, Bound::PosInf) => (b'<', GRB_INFINITY),
            (Bound::Num(_), Bound::Num(_)) => {
                return Err("ranged constraints are not supported by the Gurobi backend".into())
            }
            _ => return Err("inconsistent row bounds".into()),
        };

        sense.push(s as c_char);
        rhs.push(r);
    }

    let mut vtype = Vec::with_capacity(n);
    for t in &input.col_type {
        vtype.push(match t {
            0 => b'C' as c_char,
            1 => b'I' as c_char,
            2 => b'B' as c_char,
            _ => return Err("unknown variable type".into()),
        });
    }

    let vlen = (0..n)
        .map(|j| input.col_start[j + 1] - input.col_start[j])
        .collect();

    Ok(ModelArrays {
        obj: input.obj.clone(),
        sense,
        rhs,
        vbeg: input.col_start[..n].to_vec(),
        vlen,
        vind: input.row_index.clone(),
        vval: input.values.clone(),
        lb: input.col_lb.iter().map(|b| b.resolve(GRB_INFINITY)).collect(),
        ub: input.col_ub.iter().map(|b| b.resolve(GRB_INFINITY)).collect(),
        vtype,
    })
}

unsafe fn env_error(env: *mut GRBenv, context: &str) -> String {
    let msg = GRBgeterrormsg(env);
    if msg.is_null() {
        context.to_string()
    } else {
        format!("{context}: {}", std::ffi::CStr::from_ptr(msg).to_string_lossy())
    }
}

unsafe fn set_int_param(env: *mut GRBenv, name: &str, value: c_int) -> Result<(), String> {
    match std::ffi::CString::new(name) {
        Ok(c) if GRBsetintparam(env, c.as_ptr(), value) == 0 => Ok(()),
        _ => Err(format!("invalid solver option {name}")),
    }
}

unsafe fn set_dbl_param(env: *mut GRBenv, name: &str, value: f64) -> Result<(), String> {
    match std::ffi::CString::new(name) {
        Ok(c) if GRBsetdblparam(env, c.as_ptr(), value) == 0 => Ok(()),
        _ => Err(format!("invalid solver option {name}")),
    }
}

/// Create the env (client version 13.0.0, verified), apply params, start it
/// (license check happens here), and load the whole model. On error the env
/// is already freed.
unsafe fn open_model(
    input: &SolverInput,
    arrays: &mut ModelArrays,
    n: usize,
    m: usize,
    int_params: &[(String, i32)],
    dbl_params: &[(String, f64)],
) -> Result<(*mut GRBenv, *mut GRBmodel), String> {
    if !input.cones.is_empty() {
        // temporary backstop: removed when the cone mapping lands
        return Err("cones not yet mapped on this backend".into());
    }

    let mut env: *mut GRBenv = std::ptr::null_mut();
    if GRBemptyenvinternal(&mut env, 13, 0, 0) != 0 || env.is_null() {
        if !env.is_null() {
            GRBfreeenv(env);
        }
        return Err("GRBemptyenv failed (client/library version mismatch?)".into());
    }

    // silent by default; user params applied afterwards may override
    let setup = set_int_param(env, "OutputFlag", 0)
        .and_then(|_| {
            int_params
                .iter()
                .try_for_each(|(k, v)| set_int_param(env, k, *v))
        })
        .and_then(|_| {
            dbl_params
                .iter()
                .try_for_each(|(k, v)| set_dbl_param(env, k, *v))
        });

    if let Err(e) = setup {
        GRBfreeenv(env);
        return Err(e);
    }

    if GRBstartenv(env) != 0 {
        let e = env_error(env, "Gurobi environment start failed");
        GRBfreeenv(env);
        return Err(e);
    }

    let name = std::ffi::CString::new("optex").unwrap();
    let objsense = if input.sense == atoms::min() {
        GRB_MINIMIZE
    } else {
        GRB_MAXIMIZE
    };

    let mut model: *mut GRBmodel = std::ptr::null_mut();
    let rc = GRBloadmodel(
        env,
        &mut model,
        name.as_ptr(),
        n as c_int,
        m as c_int,
        objsense,
        input.obj_offset,
        arrays.obj.as_mut_ptr(),
        arrays.sense.as_mut_ptr(),
        arrays.rhs.as_mut_ptr(),
        arrays.vbeg.as_mut_ptr(),
        arrays.vlen.as_mut_ptr(),
        arrays.vind.as_mut_ptr(),
        arrays.vval.as_mut_ptr(),
        arrays.lb.as_mut_ptr(),
        arrays.ub.as_mut_ptr(),
        arrays.vtype.as_mut_ptr(),
        std::ptr::null_mut(),
        std::ptr::null_mut(),
    );

    if rc != 0 || model.is_null() {
        let e = env_error(env, "GRBloadmodel failed");
        if !model.is_null() {
            GRBfreemodel(model);
        }
        GRBfreeenv(env);
        return Err(e);
    }

    // native general constraints, mapped 1:1 (indicator rows and abs
    // definitions were range-checked by the firewall)
    for ind in &input.indicators {
        let sense = match sense_char(ind.sense) {
            Ok(s) => s,
            Err(e) => {
                free_all(env, model);
                return Err(e);
            }
        };

        let rc = GRBaddgenconstrIndicator(
            model,
            std::ptr::null(),
            ind.bin_col,
            ind.active_value,
            ind.cols.len() as c_int,
            ind.cols.as_ptr(),
            ind.coefs.as_ptr(),
            sense as c_char,
            ind.rhs,
        );

        if rc != 0 {
            let e = env_error(env, "GRBaddgenconstrIndicator failed");
            free_all(env, model);
            return Err(e);
        }
    }

    for (res, arg) in &input.abs_defs {
        if GRBaddgenconstrAbs(model, std::ptr::null(), *res, *arg) != 0 {
            let e = env_error(env, "GRBaddgenconstrAbs failed");
            free_all(env, model);
            return Err(e);
        }
    }

    for mm in &input.minmax_defs {
        // an absent constant becomes the operation's identity, an operand
        // that never wins: -infinity for max, +infinity for min
        let rc = if mm.op == atoms::max() {
            GRBaddgenconstrMax(
                model,
                std::ptr::null(),
                mm.res_col,
                mm.arg_cols.len() as c_int,
                mm.arg_cols.as_ptr(),
                mm.constant.unwrap_or(-GRB_INFINITY),
            )
        } else if mm.op == atoms::min() {
            GRBaddgenconstrMin(
                model,
                std::ptr::null(),
                mm.res_col,
                mm.arg_cols.len() as c_int,
                mm.arg_cols.as_ptr(),
                mm.constant.unwrap_or(GRB_INFINITY),
            )
        } else {
            free_all(env, model);
            return Err("unknown min/max op".into());
        };

        if rc != 0 {
            let e = env_error(env, "GRBaddgenconstrMax/Min failed");
            free_all(env, model);
            return Err(e);
        }
    }

    for pwl in &input.pwl_defs {
        let rc = GRBaddgenconstrPWL(
            model,
            std::ptr::null(),
            pwl.arg_col,
            pwl.res_col,
            pwl.xs.len() as c_int,
            pwl.xs.as_ptr(),
            pwl.ys.as_ptr(),
        );

        if rc != 0 {
            let e = env_error(env, "GRBaddgenconstrPWL failed");
            free_all(env, model);
            return Err(e);
        }
    }

    if !input.q_vals.is_empty() {
        let rc = GRBaddqpterms(
            model,
            input.q_vals.len() as c_int,
            input.q_rows.as_ptr(),
            input.q_cols.as_ptr(),
            input.q_vals.as_ptr(),
        );

        if rc != 0 {
            let e = env_error(env, "GRBaddqpterms failed");
            free_all(env, model);
            return Err(e);
        }
    }

    for qc in &input.qconstraints {
        let sense = match sense_char(qc.sense) {
            Ok(s) => s,
            Err(e) => {
                free_all(env, model);
                return Err(e);
            }
        };

        let rc = GRBaddqconstr(
            model,
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
            let e = env_error(env, "GRBaddqconstr failed");
            free_all(env, model);
            return Err(e);
        }
    }

    // SOS sets, batch call. Addition order is load-bearing for the IIS
    // splits: general constraints (indicators, abs, minmax, pwl), then
    // qconstraints, then SOS (their IIS flags are a separate attribute).
    if !input.soss.is_empty() {
        let mut types: Vec<c_int> = Vec::with_capacity(input.soss.len());
        let mut beg: Vec<c_int> = Vec::with_capacity(input.soss.len());
        let mut ind: Vec<c_int> = vec![];
        let mut weight: Vec<f64> = vec![];

        for sos in &input.soss {
            types.push(if sos.sos_type == atoms::sos1() { 1 } else { 2 });
            beg.push(ind.len() as c_int);
            ind.extend_from_slice(&sos.cols);
            weight.extend_from_slice(&sos.weights);
        }

        let rc = GRBaddsos(
            model,
            input.soss.len() as c_int,
            ind.len() as c_int,
            types.as_mut_ptr(),
            beg.as_mut_ptr(),
            ind.as_mut_ptr(),
            weight.as_mut_ptr(),
        );

        if rc != 0 {
            let e = env_error(env, "GRBaddsos failed");
            free_all(env, model);
            return Err(e);
        }
    }

    Ok((env, model))
}

unsafe fn free_all(env: *mut GRBenv, model: *mut GRBmodel) {
    GRBfreemodel(model);
    GRBfreeenv(env);
}

unsafe fn dbl_attr(model: *mut GRBmodel, name: &str) -> Option<f64> {
    let c = std::ffi::CString::new(name).ok()?;
    let mut out = 0.0_f64;
    if GRBgetdblattr(model, c.as_ptr(), &mut out) == 0 {
        Some(out)
    } else {
        None
    }
}

unsafe fn dbl_attr_array(model: *mut GRBmodel, name: &str, len: usize) -> Option<Vec<f64>> {
    let c = std::ffi::CString::new(name).ok()?;
    // (3) exact-size output buffer
    let mut out = vec![0.0_f64; len];
    if GRBgetdblattrarray(model, c.as_ptr(), 0, len as c_int, out.as_mut_ptr()) == 0 {
        Some(out)
    } else {
        None
    }
}

unsafe fn int_attr_array(model: *mut GRBmodel, name: &str, len: usize) -> Option<Vec<c_int>> {
    let c = std::ffi::CString::new(name).ok()?;
    let mut out = vec![0 as c_int; len];
    if GRBgetintattrarray(model, c.as_ptr(), 0, len as c_int, out.as_mut_ptr()) == 0 {
        Some(out)
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn solve(input: SolverInput, options: SolveOptions) -> Result<SolveResult, String> {
    let (n, m, _nnz) = validate(&input)?;
    let mut arrays = to_arrays(&input, n, m)?;

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
        let (env, model) = open_model(
            &input,
            &mut arrays,
            n,
            m,
            &options.int_params,
            &options.dbl_params,
        )?;

        if ctx.cancel.is_some() || ctx.log_tx.is_some() {
            GRBsetcallbackfunc(
                model,
                Some(gurobi_callback),
                &ctx as *const CallbackCtx as *mut c_void,
            );
        }

        if GRBoptimize(model) != 0 {
            let e = env_error(env, "GRBoptimize failed");
            free_all(env, model); // (2)
            return Err(e);
        }

        let mut status: c_int = 0;
        let status_name = std::ffi::CString::new("Status").unwrap();
        GRBgetintattr(model, status_name.as_ptr(), &mut status);

        // X is unavailable for infeasible/interrupted models; report zeros
        let values = dbl_attr_array(model, "X", n).unwrap_or_else(|| vec![0.0; n]);

        // Pi/RC exist only when an LP (sub)problem produced duals
        let row_duals = dbl_attr_array(model, "Pi", m);
        let col_duals = dbl_attr_array(model, "RC", n);
        let dual_status = if row_duals.is_some() && col_duals.is_some() {
            2
        } else {
            0
        };

        // QCPi (verified against gurobi_c.h 13.0) is one entry per quadratic
        // constraint, available only for continuous QCPs solved with
        // QCPDual=1; the attr fetch fails otherwise and None crosses as nil
        let qcon_duals = if options.qcp_duals && !input.qconstraints.is_empty() {
            dbl_attr_array(model, "QCPi", input.qconstraints.len())
        } else {
            None
        };

        let objective = dbl_attr(model, "ObjVal").filter(|v| v.is_finite());
        let mip_gap = dbl_attr(model, "MIPGap").filter(|v| v.is_finite());
        let solve_time = dbl_attr(model, "Runtime").unwrap_or(0.0);
        let simplex_iterations = dbl_attr(model, "IterCount").unwrap_or(0.0) as i32;
        let nodes = dbl_attr(model, "NodeCount").unwrap_or(0.0) as i64;

        free_all(env, model); // (2) free on success

        drop(ctx);
        if let Some(handle) = log_handle {
            let _ = handle.join();
        }

        Ok(SolveResult {
            status,
            objective,
            values,
            col_duals: col_duals.unwrap_or_else(|| vec![0.0; n]),
            row_duals: row_duals.unwrap_or_else(|| vec![0.0; m]),
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
    let mut arrays = to_arrays(&input, n, m)?;

    unsafe {
        // DualReductions=0 (GRB_INT_PAR_DUALREDUCTIONS, verified against
        // gurobi_c.h 13.0) makes the status decisive: without it Gurobi
        // may report INF_OR_UNBD (4) and the infeasibility check below
        // would wrongly return an empty IIS
        let dual_reductions = [("DualReductions".to_string(), 0)];
        let (env, model) = open_model(&input, &mut arrays, n, m, &dual_reductions, &[])?;

        if GRBoptimize(model) != 0 {
            let e = env_error(env, "GRBoptimize failed");
            free_all(env, model); // (2)
            return Err(e);
        }

        let mut status: c_int = 0;
        let status_name = std::ffi::CString::new("Status").unwrap();
        GRBgetintattr(model, status_name.as_ptr(), &mut status);

        if status != GRB_STATUS_INFEASIBLE {
            free_all(env, model); // (2)
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

        if GRBcomputeIIS(model) != 0 {
            let e = env_error(env, "GRBcomputeIIS failed");
            free_all(env, model); // (2)
            return Err(e);
        }

        let iis_constr = int_attr_array(model, "IISConstr", m);
        let iis_lb = int_attr_array(model, "IISLB", n);
        let iis_ub = int_attr_array(model, "IISUB", n);

        // construct membership: one IISGenConstr flag per general
        // constraint in ADDITION order (indicators, abs, minmax, pwl in
        // open_model), one IISQConstr flag per quadratic constraint
        // (both attr names verified against gurobi_c.h 13.0)
        let n_gen = input.indicators.len()
            + input.abs_defs.len()
            + input.minmax_defs.len()
            + input.pwl_defs.len();
        let iis_gen = if n_gen > 0 {
            int_attr_array(model, "IISGenConstr", n_gen)
        } else {
            Some(vec![])
        };
        let iis_qc = if input.qconstraints.is_empty() {
            Some(vec![])
        } else {
            int_attr_array(model, "IISQConstr", input.qconstraints.len())
        };
        // one flag per SOS set ("IISSOS", verified against gurobi_c.h 13.0)
        let iis_sos = if input.soss.is_empty() {
            Some(vec![])
        } else {
            int_attr_array(model, "IISSOS", input.soss.len())
        };

        free_all(env, model); // (2) single exit after this point

        let (iis_constr, iis_lb, iis_ub, iis_gen, iis_qc, iis_sos) =
            match (iis_constr, iis_lb, iis_ub, iis_gen, iis_qc, iis_sos) {
                (Some(a), Some(b), Some(c), Some(d), Some(e), Some(f)) => (a, b, c, d, e, f),
                _ => return Err("IIS attributes unavailable".into()),
            };

        fn positions(flags: &[i32]) -> Vec<i32> {
            flags
                .iter()
                .enumerate()
                .filter(|(_, f)| **f != 0)
                .map(|(i, _)| i as i32)
                .collect()
        }

        let (ind_flags, rest) = iis_gen.split_at(input.indicators.len());
        let (abs_flags, rest) = rest.split_at(input.abs_defs.len());
        let (mm_flags, pwl_flags) = rest.split_at(input.minmax_defs.len());

        // member statuses use the HiGHS-compatible ints the Elixir side
        // already decodes: 2 lower, 3 upper, 4 boxed
        let mut rows = vec![];
        let mut row_statuses = vec![];
        for i in 0..m {
            if iis_constr[i] != 0 {
                rows.push(i as i32);
                row_statuses.push(match arrays.sense[i] as u8 {
                    b'<' => 3,
                    b'>' => 2,
                    _ => 4,
                });
            }
        }

        let mut cols = vec![];
        let mut col_statuses = vec![];
        for j in 0..n {
            let lb = iis_lb[j] != 0;
            let ub = iis_ub[j] != 0;

            if lb || ub {
                cols.push(j as i32);
                col_statuses.push(if lb && ub {
                    4
                } else if lb {
                    2
                } else {
                    3
                });
            }
        }

        Ok(IisResult {
            cols,
            col_statuses,
            rows,
            row_statuses,
            indicators: positions(ind_flags),
            abs_defs: positions(abs_flags),
            minmax_defs: positions(mm_flags),
            pwl_defs: positions(pwl_flags),
            qconstraints: positions(&iis_qc),
            cones: vec![],
            soss: positions(&iis_sos),
        })
    }
}

rustler::init!("Elixir.Optex.Solver.Gurobi.Native");
