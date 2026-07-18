# Quadratic programs, quadratic constraints, and QCP duals.
#
# Quadratic OBJECTIVES (with literal coefficients, exactly as written) run
# on every backend, including HiGHS for the convex continuous case.
# Quadratic CONSTRAINTS need a capable backend, and their dual values are a
# separate opt-in: qcp_duals: true makes Gurobi compute them (its QCPDual
# parameter costs extra work, so it never happens silently) and returns
# them in Solution.qcon_duals keyed by qconstraint name. Every other
# backend rejects the request instead of returning nothing quietly.
#
# Run with: mix run examples/qcp_shadow_prices.exs

import Optex.DSL

# ---- convex QP on the default backend: min x^2 + y^2 - 4x - 6y ----

qp =
  model do
    variable x, lb: 0.0
    variable y, lb: 0.0
    objective x * x + y * y - 4 * x - 6 * y
  end

{:ok, sol} = Optex.optimize(qp)

IO.puts(
  "convex QP (HiGHS): #{sol.status}, objective #{sol.objective} " <>
    "at (#{sol.values[:x]}, #{sol.values[:y]})"
)

# requesting QCP duals on a backend without them fails fast, always
{:error, reason} = Optex.optimize(qp, qcp_duals: true)
IO.puts("qcp_duals on HiGHS: #{inspect(reason)}\n")

# ---- QCP with duals: two products inside a quadratic capacity envelope ----

# max x + y s.t. x^2 + y^2 <= 2. The optimum sits where the objective is
# tangent to the circle, at (1, 1). The qconstraint's dual is the shadow
# price of the envelope: stationarity gives lambda = 0.5, so one more unit
# of quadratic capacity is worth 0.5 in objective, at the margin.

qcp =
  model sense: :max do
    variable x, lb: 0.0
    variable y, lb: 0.0
    constraint(x * x + y * y <= 2, name: :envelope)
    objective x + y
  end

if Optex.Solver.Gurobi.available?() do
  {:ok, sol} = Optex.optimize(qcp, solver: Optex.Solver.Gurobi, qcp_duals: true)

  IO.puts("QCP (Gurobi):  #{sol.status}, objective #{Float.round(sol.objective, 6)}")
  IO.puts("shadow price of the envelope: #{Float.round(sol.qcon_duals[:envelope], 6)}")
else
  IO.puts("Gurobi not compiled; QCP duals are a Gurobi-only capability")
end

# COPT and CPLEX solve convex QCPs but their C APIs expose no quadratic
# constraint duals, so the option is rejected rather than half-honored
for backend <- [Optex.Solver.CPLEX, Optex.Solver.COPT], backend.available?() do
  {:ok, sol} = Optex.optimize(qcp, solver: backend)
  {:error, reason} = Optex.optimize(qcp, solver: backend, qcp_duals: true)

  IO.puts(
    "#{inspect(backend)}: solves the QCP (#{sol.status}, " <>
      "#{Float.round(sol.objective, 6)}) but qcp_duals -> #{inspect(reason)}"
  )
end

# Expected: QP optimum -13.0 at (2, 3) (the gradient zero, only correct
# because coefficients are literal); QCP objective 2.0 at (1, 1) with an
# envelope dual of exactly 0.5.
