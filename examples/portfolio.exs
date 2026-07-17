# Markowitz portfolio: the classic quadratic program.
#
# Split capital between two assets minimizing portfolio variance
#   w' Sigma w = 0.04 a^2 + 2*0.01 ab + 0.09 b^2
# subject to full investment and a minimum expected return. Quadratic
# objectives run on every backend, including HiGHS (convex, continuous), so
# this works without any commercial solver.
#
# Run with: mix run examples/portfolio.exs

import Optex.DSL

m =
  model do
    variable a, lb: 0.0
    variable b, lb: 0.0

    constraint(a + b == 1, name: :fully_invested)
    constraint(0.08 * a + 0.12 * b >= 0.09, name: :target_return)

    objective 0.04 * a * a + 0.02 * a * b + 0.09 * b * b
  end

{:ok, sol} = Optex.optimize(m)

IO.puts("status:            #{sol.status}")
IO.puts("variance:          #{Float.round(sol.objective, 6)}")
IO.puts("volatility:        #{Float.round(:math.sqrt(sol.objective) * 100, 2)}%")
IO.puts("asset a:           #{Float.round(sol.values[:a] * 100, 2)}%")
IO.puts("asset b:           #{Float.round(sol.values[:b] * 100, 2)}%")

expected_return = 0.08 * sol.values[:a] + 0.12 * sol.values[:b]
IO.puts("expected return:   #{Float.round(expected_return * 100, 2)}%")

# Expected: the unconstrained minimum-variance split a = 8/11, b = 3/11
# happens to earn ~9.09%, so the return target is not binding; variance is
# 3.85/121 ~ 0.031818 (volatility ~17.84%).

# ---- the flip side: maximize return under a risk budget (QCP) ----
#
# Quadratic CONSTRAINTS need a capable backend: Gurobi (full, including
# nonconvex) or CPLEX (convex, <=/>= only). HiGHS rejects them.

capable =
  Enum.find([Optex.Solver.Gurobi, Optex.Solver.CPLEX], fn backend ->
    backend.available?()
  end)

if capable do
  risky =
    model sense: :max do
      variable a, lb: 0.0
      variable b, lb: 0.0
      constraint(a + b == 1, name: :fully_invested)
      constraint(0.04 * a * a + 0.02 * a * b + 0.09 * b * b <= 0.05, name: :risk_budget)
      objective 0.08 * a + 0.12 * b
    end

  {:ok, risky_sol} = Optex.optimize(risky, solver: capable)

  IO.puts("\nrisk-budget flip (#{inspect(capable)}): #{risky_sol.status}")
  IO.puts("expected return:   #{Float.round(risky_sol.objective * 100, 2)}%")
  IO.puts("asset b:           #{Float.round(risky_sol.values[:b] * 100, 2)}%")
else
  IO.puts("\n(no capable backend for the quadratic-constraint variant;")

  IO.puts(
    " HiGHS rejects it: #{inspect(elem(Optex.optimize(model do
      variable a, lb: 0.0
      constraint a * a <= 1
      objective a
    end),
    1))})"
  )
end
