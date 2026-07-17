# Capacitated facility location: fixed-charge MILP with linking constraints.
#
# Decide which sites to open (binary, fixed cost) and how to serve each
# customer's demand from open sites (continuous shipments). The linking row
# per site
#   sum of shipments from s  <=  capacity[s] * open[s]
# forces shipments to zero unless the site pays its fixed cost. This is the
# canonical mixed-binary pattern most real MILPs are built from.
#
# Run with: mix run examples/facility_location.exs

alias Optex.Model

sites = [:a, :b, :c]
customers = [:c1, :c2, :c3, :c4]
fixed = %{a: 100.0, b: 80.0, c: 120.0}
capacity = %{a: 80, b: 60, c: 100}
demand = %{c1: 30, c2: 25, c3: 35, c4: 20}

ship_cost = %{
  {:a, :c1} => 2.0,
  {:a, :c2} => 4.0,
  {:a, :c3} => 5.0,
  {:a, :c4} => 3.0,
  {:b, :c1} => 6.0,
  {:b, :c2} => 3.0,
  {:b, :c3} => 2.0,
  {:b, :c4} => 4.0,
  {:c, :c1} => 3.0,
  {:c, :c2} => 5.0,
  {:c, :c3} => 4.0,
  {:c, :c4} => 2.0
}

lanes = for s <- sites, cu <- customers, do: {s, cu}

m =
  Enum.reduce(sites, Model.new(), fn s, m ->
    {_v, m} = Model.add_variable(m, name: {:open, s}, type: :bin)
    m
  end)

m =
  Enum.reduce(lanes, m, fn lane, m ->
    {_v, m} = Model.add_variable(m, name: {:ship, lane}, lb: 0.0)
    m
  end)

# demand rows: every customer fully served
m =
  Enum.reduce(customers, m, fn cu, m ->
    terms = for s <- sites, do: {{:ship, {s, cu}}, 1.0}
    Model.add_constraint(m, terms, :eq, demand[cu] * 1.0)
  end)

# linking rows: shipments only from open sites, up to capacity
m =
  Enum.reduce(sites, m, fn s, m ->
    terms =
      [{{:open, s}, -capacity[s] * 1.0} | for(cu <- customers, do: {{:ship, {s, cu}}, 1.0})]

    Model.add_constraint(m, terms, :le, 0.0)
  end)

objective =
  Enum.map(sites, fn s -> {{:open, s}, fixed[s]} end) ++
    Enum.map(lanes, fn lane -> {{:ship, lane}, ship_cost[lane]} end)

m = Model.set_objective(m, objective, :min)

{:ok, sol} = Optex.optimize(m)

IO.puts("status:     #{sol.status}")
IO.puts("total cost: #{sol.objective}")

for s <- sites, sol.values[{:open, s}] > 0.5 do
  load =
    customers
    |> Enum.map(fn cu -> sol.values[{:ship, {s, cu}}] end)
    |> Enum.sum()
    |> round()

  IO.puts("  open #{s} (load #{load}/#{capacity[s]})")

  for cu <- customers, sol.values[{:ship, {s, cu}}] > 1.0e-6 do
    IO.puts("    -> #{cu}: #{round(sol.values[{:ship, {s, cu}}])} units")
  end
end

# Expected: cost 445.0 opening a and b. Site a serves c1 and c4, site b
# serves c2 and c3 at exactly its 60-unit capacity; site c stays closed.
