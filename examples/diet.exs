# Diet problem: minimum-cost nutrition, the classic LP.
#
# Choose servings of each food to meet nutrient minimums at minimum cost.
# Shows >= constraints, a single-variable side constraint (per-index bounds
# cannot go in the family declaration, so beans get an explicit row), and
# data-driven coefficients from maps.
#
# Run with: mix run examples/diet.exs

import Optex.DSL

foods = [:rice, :beans, :spinach]
cost = %{rice: 1.0, beans: 2.0, spinach: 3.0}
protein = %{rice: 2, beans: 5, spinach: 1}
iron = %{rice: 1, beans: 3, spinach: 4}

m =
  model sense: :min do
    variable buy[f], f <- foods, lb: 0.0

    constraint sum(protein[f] * buy[f], f <- foods) >= 20
    constraint sum(iron[f] * buy[f], f <- foods) >= 15

    # nobody eats more than 3 servings of beans
    constraint buy[:beans] <= 3

    objective sum(cost[f] * buy[f], f <- foods)
  end

{:ok, sol} = Optex.optimize(m)

IO.puts("status:     #{sol.status}")
IO.puts("total cost: #{sol.objective}")

for f <- foods do
  IO.puts("  #{f}: #{Float.round(sol.values[{:buy, f}], 4)} servings")
end

# Expected: cost 11.0 with rice 2, beans 3 (at its cap), spinach 1; both
# nutrient constraints bind exactly (protein 20, iron 15).
