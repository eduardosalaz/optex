# Callbacks, the BEAM way: a user-defined stopping rule.
#
# Other modeling stacks make you register solver callbacks: C function
# pointers running on solver threads, with reentrancy rules per vendor.
# Optex composes three plain pieces instead: the solve runs in a Task, the
# progress stream arrives as ordinary messages, and the cancel token
# interrupts from outside. Your "callback" is a receive loop in your own
# process: watch, decide, cancel. Works identically on every backend.
#
# The rule here: proving optimality is expensive, and often a solution
# within 2% of the bound is all the business question needs. Solve once to
# proven optimality for reference, then re-solve and stop the moment the
# gap dips under 2%.
#
# Run with: mix run examples/stopping_rule.exs

import Optex.DSL

items = 1..120
w1 = Map.new(items, fn i -> {i, rem(i * 7919, 199) + 11} end)
w2 = Map.new(items, fn i -> {i, rem(i * 6733, 211) + 7} end)
w3 = Map.new(items, fn i -> {i, rem(i * 104_729, 223) + 13} end)
value = Map.new(items, fn i -> {i, rem(i * 31_337, 197) + 19} end)
cap1 = w1 |> Map.values() |> Enum.sum() |> div(3)
cap2 = w2 |> Map.values() |> Enum.sum() |> div(3)
cap3 = w3 |> Map.values() |> Enum.sum() |> div(3)

m =
  model sense: :max do
    variable take[i], i <- items, type: :bin
    constraint sum(w1[i] * take[i], i <- items) <= cap1
    constraint sum(w2[i] * take[i], i <- items) <= cap2
    constraint sum(w3[i] * take[i], i <- items) <= cap3
    objective sum(value[i] * take[i], i <- items)
  end

# ---- reference: run to proven optimality ----

{:ok, exact} = Optex.optimize(m, threads: 1, mip_gap: 1.0e-9)

IO.puts(
  "proven optimum: #{exact.status}, objective #{exact.objective} " <>
    "in #{Float.round(exact.stats.solve_time, 3)}s"
)

# ---- the stopping rule: cancel once the gap is under 2% ----

token = Optex.Solver.HiGHS.cancel_token()
watcher = self()

solve =
  Task.async(fn ->
    Optex.optimize(m,
      solver: Optex.Solver.HiGHS,
      progress: watcher,
      progress_every: 0,
      cancel: token,
      threads: 1,
      mip_gap: 1.0e-9
    )
  end)

# the "callback": an ordinary receive loop in this process
watch = fn watch ->
  receive do
    {:optex_progress, %{best_obj: obj, best_bound: bound}}
    when is_float(obj) and is_float(bound) and obj > 0.0 ->
      gap = abs(bound - obj) / obj

      if gap < 0.02 do
        IO.puts("rule fired: gap #{Float.round(gap * 100, 2)}% < 2%, cancelling")
        Optex.Solver.HiGHS.cancel(token)
      else
        watch.(watch)
      end

    {:optex_progress, _early} ->
      watch.(watch)
  after
    30_000 -> IO.puts("no progress events; letting the solve finish")
  end
end

watch.(watch)
{:ok, early} = Task.await(solve, 60_000)

# drain any progress that was already in flight when we cancelled
flush = fn flush ->
  receive do
    {:optex_progress, _} -> flush.(flush)
  after
    0 -> :ok
  end
end

flush.(flush)

quality = early.objective && Float.round(early.objective / exact.objective * 100, 2)

IO.puts(
  "stopped early:  #{early.status}, objective #{early.objective} " <>
    "in #{Float.round(early.stats.solve_time, 3)}s (#{quality}% of the optimum)"
)

# Expected: the reference run prints optimal; the second run usually
# returns :interrupted with an objective within 2% of it, faster. On a
# machine where the solve outruns the rule entirely, the second run also
# finishes :optimal, which is the graceful degenerate case of the pattern.
# Swap solver: (and the token module) to run the same loop on Gurobi,
# CPLEX, or COPT; stats.mip_gap carries the achieved gap either way.
