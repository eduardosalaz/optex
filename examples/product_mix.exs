# Product mix: the classic starter LP.
#
# A workshop builds tables and chairs. Each table needs 2 carpentry hours and
# 1 finishing hour; each chair needs 1 carpentry hour and 2 finishing hours.
# There are 40 carpentry hours and 50 finishing hours available. Tables sell
# for 30, chairs for 20. How many of each maximizes revenue?
#
# Run with: mix run examples/product_mix.exs

import Optex.DSL

m =
  model sense: :max do
    variable tables, lb: 0.0
    variable chairs, lb: 0.0

    constraint 2 * tables + chairs <= 40
    constraint tables + 2 * chairs <= 50

    objective 30 * tables + 20 * chairs
  end

{:ok, sol} = Optex.optimize(m)

IO.puts("status:    #{sol.status}")
IO.puts("revenue:   #{sol.objective}")
IO.puts("tables:    #{sol.values[:tables]}")
IO.puts("chairs:    #{sol.values[:chairs]}")

# Expected: revenue 700.0 at 10 tables and 20 chairs.
