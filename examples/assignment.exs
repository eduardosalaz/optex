# Assignment problem: two-index variables with tuple keys.
#
# Assign each worker exactly one task and each task exactly one worker,
# minimizing total cost. Multi-index families are declared with an explicit
# tuple key (w[{i, j}]); one generator per index enumerates the combinations.
#
# Run with: mix run examples/assignment.exs

import Optex.DSL

workers = [:alice, :bob, :carol]
tasks = [:design, :code, :test]

cost = %{
  {:alice, :design} => 9,
  {:alice, :code} => 2,
  {:alice, :test} => 7,
  {:bob, :design} => 6,
  {:bob, :code} => 4,
  {:bob, :test} => 3,
  {:carol, :design} => 5,
  {:carol, :code} => 8,
  {:carol, :test} => 1
}

m =
  model sense: :min do
    variable assign[{w, t}], w <- workers, t <- tasks, type: :bin

    # each worker does exactly one task
    constraint sum(assign[{:alice, t}], t <- tasks) == 1
    constraint sum(assign[{:bob, t}], t <- tasks) == 1
    constraint sum(assign[{:carol, t}], t <- tasks) == 1

    # each task is done by exactly one worker
    constraint sum(assign[{w, :design}], w <- workers) == 1
    constraint sum(assign[{w, :code}], w <- workers) == 1
    constraint sum(assign[{w, :test}], w <- workers) == 1

    objective sum(cost[{w, t}] * assign[{w, t}], w <- workers, t <- tasks)
  end

{:ok, sol} = Optex.optimize(m)

IO.puts("status:     #{sol.status}")
IO.puts("total cost: #{sol.objective}")

for w <- workers, t <- tasks, sol.values[{:assign, {w, t}}] > 0.5 do
  IO.puts("#{w} -> #{t} (cost #{cost[{w, t}]})")
end

# Expected: cost 9.0 with alice -> code, bob -> design, carol -> test.
