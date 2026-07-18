# Watching a solve: progress and incumbent streaming.
#
# Long MIPs are opaque without feedback. optimize/2 takes `progress:` (a
# pid receiving throttled {:optex_progress, map} messages with best_obj,
# best_bound, gap, nodes, and time; nil where a backend lacks a field) and
# `incumbents:` (a pid receiving {:optex_incumbent, %{objective, values}}
# for every improving solution, values keyed by variable name). Both work
# on every backend. Combined with the cancel token, this is a user-defined
# stopping rule in plain Elixir: watch the stream, decide, cancel. No
# solver-side callback code, no user code on solver threads.
#
# Run with: mix run examples/progress.exs

import Optex.DSL

# a knapsack family that genuinely branches, so the MIP streams have
# something to say
items = 1..120
w1 = Map.new(items, fn i -> {i, rem(i * 7919, 199) + 11} end)
w2 = Map.new(items, fn i -> {i, rem(i * 6733, 211) + 7} end)
value = Map.new(items, fn i -> {i, rem(i * 31_337, 197) + 19} end)
cap1 = w1 |> Map.values() |> Enum.sum() |> div(3)
cap2 = w2 |> Map.values() |> Enum.sum() |> div(3)

m =
  model sense: :max do
    variable take[i], i <- items, type: :bin
    constraint sum(w1[i] * take[i], i <- items) <= cap1
    constraint sum(w2[i] * take[i], i <- items) <= cap2
    objective sum(value[i] * take[i], i <- items)
  end

# progress_every: 0 turns the throttle off so a short demo has output;
# real workloads keep the default 1000 ms
{:ok, sol} =
  Optex.optimize(m,
    progress: self(),
    progress_every: 0,
    incumbents: self(),
    threads: 1,
    mip_gap: 1.0e-9
  )

drain = fn drain, progress, incumbents ->
  receive do
    {:optex_progress, map} -> drain.(drain, [map | progress], incumbents)
    {:optex_incumbent, map} -> drain.(drain, progress, [map | incumbents])
  after
    0 -> {Enum.reverse(progress), Enum.reverse(incumbents)}
  end
end

{progress, incumbents} = drain.(drain, [], [])

IO.puts("solved: #{sol.status}, objective #{sol.objective}\n")

IO.puts("the incumbent trail (each improving solution as it was found):")

for inc <- incumbents do
  picked = Enum.count(inc.values, fn {_name, v} -> v > 0.5 end)
  IO.puts("  objective #{inc.objective} (#{picked} items)")
end

IO.puts("\n#{length(progress)} progress snapshots; the last three:")

for p <- Enum.take(progress, -3) do
  IO.puts(
    "  best #{inspect(p.best_obj)}  bound #{inspect(p.best_bound)}  " <>
      "nodes #{inspect(p.nodes)}  t #{inspect(p.time)}"
  )
end

# Expected: the incumbent objectives improve monotonically up to the final
# solution, and the last progress snapshot's best matches it. The same
# streams work on Gurobi, CPLEX, and COPT via solver:, and pairing
# progress: with a cancel token gives stop-when-good-enough logic in your
# own process.
