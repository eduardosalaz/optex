# Transportation problem: ship from plants to markets at minimum cost.
#
# Supply rows (<=) per plant and demand rows (==) per market are families
# generated from data, so this uses the programmatic API with {name, coef}
# terms lists. Route variables are tuple-named {:ship, {plant, market}}.
#
# Run with: mix run examples/transportation.exs

alias Optex.Model

plants = [:p1, :p2]
markets = [:m1, :m2, :m3]
supply = %{p1: 60, p2: 50}
demand = %{m1: 30, m2: 40, m3: 40}

cost = %{
  {:p1, :m1} => 4.0,
  {:p1, :m2} => 6.5,
  {:p1, :m3} => 9.0,
  {:p2, :m1} => 5.0,
  {:p2, :m2} => 4.0,
  {:p2, :m3} => 7.0
}

routes = for p <- plants, mk <- markets, do: {p, mk}

m =
  Enum.reduce(routes, Model.new(), fn route, m ->
    {_v, m} = Model.add_variable(m, name: {:ship, route}, lb: 0.0)
    m
  end)

m =
  plants
  |> Enum.reduce(m, fn p, m ->
    terms = for mk <- markets, do: {{:ship, {p, mk}}, 1.0}
    Model.add_constraint(m, terms, :le, supply[p] * 1.0)
  end)
  |> then(fn m ->
    Enum.reduce(markets, m, fn mk, m ->
      terms = for p <- plants, do: {{:ship, {p, mk}}, 1.0}
      Model.add_constraint(m, terms, :eq, demand[mk] * 1.0)
    end)
  end)
  |> Model.set_objective(Enum.map(routes, fn route -> {{:ship, route}, cost[route]} end), :min)

{:ok, sol} = Optex.optimize(m)

IO.puts("status:     #{sol.status}")
IO.puts("total cost: #{sol.objective}")

for {p, mk} = route <- routes, sol.values[{:ship, route}] > 1.0e-6 do
  IO.puts("  #{p} -> #{mk}: #{round(sol.values[{:ship, route}])} units")
end

# Expected: cost 620.0 shipping p1 -> m1 30, p1 -> m3 30, p2 -> m2 40,
# p2 -> m3 10. Total supply equals total demand, so supply rows go tight.
