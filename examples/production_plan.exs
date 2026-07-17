# Multi-period production planning: the programmatic API.
#
# This model could also be written in the DSL (constraint families take
# trailing generators); it is built with the core Optex.Model API instead to
# show that path. Constraints and the objective take {name, coefficient}
# terms lists that resolve against variable names, so everything after
# variable creation pipes. Optex.optimize/2 works the same either way, and
# values come back keyed by the names given at creation.
#
# Model: integer production make[t] up to a per-period capacity, inventory
# inv[t] carried between periods, demand met every period.
#   inv[t] == inv[t-1] + make[t] - demand[t]      (inv[0] is 0)
# Minimize production cost (5 per unit) plus holding cost (1 per unit-period).
#
# Run with: mix run examples/production_plan.exs

alias Optex.Model

periods = 1..4
demand = %{1 => 10, 2 => 60, 3 => 40, 4 => 50}
capacity = 45
production_cost = 5.0
holding_cost = 1.0

# variable creation threads {var, model}; the vars themselves are not needed
# afterwards because constraints reference them by name
m =
  Enum.reduce(periods, Model.new(), fn t, m ->
    {_make, m} = Model.add_variable(m, name: {:make, t}, type: :int, lb: 0.0, ub: capacity * 1.0)
    {_inv, m} = Model.add_variable(m, name: {:inv, t}, lb: 0.0)
    m
  end)

# inventory balance per period: inv[t] - inv[t-1] - make[t] == -demand[t]
balance_terms = fn
  1 -> [{{:inv, 1}, 1.0}, {{:make, 1}, -1.0}]
  t -> [{{:inv, t}, 1.0}, {{:inv, t - 1}, -1.0}, {{:make, t}, -1.0}]
end

objective =
  Enum.flat_map(periods, fn t ->
    [{{:make, t}, production_cost}, {{:inv, t}, holding_cost}]
  end)

m =
  periods
  |> Enum.reduce(m, fn t, m ->
    Model.add_constraint(m, balance_terms.(t), :eq, -demand[t] * 1.0)
  end)
  |> Model.set_objective(objective, :min)

{:ok, sol} = Optex.optimize(m)

IO.puts("status:     #{sol.status}")
IO.puts("total cost: #{sol.objective}")
IO.puts("")
IO.puts("period  demand  make  end inventory")

for t <- periods do
  make_t = round(sol.values[{:make, t}])
  inv_t = round(sol.values[{:inv, t}])

  IO.puts(
    String.pad_leading("#{t}", 6) <>
      String.pad_leading("#{demand[t]}", 8) <>
      String.pad_leading("#{make_t}", 6) <> String.pad_leading("#{inv_t}", 15)
  )
end

# Expected: cost 820.0. Capacity 45 cannot cover the demand spikes of 60 and
# 50, so period 1 pre-builds 15 units and period 3 pre-builds 5.
