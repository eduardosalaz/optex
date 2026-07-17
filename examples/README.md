# Examples

Runnable scripts demonstrating Optex, ordered from starter to advanced. Run
any of them from the repo root:

    mix run examples/product_mix.exs

- `product_mix.exs`: the classic two-variable LP. Scalar variables,
  constraints, objective, reading values back by name.
- `knapsack.exs`: binary knapsack. Indexed variable families (`take[i]`),
  `sum` over an item list, coefficients pulled from plain maps at runtime.
- `assignment.exs`: assignment problem. Two-index families with tuple keys
  (`assign[{w, t}]`), multiple generators in one `sum`, equality constraints.
- `diet.exs`: minimum-cost diet. `>=` nutrient rows, a single-variable side
  constraint (per-index bounds cannot go in a family declaration), objective
  and constraints from data maps.
- `production_plan.exs`: multi-period planning with the programmatic
  `Optex.Model` API instead of the DSL. Constraints and the objective are
  `{name, coefficient}` terms lists resolved against variable names, so the
  build pipes. Use this style when constraints are generated from data (one
  balance equation per period); the DSL writes each constraint out
  explicitly.
- `transportation.exs`: plants-to-markets shipping. Programmatic supply (`<=`)
  and demand (`==`) constraint families over tuple-named route variables.
- `facility_location.exs`: capacitated facility location. Fixed-charge
  binaries gate continuous shipments through linking rows
  (`ship total <= capacity * open`), the canonical mixed-binary MILP pattern.
- `sudoku.exs`: sudoku as pure feasibility, no objective at all. 729 binary
  variables and 324 equality rows; givens fixed through variable bounds. Also
  a small stress test of the transform and the NIF.

The first solve after a fresh checkout triggers the Rust/HiGHS build and takes
a few minutes; after that, runs are instant.
