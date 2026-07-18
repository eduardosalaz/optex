# Piecewise-linear jump discontinuities: step tariffs.
#
# Importing a good costs 1/unit, but crossing 10 units triggers a flat
# customs fee of 15. That cost curve has a JUMP at q = 10: it is 10 just
# below the threshold and 25 just past it. A pwl breakpoint list encodes
# the jump by repeating the x value with two different y values:
#
#     [{0, 0}, {10, 10}, {10, 25}, {30, 45}]
#
# Jumps must be interior (the first and last segments define how the curve
# extends beyond its range), and at the jump x itself either y is feasible;
# the objective direction picks the favorable one. The manual equivalent
# needs a binary and a big-M. Native pwl runs on Gurobi and CPLEX.
#
# Run with: mix run examples/step_tariffs.exs

import Optex.DSL

demand = 12

# ---- manual linearization: binary fee trigger plus big-M ----

manual =
  model do
    variable q, lb: 0.0, ub: 30.0
    variable fee, type: :bin

    constraint(q >= demand, name: :demand)
    # crossing 10 units without paying the fee is impossible (M = 20 caps q)
    constraint(q - 20 * fee <= 10, name: :threshold)

    objective q + 15 * fee
  end

{:ok, sol} = Optex.optimize(manual, solver: Optex.Solver.HiGHS)
IO.puts("manual step (HiGHS):  #{sol.status}, cost #{sol.objective} at q = #{sol.values[:q]}")

# ---- native pwl with a jump (Gurobi / CPLEX) ----

native =
  model do
    variable q, lb: 0.0, ub: 30.0
    variable cost = pwl(q, [{0, 0}, {10, 10}, {10, 25}, {30, 45}])

    constraint(q >= demand, name: :demand)
    objective cost
  end

capable =
  Enum.filter([Optex.Solver.Gurobi, Optex.Solver.CPLEX], fn backend ->
    backend.available?()
  end)

if capable == [] do
  IO.puts("no pwl-capable backend compiled; the manual result above is the answer")
else
  for backend <- capable do
    {:ok, sol} = Optex.optimize(native, solver: backend)

    IO.puts(
      "native jump (#{inspect(backend)}): #{sol.status}, " <>
        "cost #{sol.values[:cost]} at q = #{sol.values[:q]}"
    )
  end
end

# Expected: cost 27.0 at q = 12 from both formulations: the fee is
# unavoidable at demand 12 (25 at the jump plus 2 more units at slope 1).
# Staying under the threshold would cap q at 10, short of demand.
