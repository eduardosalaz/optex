# Special ordered sets: exclusivity without binaries.
#
# A workshop can run at most ONE shift pattern, each with its own capacity
# and hourly profit. The classic formulation gates each intensity with a
# binary and a big-M-style link (x <= cap * y, sum y <= 1). An SOS1 set
# says the same thing declaratively: at most one member may be nonzero.
# No binaries, no linking rows, and the weights hand the solver a
# branching order. SOS runs natively on Gurobi, CPLEX, and COPT; HiGHS
# rejects it strictly.
#
# Run with: mix run examples/sos_selection.exs

import Optex.DSL

patterns = [:day, :night, :weekend]
cap = %{day: 8.0, night: 6.0, weekend: 12.0}
profit = %{day: 5.0, night: 8.0, weekend: 4.5}

# ---- manual exclusivity: binaries plus linking rows (everywhere) ----

manual =
  model sense: :max do
    variable hours[p], p <- patterns, lb: 0.0
    variable run[p], p <- patterns, type: :bin

    constraint(hours[p] - cap[p] * run[p] <= 0, p <- patterns, name: {:link, p})
    constraint(sum(run[p], p <- patterns) <= 1, name: :one_pattern)

    objective sum(profit[p] * hours[p], p <- patterns)
  end

{:ok, sol} = Optex.optimize(manual, solver: Optex.Solver.HiGHS)
IO.puts("manual exclusivity (HiGHS): #{sol.status}, profit #{sol.objective}")

# ---- the same exclusivity as one SOS1 set (capable backends) ----

native =
  model sense: :max do
    variable hours[p], p <- patterns, lb: 0.0

    constraint(hours[p] <= cap[p], p <- patterns, name: {:cap, p})
    constraint(sos1([{hours[:day], 1}, {hours[:night], 2}, {hours[:weekend], 3}]), name: :pick)

    objective sum(profit[p] * hours[p], p <- patterns)
  end

capable =
  Enum.filter([Optex.Solver.Gurobi, Optex.Solver.CPLEX, Optex.Solver.COPT], fn backend ->
    backend.available?()
  end)

if capable == [] do
  IO.puts("no SOS-capable backend compiled; the manual result above is the answer")
else
  for backend <- capable do
    {:ok, sol} = Optex.optimize(native, solver: backend)

    chosen =
      Enum.find(patterns, fn p -> sol.values[{:hours, p}] > 1.0e-6 end)

    IO.puts(
      "sos1 (#{inspect(backend)}): #{sol.status}, profit #{sol.objective}, " <>
        "running #{chosen} for #{sol.values[{:hours, chosen}]} hours"
    )
  end

  # sos2 in thirty seconds: at most TWO nonzero members, and they must be
  # ADJACENT in weight order; z1 and z3 can never be nonzero together
  adjacency =
    model sense: :max do
      variable z[i], i <- [1, 2, 3], lb: 0.0, ub: 1.0
      constraint(sos2([{z[1], 1}, {z[2], 2}, {z[3], 3}]), name: :adjacent)
      objective z[1] + z[3]
    end

  [backend | _] = capable
  {:ok, sol} = Optex.optimize(adjacency, solver: backend)

  IO.puts(
    "\nsos2 adjacency (#{inspect(backend)}): maximizing z1 + z3 under " <>
      "sos2 gives #{sol.objective} (2.0 would need the non-adjacent pair)"
  )
end

# Expected: profit 54.0 from both formulations, running the weekend
# pattern for 12 hours (12 * 4.5 beats 6 * 8 = 48 and 8 * 5 = 40); the
# sos2 demo yields 1.0 because z1 and z3 are not adjacent.
