# Optex

An Elixir library for modeling and solving mixed-integer linear programs
(MILPs), with in-process solver bindings via Rustler: [HiGHS](https://highs.dev)
(built from source, always available) and optionally
[Gurobi](https://www.gurobi.com) and [CPLEX](https://www.ibm.com/products/ilog-cplex-optimization-studio)
(`solver: Optex.Solver.Gurobi` / `Optex.Solver.CPLEX`, each compiled only
when its licensed installation is present at build time).

Three cleanly separated layers:

1. **Modeling** (pure Elixir): a declarative `model do ... end` DSL, affine
   expressions, an immutable model struct.
2. **Solver abstraction** (pure Elixir): a `Optex.Solver` behaviour and a
   neutral column-sparse `Optex.SolverInput`.
3. **Binding** (Rustler): one dirty NIF that hands the whole model to HiGHS
   and returns the solution.

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
```

`pwl` breakpoints are `{x, y}` pairs with strictly increasing x; consecutive
points are joined by segments and the first and last segments extend beyond
the breakpoint range (identical semantics on every capable backend).

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

Solutions carry `stats` (solve time, simplex iterations, nodes, achieved MIP
gap), and for LPs `duals` (keyed by constraint name, id fallback for unnamed
rows) and `reduced_costs` (by variable name); both are `nil` for models with
integer variables.

Debugging aids:

- `Optex.explain_infeasibility(m)` computes an irreducible infeasible
  subsystem: the minimal set of named constraints and variable bounds that
  conflict.
- `Optex.Format.pretty(m)` renders the model as readable text with the names
  as written; `Optex.LP.emit(m)` writes an LP-format file with sanitized
  names for hand inspection or other solvers.

Objectives may be quadratic: `objective x * x + 2 * x * y - 3 * x` works
with literal coefficients on every backend (HiGHS solves convex continuous
QPs; Gurobi and CPLEX also solve MIQP, and Gurobi handles nonconvex).
Quadratic terms anywhere else (constraints, abs/pwl arguments) are rejected
at build time, and products of degree greater than two raise
`Optex.NonlinearError`.

## Solver backends

`optimize/2` takes `solver: Optex.Solver.HiGHS` (default),
`Optex.Solver.Gurobi`, or `Optex.Solver.CPLEX`. All implement the full
contract: options, stats, duals, reduced costs, log streaming, cancellation,
and IIS, and a cross-solver test suite pins them to agreeing objectives and
duals. The commercial backends are compile-gated on their installations
(`GUROBI_HOME`; the versioned `CPLEX_STUDIO_DIR*` var); without them the
rest of the library builds and works normally and each backend's
`available?/0` returns false. Log messages arrive as
`{:optex_gurobi_log, line}` / `{:optex_cplex_log, line}`, and cancel tokens
come from each backend's own `cancel_token/0` (tokens are backend-specific).

## Not in scope

Deliberately deferred, so the boundary is visible:

- Quadratic or nonlinear terms - rejected at build time, never represented.
- Persistent solver handles, warm starts, incremental modification.
- Basis information.
- Multi-objective, indicator/SOS/lazy constraints, user callbacks.

## Building

Requires Elixir (~> 1.15), Rust (1.91+), CMake, and libclang (for bindgen):

- `highs-sys` is pinned to 1.15.0 and builds HiGHS 1.15.0 from source via
  CMake at `mix compile` time.
- On Windows, install LLVM and set `LIBCLANG_PATH` to its `bin` directory if
  bindgen cannot find libclang.

Run tests with `mix test`. Oracle tests cross-check the NIF against a
standalone HiGHS binary via an MPS emitter; they are excluded automatically
unless a binary is found (point `OPTEX_HIGHS_EXE` at one to enable them).

Generate API docs with `mix docs` (ExDoc; output in `doc/`).

Design decisions and version-pin verification notes live in `DECISIONS.md`.

## License

MIT, see `LICENSE`. HiGHS itself is MIT-licensed and is built from source via
the `highs-sys` crate at compile time.
