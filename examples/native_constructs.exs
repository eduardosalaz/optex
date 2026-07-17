# Native general constraints vs manual linearization.
#
# Energy procurement: buy 100 units from two suppliers.
#   - Supplier a has tiered pricing: 1/unit for the first 40, 3/unit beyond.
#   - Supplier b costs 2/unit but needs a contract (fixed fee 25); with a
#     contract you must take at least 20; without one you may take nothing.
#   - Balance rule: the two purchase amounts may differ by at most 60.
#
# The model is stated twice. The manual version uses the classic hand tricks,
# each with a caveat: tier splitting (only valid because the price curve is
# convex and minimized), a big-M for the contract logic (needs a correct M),
# and the two-row expansion of |a - b| <= 60 (only valid for <=). The native
# version just says what it means: pwl, if:, abs. Capable backends (Gurobi,
# CPLEX) solve it natively; HiGHS rejects it, strictly and loudly.
#
# Run with: mix run examples/native_constructs.exs

import Optex.DSL

# ---- manual linearization (solvable by every backend) ----

manual =
  model do
    variable tier1, lb: 0.0, ub: 40.0
    variable tier2, lb: 0.0
    variable buy_b, lb: 0.0
    variable contract, type: :bin

    # tier split: buy_a = tier1 + tier2, cost 1 and 3 per unit
    constraint(tier1 + tier2 + buy_b == 100, name: :demand)
    # contract logic by big-M (M = 100 because demand caps buy_b)
    constraint(buy_b - 100 * contract <= 0, name: :needs_contract)
    constraint(buy_b - 20 * contract >= 0, name: :min_take)
    # |buy_a - buy_b| <= 60 expands to two rows only because the sense is <=
    constraint(tier1 + tier2 - buy_b <= 60, name: :balance_hi)
    constraint(buy_b - tier1 - tier2 <= 60, name: :balance_lo)

    objective tier1 + 3 * tier2 + 2 * buy_b + 25 * contract
  end

{:ok, manual_sol} = Optex.optimize(manual, solver: Optex.Solver.HiGHS)

IO.puts("manual linearization (HiGHS): #{manual_sol.status}, cost #{manual_sol.objective}")

IO.puts(
  "  buy_a = #{manual_sol.values[:tier1] + manual_sol.values[:tier2]}, " <>
    "buy_b = #{manual_sol.values[:buy_b]}, contract = #{round(manual_sol.values[:contract])}\n"
)

# ---- native constructs (capable backends only) ----

native =
  model do
    variable buy_a, lb: 0.0
    variable buy_b, lb: 0.0
    variable contract, type: :bin

    variable cost_a = pwl(buy_a, [{0, 0}, {40, 40}, {100, 220}])
    variable imbalance = abs(buy_a - buy_b)

    constraint(buy_a + buy_b == 100, name: :demand)
    constraint(buy_b <= 0, if: {contract, 0}, name: :needs_contract)
    constraint(buy_b >= 20, if: contract, name: :min_take)
    constraint(imbalance <= 60, name: :balance)

    objective cost_a + 2 * buy_b + 25 * contract
  end

# HiGHS has no native general constraints and says so instead of pretending
{:error, reason} = Optex.optimize(native, solver: Optex.Solver.HiGHS)
IO.puts("native model on HiGHS: #{inspect(reason)}\n")

capable =
  Enum.filter([Optex.Solver.Gurobi, Optex.Solver.CPLEX], fn backend ->
    backend.available?()
  end)

if capable == [] do
  IO.puts("no capable backend compiled; the manual result above is the answer")
else
  for backend <- capable do
    {:ok, sol} = Optex.optimize(native, solver: backend)

    IO.puts("native constructs (#{inspect(backend)}): #{sol.status}, cost #{sol.objective}")

    IO.puts(
      "  buy_a = #{sol.values[:buy_a]}, buy_b = #{sol.values[:buy_b]}, " <>
        "imbalance = #{sol.values[:imbalance]}, contract = #{round(sol.values[:contract])}"
    )
  end

  IO.puts("\nboth formulations agree: the native one just says what it means.")
end

# Expected: cost 185.0 at buy_a = 40 (exactly the cheap tier), buy_b = 60,
# contract = 1, imbalance = 20. Skipping the contract forces buy_a = 100,
# which costs 220 in tier pricing alone and violates the balance rule anyway.
