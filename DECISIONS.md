# Decision log

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

## Milestone 5 - solution keying (2026-07-16)

`Optex.optimize/2` rekeys solution values by each variable's `name`: the bare
atom for scalars (`:x`), `{family, index}` for indexed families (`{:y, 1}`).
A variable created without a name (hand-built models) keeps its integer id as
the key. The raw id-keyed map remains available by calling
`Optex.Solver.HiGHS.solve/2` directly. Duplicate names (declaring `variable x`
twice shadows the first binding) collapse to one key; don't do that.
