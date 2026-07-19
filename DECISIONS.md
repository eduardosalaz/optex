# Decision log

## Post-v1: per-binding options in DSL variable families (2026-07-18)

Indexed variable declarations (plain `variable x[{r, c}], r <- ..., c <-
..., opts` and the indexed defined forms abs/pwl/min/max) now splice their
trailing options into the family comprehension, the same shape the
constraint/SOS/norm/indicator family expansions always used
(`for(clauses, do: {key, opts})` instead of bare keys reduced with opts in
the closure). Consequences:

- `lb:`/`ub:`/`type:` may reference the generator variables and vary per
  binding. The sudoku givens pattern (bounds encoding fixed cells) now
  expresses in the DSL; previously it forced the programmatic builder,
  which was an implementation asymmetry of the variable rewrite, not a
  language limitation (gurobipy and JuMP both allow per-index bounds).
- Evaluation count is UNCHANGED: opts already re-evaluated per iteration
  inside the reduce closure; the change only brings the generators into
  scope.
- One deliberate behavior change: opts that referenced an OUTER variable
  with the same name as a generator now resolve to the generator (before,
  the generator was out of scope so the outer binding leaked through).
  The old behavior was a footgun and inconsistent with every other family
  expansion; pinned by a shadowing test in dsl_test.exs.

## Post-v1: precompiled HiGHS NIF for the 0.1.0 release (2026-07-17)

The HiGHS crate switched from `use Rustler` to `use RustlerPrecompiled`:
consumers on x86_64/aarch64 linux-gnu, x86_64/aarch64 macOS, and x86_64
Windows MSVC download a checksummed binary from the GitHub release at
compile time and need NO Rust/CMake/libclang toolchain. Decisions:

- Scope: the HiGHS crate ONLY. The commercial crates link the consumer's
  locally installed proprietary SDKs, cannot be built in CI (no licenses,
  no redistributable import libraries), and their users have real dev
  setups anyway; they keep plain compile-gated Rustler builds.
- rustler stays a HARD dependency, not optional (against the
  explorer-style convention): the gated commercial crates `use Rustler`
  whenever their env vars are set, and the FORCE_OPTEX_BUILD path needs
  it too; an optional dep would break exactly the users who set
  GUROBI_HOME. The rustler hex package is pure Elixir, so requiring it
  costs consumers nothing at install time.
- FORCE_OPTEX_BUILD=1 is REQUIRED on dev machines and in the CI test
  workflow (set in ci.yml and machine-wide on the dev box): without it,
  compiling a checkout whose @version has no published release fails
  trying to download binaries. The test workflow also deliberately keeps
  proving the source-build path.
- The release matrix uses NATIVE runners for all five targets (GitHub's
  arm Linux and arm macOS runners included), sidestepping the C++
  cross-compilation problem entirely: the CMake-built HiGHS tree is never
  cross-compiled. musl and other targets are out of the matrix; those
  platforms build from source via the force flag (documented).
- NIF version pinned to 2.15 (rustler_precompiled's default expectation);
  the checksum-*.exs file is generated per release from the published
  artifacts, gitignored, and shipped in the Hex package (files list).

## Post-v1: progress and incumbent streaming (2026-07-17)

optimize/2 gained `progress:` (pid; throttled {:optex_progress, map} with
best_obj/best_bound/gap/nodes/time), `progress_every:` (ms, default 1000,
0 = unthrottled, validated per backend), and `incumbents:` (pid;
{:optex_incumbent, %{objective, values}} per improving solution, values
keyed by variable name). MIP-focused; LP solves emit nothing. All four
backends support both streams; nil fields are honest per backend:

| field   | HiGHS | Gurobi | CPLEX | COPT |
|---------|-------|--------|-------|------|
| best*   | yes   | yes    | yes   | yes  |
| gap     | yes   | nil    | nil   | nil  |
| nodes   | yes   | yes    | yes   | nil  |
| time    | yes   | yes    | ours  | ours |

Design points:

- Same safety recipe as log streaming: the solver callback only pushes
  into a NEW per-solve mpsc channel (one enum of Progress|Incumbent); one
  unmanaged thread drains it, joined before the NIF returns. The log
  channel stayed separate (on COPT it doubles as the cancel poll hook; do
  not destabilize a pinned mechanism). No user code on solver threads,
  ever; stopping rules live app-side: receive progress, call cancel/1
  (pinned by the composition test).
- Rekeying: incumbents leave the NIF raw ({:optex_incumbent_raw, obj,
  values list}); only optimize/2 knows names, so it spawns
  Optex.StreamRelay per solve (stopped via try/after even on pre-NIF
  rejection). When both streams are on, progress routes through the relay
  too, preserving arrival order for a user watching both.
- Throttle lives in the callback (atomic last-sent millis; first event
  always sent) so mailboxes never flood; incumbents are never throttled.
- Empirical pins: HiGHS MipLogging events DO NOT fire while output_flag
  is false, so requesting progress silently enables logging with the
  console dark (appended so it beats log: false); Gurobi callback whats
  all decode as double, including NODCNT (the header is typeless); CPLEX
  CPXCALLBACKINFO ordinals pinned from the unvalued enum in cpxconst.h
  (NODECOUNT 1, BEST_SOL 3, BEST_BND 4) and its TIME info returns an
  ABSOLUTE timestamp, so elapsed time is measured on our side; COPT's
  callback info has no node/time entries at all.
- CPLEX's generic callback fires from MULTIPLE threads: the ctx uses
  compare-exchange for the throttle and a f64-bits CAS tracker for
  incumbent detection (mpsc::Sender is Sync since Rust 1.72). Its
  incumbent stream is at-least-once per strict improvement and may
  coalesce near-simultaneous incumbents.

## Post-v1: SOS constraints (2026-07-17)

sos1/sos2 as a native primitive on Gurobi, CPLEX, and COPT (capability
:sos; HiGHS has no SOS support). Model.add_sos(m, type, [{var, weight}],
name:) plus the DSL forms `constraint sos1([{x, 1}, {y, 2}])` and
families. Validation everywhere (model layer and the three firewalls):
at least two members, distinct variables, distinct finite weights (the
weights define the order, which is what SOS2 adjacency means). Mappings:
GRBaddsos (int types 1/2), CPXaddsos (char types '1'/'2'; SOS forces the
MIP optimizer like the other CPLEX constructs), COPT_AddSOSs (forces
is_mip). Gurobi's construct-aware IIS reports conflicting sets as
{:sos, name} via IISSOS (gurobi_c.h:509). Pinned by analytic SOS1
pick-one and SOS2 adjacency solves agreeing across all three backends.
Deliberately NOT a PWL backdoor for COPT: building the lambda formulation
from SOS2 would be exactly the reformulation the house rule forbids.

## Post-v1: second-order cones (2026-07-17)

Capability :second_order_cone on Gurobi, CPLEX, and COPT: quad cones
(head >= ||members||) and rotated cones (2*h1*h2 >= sum member^2) via
Model.add_cone / add_rotated_cone, plus the DSL sugar
`constraint norm(exprs...) <= rhs` (members lift through the
defined-argument machinery as {name, {:arg, i}}/{name, {:def, i}}; a
non-variable rhs gets a lb-0 head aux {name, :head} pinned by
{name, :head_def}, exact because the cone forces its head nonnegative).

- HEAD RULE, load-bearing: cone heads must already carry a nonnegative
  lower bound; add_cone raises rather than mutating bounds. On
  Gurobi/CPLEX the cones are SOC-shaped quadratic constraints (members +1
  on the diagonal; head -1, or -2 on the h1*h2 cross term), each solver's
  DOCUMENTED native encoding (the same never-reformulate class as
  CPLEX-abs-via-PWL), and the head bound is what makes CPLEX's convexity
  check accept the shape. COPT uses its real cone API (COPT_AddCones,
  copt.h:544-549) with heads-first index lists.
- Pins: the 3-4-5 quad cone solves to exactly 5 on all three (fixes the
  COPT head-order convention); the rotated test (min h1, 2*h1*h2 >= x^2,
  h2 = 2, x = 4 -> h1 = 4, where a 1*h1*h2 convention would give 8)
  fixes the factor on all three. MISOCP covered.
- Gurobi order contract EXTENDED and still load-bearing: qconstraints are
  added before cones, so the QCPi prefix fetch (length = real
  qconstraints) stays correct with cones present (pinned by a mixed
  qcp_duals test) and IISQConstr is fetched over qconstraints + cones and
  split; cone conflicts report as {:second_order_cone, name}.
- CPLEX optimizer routing now treats cones as barrier-worthy (a
  continuous SOCP would previously have routed to lpopt).
- No cone duals anywhere in v1 (COPT's API has no cone dual or cone IIS
  getters at all; Gurobi's would arrive through QCPi but stays unexposed
  for symmetry until someone needs it).

## Post-v1: construct-aware IIS on Gurobi (2026-07-17)

explain_infeasibility/2 now examines the FULL model on Gurobi instead of
the linear relaxation: conflicting native constructs are reported as
{kind, name} tuples under a new `constructs` key, and not_examined is []
there. Everything else keeps the strip-and-flag behavior.

- Mechanism: GRBcomputeIIS already covers general and quadratic
  constraints; the NIF now also fetches IISGenConstr and IISQConstr
  (verified against gurobi_c.h 13.0, lines 511/510). IISGenConstr is ONE
  array over all general constraints in ADDITION order, so the split into
  kinds relies on open_model's ordering: indicators, abs, minmax, pwl.
  That ordering is now a load-bearing contract between open_model and iis.
- Dispatch: a new optional Optex.Solver callback construct_iis?/0 (true
  only on Gurobi). explain_infeasibility passes the unstripped input when
  the callback says yes AND the solver's capabilities cover everything the
  input carries; otherwise the linear-relaxation strip continues to apply
  (HiGHS/CPLEX/COPT report rows and bounds only).
- Naming: indicators and qconstraints by their own names (id fallback,
  own id spaces; wire position == id). Defined variables (abs/pwl/minmax)
  report under their RESULT variable's name, the handle users know them
  by ({:abs, :t} for variable t = abs(...)).
- Wire: Optex.IisResult gained per-kind position lists in ALL FOUR crates
  (NifStruct encode requires every declared field; non-Gurobi crates
  return empty lists).
- Found while testing: without DualReductions=0 Gurobi may report
  INF_OR_UNBD (4) instead of INFEASIBLE (3), and the iis NIF's
  infeasibility check would return an empty IIS. The iis solve now always
  sets DualReductions=0 (GRB_INT_PAR_DUALREDUCTIONS, verified) so the
  status is decisive. This also hardens the pre-existing linear IIS path.
- Pinned by tests: an indicator conflict named as {:indicator, :gate}
  with not_examined == [], an abs conflict under the result variable, a
  quadratic constraint conflict plus the guilty bound, and a min/max
  conflict (the case that exposed the INF_OR_UNBD gap).

## Post-v1: abs/pwl/min-max on COPT, CONSIDERED AND REJECTED (2026-07-17)

Investigated whether COPT 8.0.5 could join the abs/pwl/min-max
capabilities. Verdict: no, on all three. The evidence, so this is not
re-litigated:

- abs: COPT has no general constraint for it, but its nonlinear-expression
  API (COPT_AddNLConstr) has a COPT_NL_ABS opcode, which would have been a
  legitimate bridge in the CPLEX-abs-via-native-PWL sense IF it were
  exact. It is not: the NL machinery is a LOCAL solver. Probed through
  the bundled coptpy against the live 8.0.5 library: t == abs(x) on
  x in [-3, 2] maximizing t returned x = 2, t = 2 (the local optimum; the
  global answer is 3 at x = -3) with status 20, which copt.h:107 names
  COPT_STATUS_LOCAL_OPTIMAL. The header agrees with the experiment:
  NLPMuUpdate/NLPTol params and COPT_SetNLPrimalStart are local-NLP
  machinery. Our :abs capability contract is "exact even when maximized"
  (the pinned test all other capable backends pass), so mapping abs onto
  this would silently return wrong answers on nonconvex uses. Rejected.
- pwl: no representation in the C API at all (no constraint type, no
  opcode). Any encoding would be an SOS2/binary reformulation, forbidden.
- min/max: no opcodes. The identity max(a, b) == (a + b + |a - b|) / 2 is
  a reformulation on our side AND would inherit the local-only abs.

COPT's capability set therefore stays
[:indicator, :quadratic_objective, :quadratic_constraint], and the NL API
remains deliberately unused (it is also the SOCP/general-nonlinear
surface, which is out of project scope).

## Post-v1: COPT 8.0.5 upgrade and runtime verification (2026-07-17)

The user upgraded COPT 7.2.11 -> 8.0.5 (C:\Program Files\copt80, valid
license) the same day the backend was built. Results:

- Header re-verification (required by the version-bump rule): every
  signature, constant, status code, attribute/parameter/info name the
  crate uses is BYTE-IDENTICAL between 7.2.11 and 8.0.5 (only line numbers
  shifted; crate comments updated to 8.0.5 references). New 8.0 API
  surface (FeasRelax, multi-objective, advanced simplex routines, the
  nonlinear-expression API) is all outside project scope; COPT still has
  NO pwl/abs/min-max general constraints, so the capability set is
  unchanged: [:indicator, :quadratic_objective, :quadratic_constraint].
- All pending empirical pins from the entry below now VERIFIED on 8.0.5:
  literal quadratic coefficients (analytic -13 QP), LP dual conventions
  agree with the other three backends (four-way zoo test), status
  decoding, LoadProb row encoding, indicator semantics, IIS, log
  streaming, MIQP/MIQCP.
- CORRECTION to the entry below: qcp_duals is NOT supported on COPT after
  all. COPT_GetQConstrInfo rejects the "Dual" info name with
  RETCODE_INVALID (3) while "Slack" succeeds (verified empirically on the
  solved ball QCP), so like CPLEX the C API exposes qconstraint slacks
  but no dual multipliers. qcp_duals: true is rejected pre-NIF with
  {:unsupported, :qcp_duals, COPT}; the option remains Gurobi-only. The
  crate deliberately does not declare COPT_GetQConstrInfo.
- Cancellation refinement: COPT_Interrupt does NOT persist across a solve
  start (a pre-solve interrupt still ran to optimality), so a token
  cancelled before the solve begins skips COPT_Solve entirely and the NIF
  synthesizes status 10, which is INTERRUPTED in BOTH the Lp and Mip
  tables. Mid-solve cancellation interrupts directly through the parked
  prob pointer, with the log-callback poll as backstop.
- Console hygiene: LogToConsole=0 is applied BEFORE Logging=1 (both in
  build_options and the cancel-only NIF path), otherwise COPT echoes the
  parameter change to the console.

## Post-v1: COPT backend (2026-07-17) - status superseded by the entry above

(Originally written against 7.2.11 with an expired license; the "RUNTIME
PINS PENDING" state below is resolved by the 8.0.5 entry, including one
correction on qcp_duals.)

Fourth backend: COPT (Cardinal Optimizer) 7.2.11, same recipe as
Gurobi/CPLEX. Crate native/optex_copt, module Optex.Solver.COPT,
compile-gated on COPT_HOME (installer sets it; C:\Program Files\copt72),
unversioned import lib copt.lib, Native chain extended to
HiGHS <- Gurobi <- CPLEX <- COPT.

Header-verified facts (copt.h 7.2.11, line refs in the crate):
- COPT_CALL is __stdcall on Windows (copt.h:5): the whole extern block is
  extern "system", NOT extern "C". First backend where this matters.
- Parameters are string-named and set on the PROBLEM (not the env):
  TimeLimit, RelGap, Threads, Logging, LogToConsole.
- LoadProb is beg+cnt CSC with sense chars ('L'/'G'/'E'/'N'/'R') plus
  rowBound/rowUpper; ranged rows map natively to 'R' like CPLEX.
- LP (LpStatus, copt.h:95-104) and MIP (MipStatus, copt.h:107-115) status
  enumerations OVERLAP numerically (both use 1 optimal, 2 infeasible...),
  unlike CPLEX's disjoint tables: decode_status/2 takes the mip? flag.
  4 = INF_OR_UNB exists only on the MIP side.
- COPT_INFINITY (1e30) and COPT_UNDEFINED (1e40) are FINITE doubles:
  sentinel filtering is by magnitude (< 1e30), is_finite alone is wrong.
- Objective attr is "LpObjval" (lowercase val) for continuous, "BestObj"
  for MIP; stats via SolvingTime/SimplexIter/NodeCnt/BestGap.
- Duals: COPT_GetRowInfo "Dual" / COPT_GetColInfo "RedCost", gated on
  HasLpSol (continuous only). Quadratic constraint duals exist via
  COPT_GetQConstrInfo "Dual", so COPT supports the qcp_duals option (no
  extra parameter needed, unlike Gurobi's QCPDual).
- Constructs: indicators via COPT_AddIndicator (binColVal takes
  active_value directly, no complement flip like CPLEX); quadratic
  objective via COPT_SetQuadObj triplets; quadratic constraints via
  COPT_AddQConstr (single sense char + bound). NO pwl, NO abs, NO min/max
  general constraints in this API, so capabilities are
  [:indicator, :quadratic_objective, :quadratic_constraint]; quadratic
  equality rejected pre-NIF like CPLEX (convex-only stance; COPT's
  NonConvex parameter is deliberately not enabled).
- IIS: COPT_ComputeIIS + per-bound getters (GetCol/RowLower/UpperIIS),
  combined into the shared 2 lower / 3 upper / 4 boxed convention.
- Cancellation: no terminate-pointer API; COPT_Interrupt(prob) instead.
  The token holds the prob pointer (as usize) under a mutex for exactly
  the solve's duration; cancel/1 interrupts a running solve directly, and
  the log callback doubles as a poll hook (logging is forced on, console
  off, when only a cancel token is present).

PENDING EMPIRICAL PINS - the local license EXPIRED 2026-03-07 (found via
copt_cmd; the user believed it valid and plans to renew). Every runtime
convention is encoded in test/optex/copt_test.exs and activates
automatically on renewal (test_helper probes the license with a trivial
solve and excludes :copt loudly while it fails, because COPT checks the
license per env creation and a red suite would hide real failures):
- quadratic objective assumed LITERAL coefficients (pinned by the -13
  separable QP test);
- qcp_duals sign convention assumed to match Gurobi's +0.5 ball dual;
- LoadProb rowBound/rowUpper interpretation, indicator binColVal
  semantics, status decoding, IIS flags, log streaming, cancel.
What DID run against the real library: crate compiles and links, license
failure propagates as a clean {:error, "COPT_CreateEnv failed..."} on
every path (no VM crash), and the pre-NIF capability/option rejections
pass. Until the pins run, treat the COPT backend as unverified.

## Post-v1: pwl jump discontinuities (2026-07-17)

pwl breakpoints now allow jump discontinuities via a repeated x, relaxing
the v1 strictly-increasing rule. The exact validation, IDENTICAL in all
three layers (Optex.Model.validate_points!, the Gurobi crate firewall, the
CPLEX crate firewall - the NIF firewalls stay authoritative):

1. x values non-decreasing;
2. at most two consecutive equal x (a jump); three or more rejected;
3. an equal-x pair must have different y values (equal x and equal y is a
   duplicate point, not a jump);
4. jumps interior only: the first and last point pairs need strictly
   increasing x. Reason: the end segments define the extension slopes, and
   the CPLEX NIF literally divides by their width for CPXaddpwl's
   preslope/postslope; an end jump would divide by zero (Gurobi's own end
   extension would be equally undefined).

Semantics AT the jump x, pinned empirically on both backends with a step
function [{0,0},{5,0},{5,10},{10,10}] fixed at x=5: both jump values are
feasible and the objective direction chooses (maximize returns 10,
minimize returns 0, on Gurobi and CPLEX alike). So the vertical segment is
part of the feasible graph; a solver picks the favorable endpoint. Interior
and out-of-range probes confirm end-segment extension is unaffected.
Mapping code is untouched: Gurobi's GRBaddgenconstrPWL treats repeated x
as a jump natively, CPLEX's CPXaddpwl documents discontinuities via
repeated breakx values.

## Post-v1: min/max general constraints (2026-07-17)

`variable t = max(args...)` / `min(args...)` (scalar and indexed), USER
AUTHORIZED, reversing the earlier "not offered at all" decision. The
never-reformulate rule is intact: capability :min_max exists only on
Gurobi; HiGHS and CPLEX reject pre-NIF with {:unsupported, :min_max,
backend}, and their crates' firewalls reject defensively (a crate that did
not declare the wire field would silently DROP it on decode, which is why
the field plus rejection landed in all three crates).

- FFI: GRBaddgenconstrMax / GRBaddgenconstrMin(model, name, resvar, nvars,
  vars, constant), verified against gurobi_c.h 13.0 lines 1012-1018.
- Arguments: any mix of linear expressions and numbers. Numbers (and
  constant Affs) fold into the single `constant` operand via Enum.max/min;
  at least one variable argument is required; quadratic arguments raise.
  A model with NO constant operand passes the operation's identity
  (-GRB_INFINITY for max, +GRB_INFINITY for min, an operand that never
  wins); pinned by the maximize-the-max test solving to the exact bound.
- Aux naming contract extends the abs/pwl one: expression arguments get
  {name, {:arg, i}} aux vars and {name, {:def, i}} equality rows, i the
  0-based position among EXPRESSION arguments (bare variables and
  single-term coef-1.0 references reuse their ids, no aux).
  defined_arg!/5 now takes the aux/def names from the caller; abs/pwl pass
  the original {name, :arg} / {name, :def}, unchanged.
- The expression-walker rejection of max/min INSIDE expressions stays
  (Kernel.max would silently compare structs); only the defined-variable
  head position is intercepted. maxi/mini misspellings get a pointer to
  the native spelling.
- CPLEX gained the generic check_capabilities/1 (it never needed one while
  it advertised every capability); Gurobi gained it too as a no-op, so all
  three backends now reject uniformly and pre-NIF.
- Result variable defaults to unbounded (like pwl, unlike abs's lb 0.0).
- Wire form: %Optex.SolverInput.MinMax{res_col, op, arg_cols, constant},
  constant nil-or-float (Option<f64> in the crates), op the neutral
  :min/:max atom dispatched in the Gurobi NIF.

## Post-v1: QCP duals (2026-07-17)

Quadratic constraint duals are OPT-IN and Gurobi-only: `qcp_duals: true` on
optimize/2. Design points, in order of consequence:

- Opt-in because Gurobi only computes them under the QCPDual parameter
  (GRB_INT_PAR_QCPDUAL, gurobi_c.h:1390, verified 13.0), which costs extra
  work on every continuous QCP solve; existing users pay nothing. The
  option pushes {"QCPDual", 1} through the ordinary int_params plumbing and
  sets a qcp_duals flag on the Options wire struct; the NIF then fetches
  the QCPi attribute array (GRB_DBL_ATTR_QCPI, gurobi_c.h:430, one entry
  per quadratic constraint).
- Results surface on a SEPARATE Solution.qcon_duals field, keyed by
  qconstraint name with id fallback. Merging into `duals` was rejected:
  qconstraints have their own id space, so unnamed rows would collide with
  unnamed linear rows.
- Index correspondence, load-bearing for the rekeying: model qcon id i ==
  wire qconstraints position i (Transform reverses the prepended list) ==
  i-th GRBaddqconstr call == QCPi[i]. The wire QConstraint struct still
  carries no name; optimize/2 rekeys positionally against
  model.qconstraints.
- qcp_duals: false is a no-op on EVERY backend (portable code can pass a
  toggle); qcp_duals: true on HiGHS/CPLEX fails pre-NIF with
  {:unsupported, :qcp_duals, backend}. CPLEX rationale: the 22.1.1 C API
  exposes qconstraint slacks only (CPXgetqconstrslack and friends,
  cplex.h:3312); there is no dual multiplier accessor, and we never
  approximate.
- MIQCP: the option is accepted, QCPi does not exist for MIPs, the attr
  fetch fails, qcon_duals is nil. Same shape as linear duals for MIPs.
- Sign convention pinned empirically (same method as linear duals):
  max x+y s.t. x^2+y^2 <= 2 (optimum (1,1), stationarity lambda = 0.5)
  returns QCPi = +0.5, i.e. positive for a binding <= constraint in a max
  problem, matching Gurobi's Pi convention.
- Wire consequence: Optex.SolveResult gained qcon_duals in ALL THREE
  crates (rustler NifStruct encode emits exactly the declared fields, so a
  missing field in any crate would break the shared struct contract);
  HiGHS and CPLEX always return None.

## Post-v1: debt cleanup and packaging (2026-07-17)

- Duplicate variable names now warn (IO.warn) while keeping last-wins
  semantics; silent shadowing was always a modeling bug waiting to happen.
- explain_infeasibility analyzes the LINEAR RELAXATION: constructs
  (indicators, abs/pwl defs, quadratic constraints) and the quadratic
  objective are stripped before the backend iis call, so any IIS found is
  genuine, HiGHS can analyze construct-carrying models, and the result's
  new not_examined field names the stripped construct kinds where the real
  conflict may live. Native construct-aware IIS (Gurobi IISGenConstr /
  IISQConstr) was future work here; DONE, see "Post-v1: construct-aware
  IIS on Gurobi" above.
- Aux-variable naming ({name, :arg} / {name, :def}) and the if: {b, 0}
  tuple convention (a 2-tuple with literal 0/1 is always the negation form;
  use the access form for indexed binaries) are now documented contracts.
- Packaging: ONE package shipping all three gated crates, not adapter
  packages. The compile gating makes this safe (stubs without the vendor
  SDKs; CI proves the no-vendor build every push), and it keeps versioning
  trivial. The adapter split remains available if backend count or release
  cadence ever diverges.

## Post-v1: quadratic constraints (2026-07-17)

`constraint x*x + y*y <= 2` works: a quadratic left side routes to
%Optex.QConstraint{} in its OWN id space (never part of the CSC matrix),
same normalization as linear rows. Capability :quadratic_constraint with
the honest matrix: Gurobi full (nonconvex and equality via spatial
branching), CPLEX convex <=/>= only (quadratic equality does not exist in
CPXaddqconstr and is rejected specifically with
{:unsupported, :quadratic_equality_constraint, CPLEX} before the NIF),
HiGHS none. Conventions: BOTH solvers take literal coefficients for
constraint quadratics (CPLEX's 1/2 convention applies only to the
objective), so the wire triplets pass through unchanged. CPLEX continuous
QCP needs its third optimizer, CPXbaropt (the routing is now lpopt / qpopt
/ baropt / mipopt). IIS does not cover quadratic constraints (documented
limitation); duals originally did not either, until the opt-in qcp_duals
option (see "Post-v1: QCP duals" below). Pinned by tests: convex ball
tangency at the
analytic point on both commercial backends, MIQCP, nonconvex
outside-the-ball on Gurobi only.

## Post-v1: quadratic objectives (2026-07-17)

The v1 invariant "nonlinear products are rejected, never represented" is
DELIBERATELY AMENDED (user decision) to "degree > 2 is rejected, never
represented": Aff gained qterms (%{{lo_id, hi_id} => coef}, normalized so
x*y and y*x share a cell) and Aff.mul of two linear expressions now expands
the product instead of raising. Quadratic terms are representable ONLY in
the objective; constraints, indicator rows, and abs/pwl arguments reject
them at build time (quadratic constraints are the natural follow-up slice).

Coefficient conventions were the trap: the neutral wire (q_cols/q_rows/
q_vals COO triplets, lower-triangle normalized) carries LITERAL
coefficients (the qterm coefficient of {i, j} is the coefficient of
x_i * x_j as written). Backends convert:

- Gurobi GRBaddqpterms is already literal: triplets pass through unchanged.
  Supports MIQP and (via spatial branching) nonconvex.
- HiGHS's objective is c'x + 1/2 x'Qx with a lower-triangular CSC Hessian
  through passModel (q_start has length num_col, NOT num_col + 1; format
  constant 1 verified): diagonal entries double, off-diagonal pass through.
  Convex continuous only; the binding rejects quad + integer inputs with
  {:unsupported, :quadratic_objective_with_integers, ...}.
- CPLEX CPXcopyquad wants the FULL symmetric Q, same 1/2 convention:
  diagonal doubled, off-diagonal mirrored to both triangles. Continuous QP
  needs its own optimizer (CPXqpopt); MIQP goes through mipopt. Nonconvex
  errors at solve (would need OptimalityTarget; not exposed).

The conversions are pinned empirically: a cross-term QP with analytic
optimum (-3 at (1,1) for x^2+xy+y^2-3x-3y) agrees across all three
backends, which only happens if every 1/2-convention conversion is right.

## Post-v1: piecewise-linear functions (2026-07-17)

`variable y = pwl(e, points)` (scalar and indexed; points is any runtime
expression yielding [{x, y}] pairs, at least two, strictly increasing x; no
jump discontinuities in v1 - SUPERSEDED by "Post-v1: pwl jump
discontinuities" below, which relaxes the rule to non-decreasing x with
interior jumps). Same strict-capability mold: capability :pwl on
Gurobi and CPLEX, HiGHS rejects, never reformulated; same aux-variable
pattern for expression arguments.

The one real design decision was out-of-range semantics: CPLEX takes
explicit pre/post slopes, Gurobi extends its end segments. Neutral semantics
chosen: END-SEGMENT EXTENSION, with the CPLEX slopes computed in the NIF
from the first/last segments. Pinned empirically by a cross-backend test
probing interior (35 at x=25), above-range (50 at x=40), and below-range
(-10 at x=-5) points on both solvers.

Also fixed here: with three Rustler crates, the parallel Elixir compiler
races on copying priv/native (one module's build_structure copy sees a DLL
another is mid-replacing). Crate builds are serialized via
Code.ensure_compiled compile-time deps between the Native modules
(HiGHS <- Gurobi <- CPLEX).

## Post-v1: native general constraints (2026-07-17)

Indicator constraints and absolute values, solved by each solver's own
construct and NEVER reformulated (explicit user decision over the big-M
reformulation alternative: no user-supplied Ms, tighter solver internals).
Strict capability model: backends export capabilities/0 ([:indicator, :abs]
for Gurobi and CPLEX, [] for HiGHS) and reject inputs needing more with
{:error, {:unsupported, construct, backend}} before any NIF runs; the HiGHS
crate additionally rejects in its firewall.

- Surface: `constraint ..., if: b` / `if: {b, 0}` (indicator, families
  supported, bin-ness validated at runtime) and `variable t = abs(e)`
  (scalar and indexed). bound: on constraints is rejected as unnecessary.
- Neutral form is variable-based because both solver APIs are: `abs(e)` for
  a non-bare expression introduces a free aux variable pinned by an
  equality row (named {name, :arg} / {name, :def}); the neutral abs_def
  relates two variable ids. Indicators store a normalized row plus bin id
  and active value; Model/SolverInput/Transform carry both construct kinds.
- Mapping: Gurobi GRBaddgenconstrIndicator / GRBaddgenconstrAbs; CPLEX
  CPXaddindconstr (active_when 0 is the complemented form) and abs as a
  native piecewise-linear CPXaddpwl (slopes -1/+1, breakpoint at origin).
  CPLEX forces the MIP optimizer when constructs are present even for
  all-continuous columns.
- The expression walker rejects abs/max/min anywhere inside expressions:
  Kernel.max of two %Var{} structs would silently compare structs and build
  a wrong model. min/max general constraints are Gurobi-only and were
  originally not offered at all under the never-reformulate rule
  (SUPERSEDED: see "Post-v1: min/max general constraints" below, which
  offers them as a strictly-rejected Gurobi-only capability, still never
  reformulated).
- MPS/LP emitters raise on models with constructs (not representable in the
  plain dialects); the pretty printer renders them. Solve tests cross-check
  the native indicator model against a manually linked HiGHS equivalent,
  and the abs tests pin the maximize-|x| case that epigraph reformulations
  cannot express.

## Post-v1: CPLEX backend and CI (2026-07-17)

Third backend, same recipe as Gurobi (hand-rolled FFI verified against the
installed CPLEX 22.1.1 cplex.h/cpxconst.h; compile-gated on the versioned
CPLEX_STUDIO_DIR* env var; :cplex tests self-exclude). CPLEX-specific
decisions:

- Links the static library (lib/x64_windows_msvc14/stat_mda/cplex2211.lib),
  which matches Rust's /MD runtime and avoids DLL-path issues.
- LP and MIP have separate optimize calls (CPXlpopt/CPXmipopt) and disjoint
  status tables; a single Elixir decode covers both (1/2/3/4/11/13 and
  101/102/103/107/108/113/114/118/119, with 102 optimal-within-tolerance
  decoding as :optimal). Parameters are numeric ids (TILIM 1039, EPGAP 2009,
  THREADS 1067, SCRIND 1035), owned by the binding module.
- Ranged rows are supported natively (sense 'R' with rngval = ub - lb), so
  this backend does not share the Gurobi range limitation.
- Cancellation uses CPXsetterminate polling an int owned by the token
  resource; no callback needed. Log streaming hooks all four message
  channels via CPXaddfuncdest with the usual channel-plus-unmanaged-thread
  pattern. IIS is the conflict refiner (CPXrefineconflict/CPXgetconflict),
  gated on infeasible-family statuses, members mapped to the shared
  lower/upper/boxed convention.
- CPXcopyctype is only called when integrality exists: copying a ctype
  array makes the problem a MIP even if all-continuous, which would break
  CPXlpopt.
- The cross-solver agreement test now spans every available backend.

CI (GitHub Actions, ubuntu-latest, Elixir 1.20.2/OTP 29 verified on
builds.hex.pm): compiles with --warnings-as-errors and runs the suite; both
commercial gates are off on the runner, a configuration verified locally in
an isolated build root (it caught one real defect: the type checker proves
{:ok, ...} clauses unreachable against stub returns, so backend Native calls
go through apply/3).

## Post-v1: Gurobi backend (2026-07-17)

Second solver, proving the Solver-behaviour seam: zero changes above the
behaviour; `optimize(m, solver: Optex.Solver.Gurobi)` just works, and the
cross-solver test suite pins HiGHS and Gurobi to agreeing objectives and
duals. Decisions:

- **Hand-rolled FFI, not grb-sys2.** The sys crate tracks Gurobi 12.1 and
  the client version triple is baked into env creation (GRBloadenv is a
  macro over GRBloadenvinternal), risking a version rejection against the
  installed 13.0. Every declared signature was verified against
  C:\gurobi1300 gurobi_c.h instead; the build script (lib-name scan of
  GUROBI_HOME/lib for gurobi<digits>) is borrowed from grb-sys2.
- **Compile-gated on GUROBI_HOME**: without it the crate is not built and
  Optex.Solver.Gurobi.Native compiles to stubs returning
  {:error, :gurobi_not_available}; plain checkouts stay green. After
  installing Gurobi, recompile with `mix compile --force`. Tagged :gurobi
  tests self-exclude via available?/0. The long-term shape is the
  Ecto-adapter pattern (separate optex_gurobi package); in-repo gating
  converts to that cheaply.
- **Ranges to senses**: SolverInput rows are ranges (HiGHS-shaped); Gurobi
  rows are sense+rhs. All Transform output maps cleanly ('<', '>', '=';
  free rows become '<' with +inf rhs); a genuine two-sided range is
  rejected rather than split, which would corrupt dual indexing.
- Wire structs (SolverInput/SolveResult/IisResult) are shared with the
  HiGHS crate; each backend decodes its own raw status ints (Gurobi:
  2 optimal, 3 infeasible, 4 inf-or-unbd, 5 unbounded, 9 time limit,
  11 interrupted). IIS member statuses reuse the HiGHS ints (2/3/4), with
  row involvement inferred from the row's own sense.
- Same callback rules as HiGHS (channel + unmanaged sender thread for MSG
  callbacks); cancellation calls GRBterminate from within the callback,
  which Gurobi documents as safe. Env creation passes the verified 13.0.0
  version triple through GRBemptyenvinternal; license failures surface as
  {:error, message} from GRBstartenv, not crashes.

## Milestone 0 - version pins (2026-07-16)

- `rustler` pinned to **0.38.0** (current Hex release). Requires rustc >= 1.91; the
  machine's toolchain was updated to stable 1.97.1 via rustup.
- `highs-sys` pinned to **=1.15.0** (current crates.io release), which vendors and
  builds **HiGHS 1.15.0** (confirmed from `HiGHS/Version.txt` inside the crate:
  MAJOR=1, MINOR=15, PATCH=0).
- Building the crate on Windows/MSVC needs CMake (3.29 present) and libclang for
  bindgen (LLVM 22.1.8 installed; `LIBCLANG_PATH=C:\Program Files\LLVM\bin` set as
  a user environment variable).

## Appendix A verification against highs-sys 1.15.0 / HiGHS 1.15.0

Verified in the crate source (`src/lib.rs`) and the vendored header
(`HiGHS/highs/interfaces/highs_c_api.h`):

- `Highs_passModel(highs, num_col, num_row, num_nz, q_num_nz, a_format, q_format,
  sense, offset, col_cost, col_lower, col_upper, row_lower, row_upper, a_start,
  a_index, a_value, q_start, q_index, q_value, integrality)` - 21 parameters,
  exactly the order in the spec's reference snippet.
- The crate does NOT re-export `kHighs*` names; it defines its own constants:
  - Sense: `OBJECTIVE_SENSE_MINIMIZE = 1`, `OBJECTIVE_SENSE_MAXIMIZE = -1`.
  - Matrix format: `MATRIX_FORMAT_COLUMN_WISE = 1`.
  - Var types: `VAR_TYPE_CONTINUOUS = 0`, `VAR_TYPE_INTEGER = 1`.
  - Model status: `MODEL_STATUS_OPTIMAL = 7`, `MODEL_STATUS_INFEASIBLE = 8`,
    `MODEL_STATUS_UNBOUNDED_OR_INFEASIBLE = 9`, `MODEL_STATUS_UNBOUNDED = 10`
    (full range 0..18). The spec's placeholder integers (7/8/10) happen to be
    correct for this version.
  - Call status: `STATUS_OK = 0`, `STATUS_WARNING = 1`, `STATUS_ERROR = -1`.
- Infinity accessor: `double Highs_getInfinity(const void* highs)` exists.
- Objective retrieval: `Highs_getDoubleInfoValue(highs, "objective_function_value",
  &out)` exists, as do `Highs_setBoolOptionValue`, `Highs_getModelStatus`, and
  `Highs_getSolution` with the expected shapes.

## Milestone 2 - DSL surface adaptation (2026-07-16)

The spec's literal surface does not parse under Elixir 1.20; both offending
forms are rejected by the parser itself (verified empirically), so no macro can
ever receive them:

- `x[i, j]` is a SyntaxError: `value[key]` accepts exactly one argument.
- `expr for i <- list` juxtaposition (as in `sum(y[i] for i <- [1, 2, 3])` and
  `variable y[i] for i <- [1, 2, 3]`) is a SyntaxError: `for` is not an infix
  operator.

The intent the spec fixes (single index → bare key, multiple indices → tuple
key; generators with filters) is preserved with the closest valid syntax:

- Multi-index access and declaration use an explicit tuple key: `w[{i, j}]`.
- Generators and filters follow the expression as comma-separated arguments:
  `variable y[i], i <- [1, 2, 3], lb: 0.0` and
  `sum(y[i], i <- [1, 2, 3], i > 1)`.
- `sum(for i <- [1, 2, 3], i > 1, do: expr)` (a literal comprehension) is also
  accepted, since it is the native spelling of the same thing.

Verified AST shapes (Elixir 1.20.2): `x[i]` is
`{{:., _, [Access, :get]}, _, [{:x, _, ctx}, index_ast]}`; for `x[{i, j}]` the
`index_ast` is the tuple AST, which is exactly the quoted key expression, so
`parse_indexed_head` needs no list-to-tuple normalization (the spec's
`idx_key/1` list clause is unreachable syntax and was dropped).

## Milestone 4 - binding decisions (2026-07-16)

- **Infinity substitution happens in Rust** (the spec's preferred option). The
  Elixir side passes `:infinity`/`:neg_infinity` atoms through unchanged; the
  NIF decodes each bound as number-or-atom (a small custom `Bound` decoder) and
  substitutes `Highs_getInfinity(highs)` after creating the instance. No solver
  numeric constant exists anywhere in Elixir.
- **Vartype mapping stays in Elixir** (`Optex.Solver.HiGHS.prepare/1`), per the
  spec's reference: `:cont -> 0`, `:int -> 1`, `:bin -> 1`. It lives in the
  binding module, which is allowed to know HiGHS ints.
- The NIF returns `{:ok, %Optex.SolveResult{}} | {:error, binary}` using
  rustler's built-in `Result` encoding, instead of the spec sketch's bare
  struct-or-error. Same information; lets the firewall return an error value
  rather than raising, which the crash-safety test requires.
- `Highs_passModel`/`Highs_run` failure handling: HiGHS call status is
  0 ok / 1 warning / -1 error. Only -1 aborts the solve; a warning still leaves
  a decodable model status (the spec sketch's `!= 0` would turn benign warnings
  into errors).
- The length firewall also checks `col_start` ends exactly at nnz (cheap, and a
  mismatch there is the same over-read hazard).
- `decode_status` additionally maps 9 to `:unbounded_or_infeasible` (a status
  HiGHS presolve genuinely returns) instead of leaving it `{:other, 9}`.

## Post-v1: name-based term references (2026-07-17)

`Model.add_constraint/4` and `Model.set_objective/3` accept, besides an
`%Aff{}`, a terms list of `{reference, coefficient}` tuples where a reference
is a `%Var{}` or a variable name. Chosen over a separate builder struct
because names are already the user-facing identity (creation option, solution
keying); a builder would add a third modeling surface and eventually
reimplement Model. Resolution details: a `name_index` map maintained inside
`%Model{}` at `add_variable` time (modeling layer only, no layering impact);
duplicate names are last-wins, matching solution rekeying, so DSL shadowing
semantics are unchanged; unnamed variables are only referenceable by struct;
unknown names raise ArgumentError listing the known names; duplicate
references in one list sum, matching Aff.add.

## Post-v1: DSL constraint families (2026-07-17)

`constraint lhs OP rhs, gen_or_filter...` declares one constraint per binding
of the trailing generator/filter clauses (same comma-separated clause syntax
as `variable` and `sum`, verified against the parser). Expansion is a
comprehension over the built Aff reduced through `Model.add_constraint`;
pure macro layer, no other layer touched.

## Post-v1: solver options and dual values (2026-07-17)

Extends beyond the v1 spec scope deliberately (both were "not in scope (v1)"
items with clear triggers; writing real examples was the trigger).

- Options: `Optex.optimize/2` forwards non-`:solver` options to the backend.
  `Optex.Solver.HiGHS` accepts a closed neutral set and maps names itself:
  `:time_limit` -> "time_limit" (double), `:mip_gap` -> "mip_rel_gap"
  (double), `:threads` -> "threads" (int), `:log` -> "output_flag" (bool);
  option names verified against HiGHS 1.15.0. Unknown keys return
  `{:error, {:unknown_option, key}}`, bad values
  `{:error, {:invalid_option_value, key, value}}`, both before the NIF runs.
  The NIF takes a second wire struct (`Optex.Solver.HiGHS.Options`) with
  options pre-grouped by HiGHS value type; logging stays silenced by default
  and user options are applied after, so `log: true` can override it.
  `decode_status` learned 13 -> `:time_limit`.
- Duals: the NIF now fills the col_dual/row_dual buffers of
  `Highs_getSolution` and reports "dual_solution_status".
  `Optex.Solution` gained `duals` (keyed by constraint id in declaration
  order; constraints have no user-facing names) and `reduced_costs` (keyed
  like `values`, rekeyed by name in `optimize/2`). Both are nil unless the
  dual status is feasible (2), which is always the case for MIPs. Sign
  convention verified empirically against LP theory: for a max problem with
  <= rows, duals are the nonnegative shadow prices and a nonbasic variable's
  reduced cost equals its objective coefficient.

## Post-v1: named constraints (2026-07-17)

Constraints take a trailing `name:` option, mirroring how variable
declarations carry opts last: `constraint 2t + c <= 40, name: :carpentry`.
In a family the name expression is evaluated per binding and may reference
the generator variables (`name: {:cap, t}`). The name lands in the existing
`Optex.Constraint.name` field (unused since Milestone 1) via a new optional
opts argument on `Model.add_constraint` (both Aff and terms-list forms).
`Optex.optimize/2` rekeys `duals` by constraint name with id fallback,
completing the symmetry with values/reduced_costs. The `constraint name: cmp`
keyword-first spelling was rejected: Elixir requires keyword args last, so it
cannot coexist with trailing generator clauses.

## Post-v1: examples smoke test (2026-07-17)

`test/examples_test.exs` evaluates every `examples/*.exs` in-process with
captured output and asserts an optimum is reported, so the examples cannot
silently rot as the API evolves.

## Post-v1: packaging (2026-07-17)

MIT license (the Elixir-ecosystem default; also matches HiGHS's own license).
ex_doc 0.40 wired with README as the docs landing page and modules grouped by
layer. Hex package metadata ships the native crate sources (src, Cargo.toml,
Cargo.lock), so consumers build the NIF and HiGHS locally at compile time;
`mix hex.build` validates. Publishing is a separate, deliberate step that has
not happened.

## Post-v1: diagnostics batch (2026-07-17)

Solve statistics, log streaming, cancellation, IIS, and the objective
constant fix, plus LP export and pretty printing. Hard-won lessons recorded:

- **Objective constant**: Transform/NIF previously dropped
  `objective.constant`; it now travels as `SolverInput.obj_offset` into
  `Highs_passModel`'s offset parameter, and the MPS emitter encodes it as
  RHS -c on the N row. `objective x + 5` finally reports the 5.
- **Non-finite floats cannot cross the NIF boundary.** Erlang floats have no
  infinity; HiGHS reports mip_gap as inf for LPs, objective as +-inf for
  interrupted/infeasible solves, and mip_node_count as -1 without MIP data.
  All such values become nil (Option in Rust) or are gated on mip-ness.
- **Nothing that can panic may run on a scheduler thread via a C callback.**
  rustler's OwnedEnv::send_and_clear panics on managed threads, and a panic
  inside an extern "C" frame aborts the whole VM (observed). The HiGHS log
  callback therefore only pushes lines into an mpsc channel; a dedicated
  unmanaged thread does the sending and is joined before the NIF returns.
- **Cancellation** is a ResourceArc<AtomicBool> token polled by the HiGHS
  interrupt callbacks (types 1/2/6, verified); interrupted solves decode
  model status 17 as :interrupted. No persistent handle needed.
- **IIS**: the default iis_strategy (light, 0) only finds trivial and
  single-row infeasibilities; `Highs_getIis` needs iis_strategy = 6
  (kHighsIisStrategyFromLpRowPriority) for the full irreducible computation,
  and drives its own solves, so the NIF does not run first.
  `Optex.explain_infeasibility/2` maps members back to constraint/variable
  names via the optional `iis/2` callback on the Solver behaviour.
- **Optex.LP** emits CPLEX-LP format from the Model with sanitized user
  names (oracle-tested against the standalone binary); **Optex.Format**
  renders the model for humans with names as written. Both are modeling-layer
  and solver-neutral.

## Milestone 5 - solution keying (2026-07-16)

`Optex.optimize/2` rekeys solution values by each variable's `name`: the bare
atom for scalars (`:x`), `{family, index}` for indexed families (`{:y, 1}`).
A variable created without a name (hand-built models) keeps its integer id as
the key. The raw id-keyed map remains available by calling
`Optex.Solver.HiGHS.solve/2` directly. Duplicate names (declaring `variable x`
twice shadows the first binding) collapse to one key; don't do that.
