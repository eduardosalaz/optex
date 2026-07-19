# A solver as an OTP service: GenServer + Task + cancel token.
#
# The one rule: never call optimize/2 inside handle_call and return the
# result directly. The solve itself is safe anywhere (the NIF runs on a
# dirty scheduler and never blocks the BEAM), but it would occupy the
# server process for the whole solve, so every other caller queues behind
# it and cancel requests sit unread in the mailbox. The OTP shape is: the
# server starts the solve in a Task, keeps its mailbox free, and replies
# later with GenServer.reply. Callers still see a plain synchronous
# GenServer.call; the server multiplexes any number of solves; and because
# the mailbox stays responsive, cancellation works mid-solve.
#
# Run with: mix run examples/solver_server.exs

defmodule SolverServer do
  use GenServer

  # -- client --

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, opts)

  @doc "Synchronous for the caller; the server itself never blocks."
  def solve(server, model, opts \\ []) do
    GenServer.call(server, {:solve, model, opts}, :infinity)
  end

  def cancel_all(server), do: GenServer.cast(server, :cancel_all)

  def in_flight(server), do: GenServer.call(server, :in_flight)

  # -- server --

  @impl true
  def init(:ok) do
    # a crashing solve should reply {:error, _}, not kill the service
    Process.flag(:trap_exit, true)
    {:ok, %{jobs: %{}}}
  end

  @impl true
  def handle_call({:solve, model, opts}, from, state) do
    token = Optex.Solver.HiGHS.cancel_token()
    task = Task.async(fn -> Optex.optimize(model, [cancel: token] ++ opts) end)
    {:noreply, put_in(state.jobs[task.ref], %{from: from, token: token})}
  end

  def handle_call(:in_flight, _from, state), do: {:reply, map_size(state.jobs), state}

  @impl true
  def handle_cast(:cancel_all, state) do
    for {_ref, %{token: token}} <- state.jobs, do: Optex.Solver.HiGHS.cancel(token)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.jobs, ref) do
    Process.demonitor(ref, [:flush])
    {job, state} = pop_in(state.jobs[ref])
    GenServer.reply(job.from, result)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.jobs, ref) do
    {job, state} = pop_in(state.jobs[ref])
    GenServer.reply(job.from, {:error, {:solve_crashed, reason}})
    {:noreply, state}
  end

  # the trapped :EXIT of a completed (or crashed) task; the ref clauses
  # above already did the bookkeeping
  def handle_info(_msg, state), do: {:noreply, state}
end

import Optex.DSL

# a model family with a knob: small factors solve instantly, the large one
# branches long enough to catch a cancel
build = fn n ->
  items = 1..n
  w1 = Map.new(items, fn i -> {i, rem(i * 7919, 199) + 11} end)
  w2 = Map.new(items, fn i -> {i, rem(i * 6733, 211) + 7} end)
  w3 = Map.new(items, fn i -> {i, rem(i * 104_729, 223) + 13} end)
  value = Map.new(items, fn i -> {i, rem(i * 31_337, 197) + 19} end)
  cap1 = w1 |> Map.values() |> Enum.sum() |> div(3)
  cap2 = w2 |> Map.values() |> Enum.sum() |> div(3)
  cap3 = w3 |> Map.values() |> Enum.sum() |> div(3)

  model sense: :max do
    variable take[i], i <- items, type: :bin
    constraint sum(w1[i] * take[i], i <- items) <= cap1
    constraint sum(w2[i] * take[i], i <- items) <= cap2
    constraint sum(w3[i] * take[i], i <- items) <= cap3
    objective sum(value[i] * take[i], i <- items)
  end
end

{:ok, server} = SolverServer.start_link()

# 1) plain synchronous use, one caller
{:ok, sol} = SolverServer.solve(server, build.(40))
IO.puts("one caller:  #{sol.status}, objective #{sol.objective}")

# 2) three callers at once; the server multiplexes, nobody queues
callers =
  for n <- [30, 40, 50] do
    Task.async(fn -> SolverServer.solve(server, build.(n), threads: 1) end)
  end

for {:ok, sol} <- Task.await_many(callers) do
  IO.puts("concurrent:  #{sol.status}, objective #{sol.objective}")
end

# 3) cancellation from outside, mid-solve
hard =
  Task.async(fn ->
    SolverServer.solve(server, build.(120), threads: 1, mip_gap: 1.0e-9)
  end)

Process.sleep(100)

# the mailbox is free, so the service answers queries mid-solve
IO.puts("in flight while solving: #{SolverServer.in_flight(server)}")
SolverServer.cancel_all(server)
{:ok, stopped} = Task.await(hard, 60_000)
IO.puts("cancelled:   #{stopped.status}, best found #{stopped.objective}")

# Expected: the first four solves print optimal; the hard one usually
# prints :interrupted with the best incumbent found (on a very fast
# machine it may finish first and print optimal, the graceful degenerate
# case). Production notes: use Task.Supervisor.async_nolink instead of
# Task.async under a real supervision tree, and pick the cancel token
# module to match the `solver:` you pass (here HiGHS, the default).
