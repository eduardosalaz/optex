# Decision log

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
