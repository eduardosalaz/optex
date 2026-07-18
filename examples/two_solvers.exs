# Multiple backends, one model: the solver: option in action.
#
# The same %Optex.Model{} solves through HiGHS (always available, built from
# source) and any compiled commercial backend: Gurobi, CPLEX, and COPT, each
# gated on its install being present at build time (check available?/0 on
# each). Nothing about the model changes per backend; only the option does.
# All backends implement the full contract: options, stats, duals, log
# streaming, cancellation, and IIS.
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

commercial =
  Enum.filter([Optex.Solver.Gurobi, Optex.Solver.CPLEX, Optex.Solver.COPT], fn backend ->
    backend.available?()
  end)

if commercial == [] do
  IO.puts("no commercial backend compiled (GUROBI_HOME / CPLEX_STUDIO_DIR* /")
  IO.puts("COPT_HOME unset at build time); the HiGHS result above is the full story.")
else
  agree? =
    Enum.all?(commercial, fn backend ->
      sol = solve.(backend)
      abs(highs_sol.objective - sol.objective) < 1.0e-6
    end)

  IO.puts("all backends agree on the objective: #{agree?}")
end

# Expected: objective 325.0 opening both sites, shipping 70 from north (cost
# 2) and 30 from south (cost 3): 40 + 55 + 140 + 90 = 325. Serving everything
# from one site is impossible (capacities 70 and 90 against demand 100).
