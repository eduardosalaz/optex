# Second-order cones: bounding risk instead of penalizing it.
#
# Three independent assets with returns and volatilities. Two ways to
# treat risk:
#
#   1. Penalize it: minimize the variance subject to a return floor. That
#      is a convex QP and every backend solves it, HiGHS included.
#   2. Budget it: maximize return subject to a hard cap on the standard
#      deviation. The cap is `||(sigma_i * w_i)|| <= budget`, a
#      second-order cone: exactly what `constraint norm(...) <= bound`
#      declares. Native on Gurobi, CPLEX, and COPT; HiGHS rejects it.
#
# The cone members here are expressions (sigma_i * w_i), which lift
# through auxiliary variables automatically, and the constant bound gets
# a nonnegative head variable pinned to it: both visible in the solution.
#
# Run with: mix run examples/cone_portfolio.exs

import Optex.DSL

assets = [:a, :b, :c]
ret = %{a: 0.05, b: 0.09, c: 0.13}
vol = %{a: 0.05, b: 0.12, c: 0.25}

# ---- risk as a penalty: minimum-variance QP (everywhere) ----

qp =
  model do
    variable w[i], i <- assets, lb: 0.0
    constraint(sum(w[i], i <- assets) == 1, name: :budget)
    constraint(sum(ret[i] * w[i], i <- assets) >= 0.08, name: :floor)
    objective sum(vol[i] * vol[i] * w[i] * w[i], i <- assets)
  end

{:ok, sol} = Optex.optimize(qp, solver: Optex.Solver.HiGHS)

IO.puts("min-variance QP (HiGHS): #{sol.status}")
IO.puts("  std dev #{Float.round(:math.sqrt(sol.objective), 4)} at return floor 0.08")

IO.puts(
  "  weights " <>
    Enum.map_join(assets, ", ", fn i -> "#{i}=#{Float.round(sol.values[{:w, i}], 3)}" end)
)

# ---- risk as a budget: return-max SOCP (capable backends) ----

socp =
  model sense: :max do
    variable w[i], i <- assets, lb: 0.0
    constraint(sum(w[i], i <- assets) == 1, name: :budget)

    constraint(norm(vol[:a] * w[:a], vol[:b] * w[:b], vol[:c] * w[:c]) <= 0.10,
      name: :risk_cap
    )

    objective sum(ret[i] * w[i], i <- assets)
  end

capable =
  Enum.filter([Optex.Solver.Gurobi, Optex.Solver.CPLEX, Optex.Solver.COPT], fn backend ->
    backend.available?()
  end)

if capable == [] do
  IO.puts("\nno cone-capable backend compiled; the QP above is the answer")
else
  IO.puts("\nreturn-max SOCP, std dev capped at 0.10:")

  for backend <- capable do
    {:ok, sol} = Optex.optimize(socp, solver: backend)

    IO.puts(
      "  #{inspect(backend)}: #{sol.status}, return #{Float.round(sol.objective, 5)}, " <>
        "risk used #{Float.round(sol.values[{:risk_cap, :head}], 5)}, weights " <>
        Enum.map_join(assets, ", ", fn i -> "#{i}=#{Float.round(sol.values[{:w, i}], 3)}" end)
    )
  end

  IO.puts("  ({:risk_cap, :head} is the auxiliary head pinned to the 0.10 bound)")
end

# Expected: the QP finds the least-risk mix that still returns 8%; the
# SOCP spends the whole 0.10 risk budget to push return above that, all
# capable backends agreeing on the same objective. Rotated cones
# (2 h1 h2 >= sum of squares) are available via
# Optex.Model.add_rotated_cone/5 for quadratic-over-linear shapes.
