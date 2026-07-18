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
- `portfolio.exs`: Markowitz minimum-variance portfolio, the classic
  quadratic program. Quadratic objectives (`x * x`, `x * y` terms) run on
  every backend including HiGHS (convex, continuous). The second section
  flips the problem into a QCP (maximize return under a variance budget),
  which needs a quadratic-constraint-capable backend (Gurobi or CPLEX).
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
- `bottleneck_minmax.exs`: makespan scheduling stated as an epigraph
  (`t >= load`, solvable everywhere) and as a native
  `variable makespan = max(...)` (Gurobi only), plus the direction the
  epigraph cannot express: maximizing the max.
- `step_tariffs.exs`: a customs-fee cost curve with a jump discontinuity,
  encoded as a `pwl` with a repeated x breakpoint (Gurobi/CPLEX), against
  the manual binary-plus-big-M version (everywhere). Same optimum.
- `qcp_shadow_prices.exs`: convex QP on HiGHS, then a quadratic capacity
  envelope as a QCP with `qcp_duals: true` on Gurobi: the qconstraint's
  dual is the shadow price of the envelope. Shows the strict rejection of
  the option on backends whose C APIs expose no quadratic constraint duals.
- `infeasibility_autopsy.exs`: an overcommitted staffing plan run through
  `Optex.explain_infeasibility/2`: the IIS names the minimal clash by
  constraint name, innocent rows stay out, and constructs outside the IIS
  scope are reported under `not_examined`.
- `inspect_and_export.exs`: `Optex.Format.pretty/1` rendering a model full
  of constructs and quadratics, and `Optex.LP.emit/1` refusing what plain
  LP format cannot represent, then exporting a sanitized MILP.
- `sos_selection.exs`: at-most-one-shift-pattern exclusivity stated twice:
  binaries plus linking rows (everywhere) versus one `sos1` set (Gurobi,
  CPLEX, COPT), same optimum, no big-M. Plus a thirty-second `sos2`
  adjacency demo.
- `cone_portfolio.exs`: risk penalized versus risk budgeted: the
  min-variance QP (everywhere, HiGHS included) against a return-max SOCP
  with `constraint norm(...) <= 0.10` (Gurobi, CPLEX, COPT), showing the
  expression members' aux lifting and the pinned head variable.
- `progress.exs`: watching a solve live: `progress:` streams throttled
  solver snapshots (best objective, bound, nodes) and `incumbents:` streams
  every improving solution with name-keyed values. Works on every backend;
  pairs with the cancel token for stop-when-good-enough rules.
- `stopping_rule.exs`: callbacks the BEAM way: the solve in a Task, the
  progress stream in a receive loop, the cancel token as the trigger.
  Solves to proven optimality for reference, then stops a re-solve the
  moment the gap dips under 2%, trading a sliver of quality for a large
  speedup. No solver-side callback code, no user code on solver threads.
- `all_backends.exs`: the same model solved through every available backend
  via the `solver:` option (HiGHS always; Gurobi, CPLEX, and COPT when
  their `available?/0` says so), printing each backend's plan and
  confirming they agree on the objective. Degrades gracefully to
  HiGHS-only on machines without commercial solvers.

The first solve after a fresh checkout triggers the Rust/HiGHS build and takes
a few minutes; after that, runs are instant.
