# Native min/max vs the epigraph trick.
#
# Makespan scheduling: assign five jobs to two machines so the busier
# machine finishes as early as possible. Minimizing a max has a classic
# linearization, the epigraph (t >= load per machine, minimize t), which
# every backend solves. But the trick only works in one direction: an
# epigraph MAXIMIZED is unbounded, while the native construct pins
# t == max(...) exactly and works both ways. Native min/max is a
# Gurobi-only capability; every other backend rejects it strictly.
#
# Run with: mix run examples/bottleneck_minmax.exs

import Optex.DSL

jobs = [:a, :b, :c, :d, :e]
dur = %{a: 4, b: 3, c: 3, d: 2, e: 2}
machines = [1, 2]

# ---- epigraph linearization (solvable by every backend) ----

epigraph =
  model do
    variable assign[{j, m}], j <- jobs, m <- machines, type: :bin
    variable makespan, lb: 0.0

    constraint(sum(assign[{j, m}], m <- machines) == 1, j <- jobs, name: {:once, j})

    constraint(
      sum(dur[j] * assign[{j, m}], j <- jobs) <= makespan,
      m <- machines,
      name: {:load, m}
    )

    objective makespan
  end

{:ok, sol} = Optex.optimize(epigraph, solver: Optex.Solver.HiGHS)
IO.puts("epigraph makespan (HiGHS): #{sol.status}, #{sol.objective}")

# ---- native max (Gurobi only) ----

native =
  model do
    variable assign[{j, m}], j <- jobs, m <- machines, type: :bin
    variable load[m], m <- machines, lb: 0.0

    constraint(sum(assign[{j, m}], m <- machines) == 1, j <- jobs, name: {:once, j})

    constraint(
      sum(dur[j] * assign[{j, m}], j <- jobs) == load[m],
      m <- machines,
      name: {:tally, m}
    )

    variable makespan = max(load[1], load[2])
    objective makespan
  end

if Optex.Solver.Gurobi.available?() do
  {:ok, sol} = Optex.optimize(native, solver: Optex.Solver.Gurobi)

  IO.puts(
    "native makespan (Gurobi):  #{sol.status}, #{sol.objective} " <>
      "(loads #{sol.values[{:load, 1}]} and #{sol.values[{:load, 2}]})"
  )

  # the direction epigraphs cannot express: MAXIMIZE the max. Which side
  # of the yard is taller? t == max pins the answer instead of drifting
  # off to infinity.
  peak =
    model sense: :max do
      variable x, lb: 0.0, ub: 2.0
      variable y, lb: 0.0, ub: 3.0
      variable t = max(x, y)
      objective t
    end

  {:ok, sol} = Optex.optimize(peak, solver: Optex.Solver.Gurobi)
  IO.puts("maximize the max (Gurobi): #{sol.status}, peak = #{sol.objective}")
else
  # min/max is a capability, so the rejection is strict and immediate
  {:error, reason} = Optex.optimize(native, solver: Optex.Solver.HiGHS)
  IO.puts("native max without Gurobi: #{inspect(reason)}")
  IO.puts("(the epigraph result above is the answer on this machine)")
end

# Expected: makespan 7.0 from both formulations (partition {4, 3} against
# {3, 2, 2}; total work is 14, so 7 per machine is a perfect split), and
# peak = 3.0 exactly (y at its upper bound wins the max).
