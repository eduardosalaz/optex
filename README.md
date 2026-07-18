# Optex

An Elixir library for modeling and solving linear, mixed-integer, and
quadratic programs (LP, MILP, QP, QCP, plus native indicator, absolute-value,
and piecewise-linear constructs), with in-process solver bindings via
Rustler: [HiGHS](https://highs.dev) (built from source, always available)
and optionally [Gurobi](https://www.gurobi.com) and
[CPLEX](https://www.ibm.com/products/ilog-cplex-optimization-studio)
(`solver: Optex.Solver.Gurobi` / `Optex.Solver.CPLEX`, each compiled only
when its licensed installation is present at build time).

Three cleanly separated layers:

1. **Modeling** (pure Elixir): a declarative `model do ... end` DSL,
   affine/quadratic expressions, an immutable model struct.
2. **Solver abstraction** (pure Elixir): a `Optex.Solver` behaviour with a
   strict capability model and a neutral column-sparse `Optex.SolverInput`.
3. **Binding** (Rustler): one dirty NIF per backend that hands the whole
   model to the solver and returns the solution.

## Usage

```elixir
import Optex.DSL

m =
  model sense: :max do
    variable x, lb: 0.0
    variable y[i], i <- [1, 2, 3], lb: 0.0
    variable pick, type: :bin

    constraint x + sum(y[i], i <- [1, 2, 3]) <= 10
    constraint sum(y[i], i <- [1, 2, 3], i > 1) <= 4
    constraint x - pick <= 6
    objective x + 2 * y[1] + pick
  end

{:ok, sol} = Optex.optimize(m)

sol.status          #=> :optimal
sol.objective       #=> the optimal objective value
sol.values[:x]      #=> value of x
sol.values[{:y, 2}] #=> value of y[2]
```

Solution values are keyed by the names used in the model: the bare atom for a
scalar variable, `{family, index}` for indexed families. Multi-index families
use explicit tuple keys: declare `variable w[{i, j}], i <- 1..2, j <- 1..3`
and read `sol.values[{:w, {1, 2}}]`. (Elixir's parser does not accept
`w[i, j]`.)

Runnable, commented examples live in [`examples/`](examples/README.md), from a
starter LP to an assignment problem and a data-driven multi-period plan:
`mix run examples/knapsack.exs`.

Variable types are `:cont` (default), `:int`, and `:bin`; binary variables get
`[0, 1]` bounds automatically. Bounds accept numbers or symbolic
`:infinity`/`:neg_infinity`. Constraints use `<=`, `>=`, `==` with variables
and constants on either side. `sum/2+` takes generators and filters as
arguments; a literal `for` comprehension works too. A constraint with
trailing generator clauses declares a whole family, one row per binding:

```elixir
constraint sum(ship[{p, mk}], mk <- markets) <= supply[p], p <- plants
```

Native general constraints (solved by the solver's own construct, never
reformulated) are available on capable backends (Gurobi, CPLEX; HiGHS rejects
them with `{:error, {:unsupported, construct, backend}}`):

```elixir
constraint ship[s] <= cap[s], s <- sites, if: open[s]   # indicator: open -> row
constraint x <= 1, if: {b, 0}                           # active when b = 0
variable t = abs(x - y)                                 # exact absolute value
variable c = pwl(x, [{0, 0}, {10, 10}, {20, 30}])       # piecewise-linear cost
variable m = max(x, y, 3.5)                             # native max (Gurobi only)
constraint norm(x - y, z) <= t                          # second-order cone
constraint sos1([{x, 1}, {y, 2}]), name: :pick          # special ordered set
```

`pwl` breakpoints are `{x, y}` pairs with non-decreasing x; consecutive
points are joined by segments and the first and last segments extend beyond
the breakpoint range (identical semantics on every capable backend). Two
consecutive points sharing an x with different y values define a jump
discontinuity; at the jump the solver may pick either value, and jumps must
be interior (the end segments define the extension slopes).

`max`/`min` accept any mix of linear expressions and numbers (numbers fold
into one constant operand) and are a Gurobi-only capability; HiGHS and CPLEX
reject them.

`norm(exprs...) <= bound` declares a second-order cone (`bound >= sqrt(sum
of squares)`), solved natively on Gurobi, CPLEX, and COPT (each through its
own documented encoding); rotated cones (`2 h1 h2 >= sum of squares`) are
available programmatically via `Optex.Model.add_rotated_cone/5`. Cone
bounds must be nonnegative variables (expressions get an auxiliary head).
`sos1`/`sos2` declare special ordered sets over `{variable, weight}` pairs
(distinct weights define the order; SOS2 adjacency follows it), on the same
three backends.

No big-M anywhere: the solver handles the logic internally. `abs`/`max`/`min`
deeper inside expressions are rejected at build time with guidance.

Constraints take a trailing `name:` option (evaluated per binding in a
family, so it may reference the generator variables):

```elixir
constraint 2 * tables + chairs <= 40, name: :carpentry
constraint x[t] <= cap[t], t <- periods, name: {:cap, t}
```

`optimize/2` accepts solver options: `time_limit:`, `mip_gap:`, `threads:`,
`log:` (`true` for stdout, or a pid that receives `{:optex_highs_log, line}`
messages), and `cancel:` (a token from `Optex.Solver.HiGHS.cancel_token/0`;
calling `cancel/1` from another process interrupts the solve, which returns
status `:interrupted`).

Long MIP solves can be watched live on every backend: `progress:` streams
throttled `{:optex_progress, %{best_obj, best_bound, gap, nodes, time}}`
maps (`progress_every:` sets the throttle in ms, default 1000; fields a
backend does not report are nil), and `incumbents:` streams
`{:optex_incumbent, %{objective, values}}` for each improving solution with
values keyed by variable name. Combining `progress:` with a cancel token
gives stop-when-good-enough rules in plain Elixir: watch the stream,
decide, cancel.

Solutions carry `stats` (solve time, simplex iterations, nodes, achieved MIP
gap), and for LPs `duals` (keyed by constraint name, id fallback for unnamed
rows) and `reduced_costs` (by variable name); both are `nil` for models with
integer variables. `duals` covers linear rows only; on Gurobi, passing
`qcp_duals: true` additionally returns quadratic constraint duals in
`qcon_duals` (keyed by qconstraint name) for continuous QCPs, at the cost of
the extra dual computation Gurobi's QCPDual parameter enables. Backends
without that capability reject the option.

Debugging aids:

- `Optex.explain_infeasibility(m)` computes an irreducible infeasible
  subsystem: the minimal set of named constraints and variable bounds that
  conflict. On Gurobi the IIS examines the full model, and conflicting
  native constructs (indicators, abs/pwl/min-max definitions, quadratic
  constraints) are reported as `{kind, name}` under `constructs`; on other
  backends the analysis covers the linear relaxation and constructs are
  stripped and reported under `not_examined`.
- `Optex.Format.pretty(m)` renders the model as readable text with the names
  as written; `Optex.LP.emit(m)` writes an LP-format file with sanitized
  names for hand inspection or other solvers.

Objectives and constraints may be quadratic, with literal coefficients:

```elixir
objective x * x + 2 * x * y - 3 * x            # QP, all backends
constraint x * x + y * y <= 2, name: :ball     # QCP, capable backends
```

The capability matrix is strict, and unsupported inputs fail with
`{:error, {:unsupported, construct, backend}}` before solving:

| | HiGHS | Gurobi | CPLEX | COPT |
|---|---|---|---|---|
| quadratic objective | convex, continuous only | full (MIQP, nonconvex) | convex, incl. MIQP | convex, incl. MIQP |
| quadratic constraint | no | full (nonconvex, equality) | convex, `<=`/`>=` only | convex, `<=`/`>=` only |

Quadratic terms in indicator rows or abs/pwl arguments are rejected at
build time, and products of degree greater than two raise
`Optex.NonlinearError`.

## Solver backends

`optimize/2` takes `solver: Optex.Solver.HiGHS` (default),
`Optex.Solver.Gurobi`, `Optex.Solver.CPLEX`, or `Optex.Solver.COPT`. All
implement the full contract: options, stats, duals, reduced costs, log
streaming, cancellation, and IIS, and a cross-solver test suite pins them
to agreeing objectives and duals. The commercial backends are compile-gated
on their installations (`GUROBI_HOME`; the versioned `CPLEX_STUDIO_DIR*`
var; `COPT_HOME`); without them the rest of the library builds and works
normally and each backend's `available?/0` returns false. Log messages
arrive as `{:optex_<backend>_log, line}` (for example
`{:optex_gurobi_log, line}`), and cancel tokens come from each backend's
own `cancel_token/0` (tokens are backend-specific). COPT supports
indicator constraints and convex quadratics but has no native abs, pwl, or
min/max constructs, so those inputs are rejected on it.

## Not in scope

Deliberately deferred, so the boundary is visible:

- General nonlinearity beyond quadratics and second-order cones -
  products of degree greater than two are rejected at build time, never
  represented.
- Persistent solver handles, warm starts, incremental modification.
- Basis information.
- Multi-objective; control callbacks (lazy constraints, user cuts,
  heuristic injection) - progress/incumbent streaming is built in.

## Building

Requires Elixir (~> 1.20), Rust (1.91+), CMake, and libclang (for bindgen):

- `highs-sys` is pinned to 1.15.0 and builds HiGHS 1.15.0 from source via
  CMake at `mix compile` time.
- On Windows, install LLVM and set `LIBCLANG_PATH` to its `bin` directory if
  bindgen cannot find libclang.

Run tests with `mix test`. Oracle tests cross-check the NIF against a
standalone HiGHS binary via an MPS emitter, and backend tests self-exclude
without the corresponding solver installed; the suite includes performance
regression tests that guard the scaling of every hot phase. Benchmarks live
in `bench/` (`mix run bench/benchmarks.exs`, `mix run bench/scale.exs`)
with tracked baselines in `bench/BASELINE.md`.

Generate API docs with `mix docs` (ExDoc; output in `doc/`).

Design decisions and version-pin verification notes live in `DECISIONS.md`.

## License

MIT, see `LICENSE`. HiGHS itself is MIT-licensed and is built from source via
the `highs-sys` crate at compile time.
