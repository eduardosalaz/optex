# Examples

Runnable scripts demonstrating Optex, ordered from starter to advanced. Run
any of them from the repo root:

    mix run examples/product_mix.exs

- `product_mix.exs`: the classic two-variable LP. Scalar variables,
  constraints, objective, reading values back by name.
- `knapsack.exs`: binary knapsack. Indexed variable families (`take[i]`),
  `sum` over an item list, coefficients pulled from plain maps at runtime.
- `assignment.exs`: assignment problem. Two-index families with tuple keys
  (`assign[{w, t}]`), multiple generators in one `sum`, and constraint
  families (a trailing generator emits one row per binding).
- `diet.exs`: minimum-cost diet. `>=` nutrient rows, a single-variable side
  constraint (per-index bounds cannot go in a family declaration), objective
  and constraints from data maps.
- `production_plan.exs`: multi-period planning with the programmatic
  `Optex.Model` API instead of the DSL. Constraints and the objective are
  `{name, coefficient}` terms lists resolved against variable names, so the
  build pipes. Use this style when the model is assembled dynamically or you
  prefer plain functions; the DSL's constraint families cover the
  data-driven case too.
- `transportation.exs`: plants-to-markets shipping. Programmatic supply (`<=`)
  and demand (`==`) constraint families over tuple-named route variables.
- `facility_location.exs`: capacitated facility location. Fixed-charge
  binaries gate continuous shipments through linking rows
  (`ship total <= capacity * open`), the canonical mixed-binary MILP pattern.
- `options_and_duals.exs`: solver options through `optimize/2`
  (`time_limit:`, `threads:`, `mip_gap:`, `log:`) and how to read the dual
  information of an LP: shadow prices per constraint and reduced costs per
  variable, with their economic interpretation. Also shows that MIPs carry no
  duals and that an unknown option fails fast.
- `sudoku.exs`: sudoku as pure feasibility, no objective at all. 729 binary
  variables and 324 equality rows; givens fixed through variable bounds. Also
  a small stress test of the transform and the NIF.
- `native_constructs.exs`: the same procurement model stated twice: manually
  linearized (tier splitting, big-M contract logic, two-row abs expansion,
  solvable everywhere) versus native general constraints (`pwl`, `if:`,
  `abs`, capable backends only, with HiGHS's strict rejection shown). Both
  land on the same optimum; the native version just says what it means.
- `two_solvers.exs`: the same model solved through both backends via the
  `solver:` option (HiGHS always; Gurobi when
  `Optex.Solver.Gurobi.available?/0`), printing each backend's plan and
  confirming they agree on the objective. Degrades gracefully to HiGHS-only
  on machines without Gurobi.

The first solve after a fresh checkout triggers the Rust/HiGHS build and takes
a few minutes; after that, runs are instant.
