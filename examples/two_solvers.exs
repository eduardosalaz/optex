# Two backends, one model: the solver: option in action.
#
# The same %Optex.Model{} solves through HiGHS (always available, built from
# source) and Gurobi (available when the native crate was compiled against an
# installed, licensed Gurobi; check Optex.Solver.Gurobi.available?/0).
# Nothing about the model changes per backend; only the option does. Both
# backends implement the full contract: options, stats, duals, log streaming,
# cancellation, and IIS.
#
# Run with: mix run examples/two_solvers.exs

import Optex.DSL

# a small capacitated facility choice: open sites (binary) to serve demand
sites = [:north, :south]
fixed = %{north: 40.0, south: 55.0}
capacity = %{north: 70, south: 90}

m =
  model sense: :min do
    variable open[s], s <- sites, type: :bin
    variable ship[s], s <- sites, lb: 0.0

    constraint(ship[:north] + ship[:south] == 100, name: :demand)
    constraint(ship[s] <= capacity[s] * open[s], s <- sites, name: {:cap, s})

    objective sum(fixed[s] * open[s], s <- sites) + 2 * ship[:north] + 3 * ship[:south]
  end

solve = fn backend ->
  {:ok, sol} = Optex.optimize(m, solver: backend, threads: 1)

  IO.puts("#{inspect(backend)}")
  IO.puts("  status:    #{sol.status}")
  IO.puts("  objective: #{sol.objective}")

  IO.puts(
    "  plan:      open " <>
      Enum.map_join(sites, ", ", fn s ->
        "#{s}=#{round(sol.values[{:open, s}])} (ship #{round(sol.values[{:ship, s}])})"
      end)
  )

  IO.puts("  time:      #{Float.round(sol.stats.solve_time, 4)}s\n")
  sol
end

highs_sol = solve.(Optex.Solver.HiGHS)

if Optex.Solver.Gurobi.available?() do
  gurobi_sol = solve.(Optex.Solver.Gurobi)

  agree? = abs(highs_sol.objective - gurobi_sol.objective) < 1.0e-6
  IO.puts("backends agree on the objective: #{agree?}")
else
  IO.puts("Gurobi backend not compiled (GUROBI_HOME was unset at build time);")
  IO.puts("the HiGHS result above is the full story on this machine.")
end

# Expected: objective 325.0 opening both sites, shipping 70 from north (cost
# 2) and 30 from south (cost 3): 40 + 55 + 140 + 90 = 325. Serving everything
# from one site is impossible (capacities 70 and 90 against demand 100).
