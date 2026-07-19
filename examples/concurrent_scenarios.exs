# Concurrency the BEAM way: one immutable model per scenario, solved in
# parallel with Task.async_stream.
#
# An Optex.Model is plain immutable data. Building variants and handing
# them to other processes needs no locks, no connection pool, no solver
# handle to guard: each optimize/2 call is self-contained and runs its NIF
# on a dirty scheduler, so concurrent solves use real cores without
# blocking the BEAM. That makes the everyday pattern below one line of
# Task.async_stream: sweep a parameter (here, demand scenarios), solve
# everything at once, reduce the results.
#
# Run with: mix run examples/concurrent_scenarios.exs

import Optex.DSL

plants = [:tijuana, :monterrey]
markets = [:cdmx, :gdl, :mty]
cap = %{tijuana: 140.0, monterrey: 160.0}
base_demand = %{cdmx: 90.0, gdl: 60.0, mty: 70.0}

cost = %{
  {:tijuana, :cdmx} => 12.0,
  {:tijuana, :gdl} => 9.0,
  {:tijuana, :mty} => 14.0,
  {:monterrey, :cdmx} => 8.0,
  {:monterrey, :gdl} => 10.0,
  {:monterrey, :mty} => 3.0
}

# an ordinary function from scenario to model; the DSL works fine inside
build = fn factor ->
  demand = Map.new(base_demand, fn {mk, d} -> {mk, d * factor} end)

  model do
    variable ship[{p, mk}], p <- plants, mk <- markets, lb: 0.0

    constraint(sum(ship[{p, mk}], mk <- markets) <= cap[p], p <- plants, name: {:cap, p})
    constraint(sum(ship[{p, mk}], p <- plants) == demand[mk], mk <- markets, name: {:dem, mk})

    objective sum(cost[{p, mk}] * ship[{p, mk}], p <- plants, mk <- markets)
  end
end

# demand from a mild year to a strong one; total capacity is 300
scenarios = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3]

# one process per scenario, as many at a time as there are cores;
# threads: 1 keeps each solver single-threaded so the parallelism budget
# is spent across scenarios instead of inside one solve
results =
  scenarios
  |> Task.async_stream(
    fn factor ->
      {:ok, sol} = Optex.optimize(build.(factor), threads: 1)
      {factor, sol}
    end,
    max_concurrency: System.schedulers_online(),
    ordered: true,
    timeout: :infinity
  )
  |> Enum.map(fn {:ok, result} -> result end)

IO.puts("demand   status    cost      marginal cost at mty")

for {factor, sol} <- results do
  IO.puts(
    "x#{factor}     #{sol.status}   #{Float.round(sol.objective, 1)}" <>
      String.duplicate(" ", 10 - String.length("#{Float.round(sol.objective, 1)}")) <>
      "#{Float.round(sol.duals[{:dem, :mty}], 2)}"
  )
end

{worst_factor, worst} = Enum.max_by(results, fn {_factor, sol} -> sol.objective end)

IO.puts("\nworst case is x#{worst_factor} at cost #{Float.round(worst.objective, 1)}")

# Expected: every scenario solves to optimal, cost grows with demand, and
# the dual of the mty demand row (the marginal cost of one more unit
# there) jumps once monterrey's cheap capacity is used up. The same shape
# scales to hundreds of scenarios and to MIPs. The timeout: :infinity
# above is load-bearing: Task.async_stream's default of 5 seconds kills
# solver tasks (the first solve also pays the one-time NIF load). Prefer
# a real deadline via `time_limit:` per solve, which returns the best
# solution found instead of killing the process.
