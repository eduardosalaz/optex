# Binary knapsack: indexed binary variables and data-driven coefficients.
#
# Pick a subset of items maximizing total value without exceeding the weight
# capacity. Coefficients come from plain maps; the DSL handles runtime
# numbers on either side of *.
#
# Run with: mix run examples/knapsack.exs

import Optex.DSL

items = [:book, :laptop, :camera, :phone, :tripod]
weight = %{book: 4, laptop: 8, camera: 5, phone: 2, tripod: 6}
value = %{book: 10, laptop: 30, camera: 25, phone: 15, tripod: 20}
capacity = 15

m =
  model sense: :max do
    variable take[i], i <- items, type: :bin

    constraint sum(weight[i] * take[i], i <- items) <= capacity

    objective sum(value[i] * take[i], i <- items)
  end

{:ok, sol} = Optex.optimize(m)

chosen = Enum.filter(items, fn i -> sol.values[{:take, i}] > 0.5 end)
total_weight = chosen |> Enum.map(&weight[&1]) |> Enum.sum()

IO.puts("status:       #{sol.status}")
IO.puts("total value:  #{sol.objective}")
IO.puts("total weight: #{total_weight} / #{capacity}")
IO.puts("take:         #{Enum.map_join(chosen, ", ", &Atom.to_string/1)}")

# Expected: value 70.0 taking laptop, camera, phone (weight 15).
