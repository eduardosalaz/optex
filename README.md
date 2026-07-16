# Optex

An Elixir library for modeling and solving mixed-integer linear programs
(MILPs), with an in-process [HiGHS](https://highs.dev) binding via Rustler.

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

Variable types are `:cont` (default), `:int`, and `:bin`; binary variables get
`[0, 1]` bounds automatically. Bounds accept numbers or symbolic
`:infinity`/`:neg_infinity`. Constraints use `<=`, `>=`, `==` with variables
and constants on either side. `sum/2+` takes generators and filters as
arguments; a literal `for` comprehension works too.

Products of two variable-bearing expressions raise `Optex.NonlinearError` at
model build time - MILPs are linear by definition.

## Not in scope (v1)

Deliberately deferred, so the boundary is visible:

- Gurobi or any second solver (the `Optex.Solver` behaviour is the seam; v1
  ships HiGHS only).
- Quadratic or nonlinear terms - rejected at build time, never represented.
- Persistent solver handles, warm starts, incremental modification.
- Solve cancellation / interruption.
- Dual values, reduced costs, basis information (primal values and objective
  only).
- Multi-objective, indicator/SOS/lazy constraints, callbacks.
- Solver parameter passthrough / tuning.

## Building

Requires Elixir (~> 1.15), Rust (1.91+), CMake, and libclang (for bindgen):

- `highs-sys` is pinned to 1.15.0 and builds HiGHS 1.15.0 from source via
  CMake at `mix compile` time.
- On Windows, install LLVM and set `LIBCLANG_PATH` to its `bin` directory if
  bindgen cannot find libclang.

Run tests with `mix test`. Oracle tests cross-check the NIF against a
standalone HiGHS binary via an MPS emitter; they are excluded automatically
unless a binary is found (point `OPTEX_HIGHS_EXE` at one to enable them).

Design decisions and version-pin verification notes live in `DECISIONS.md`.
