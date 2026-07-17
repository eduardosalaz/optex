# Optex benchmark suite. Run with:
#
#     mix run bench/benchmarks.exs            # quick pass (default budgets)
#     BENCH_TIME=5 mix run bench/benchmarks.exs   # longer, steadier numbers
#
# Phases are measured separately so regressions localize: model build (DSL
# and programmatic), transform to CSC, the emitters, and the NIF marshalling
# overhead (solve wall time minus the solver's own reported time; HiGHS,
# threads: 1). Record results in bench/BASELINE.md when they change
# materially.

defmodule Bench.Models do
  @moduledoc false
  import Optex.DSL

  # transportation LP: p plants x mk markets -> p*mk vars, p+mk rows,
  # 2*p*mk nonzeros
  def transport_dsl(p, mk) do
    plants = Enum.to_list(1..p)
    markets = Enum.to_list(1..mk)
    supply = Map.new(plants, fn i -> {i, mk * 2.0} end)
    demand = Map.new(markets, fn j -> {j, p * 1.0} end)

    model do
      variable ship[{i, j}], i <- plants, j <- markets, lb: 0.0
      constraint sum(ship[{i, j}], j <- markets) <= supply[i], i <- plants, name: {:supply, i}
      constraint sum(ship[{i, j}], i <- plants) >= demand[j], j <- markets, name: {:demand, j}
      objective sum((rem(i + j, 7) + 1) * ship[{i, j}], i <- plants, j <- markets)
    end
  end

  # the same model through the programmatic terms-list API
  def transport_programmatic(p, mk) do
    alias Optex.Model

    plants = Enum.to_list(1..p)
    markets = Enum.to_list(1..mk)

    m =
      Enum.reduce(plants, Model.new(), fn i, m ->
        Enum.reduce(markets, m, fn j, m ->
          {_v, m} = Model.add_variable(m, name: {:ship, {i, j}}, lb: 0.0)
          m
        end)
      end)

    m =
      Enum.reduce(plants, m, fn i, m ->
        terms = for j <- markets, do: {{:ship, {i, j}}, 1.0}
        Model.add_constraint(m, terms, :le, mk * 2.0)
      end)

    m =
      Enum.reduce(markets, m, fn j, m ->
        terms = for i <- plants, do: {{:ship, {i, j}}, 1.0}
        Model.add_constraint(m, terms, :ge, p * 1.0)
      end)

    objective =
      for i <- plants, j <- markets, do: {{:ship, {i, j}}, rem(i + j, 7) + 1.0}

    Model.set_objective(m, objective, :min)
  end
end

time = String.to_integer(System.get_env("BENCH_TIME", "2"))
warmup = max(time / 4, 0.5)

sizes = [{10, 10}, {40, 40}, {100, 100}]

cases =
  Map.new(sizes, fn {p, mk} ->
    model = Bench.Models.transport_dsl(p, mk)
    si = Optex.Transform.to_solver_input(model)

    label = "#{p}x#{mk} (#{si.num_vars} vars, #{length(si.values)} nnz)"
    {label, %{p: p, mk: mk, model: model, si: si}}
  end)

IO.puts("== phase benchmarks (BENCH_TIME=#{time}s per job) ==\n")

Benchee.run(
  %{
    "build (DSL)" => fn %{p: p, mk: mk} -> Bench.Models.transport_dsl(p, mk) end,
    "build (programmatic)" => fn %{p: p, mk: mk} -> Bench.Models.transport_programmatic(p, mk) end,
    "transform" => fn %{model: m} -> Optex.Transform.to_solver_input(m) end,
    "emit MPS" => fn %{si: si} -> :erlang.iolist_size(Optex.MPS.emit(si)) end,
    "emit LP" => fn %{model: m} -> :erlang.iolist_size(Optex.LP.emit(m)) end,
    "pretty print" => fn %{model: m} -> byte_size(Optex.Format.pretty(m)) end
  },
  inputs: cases,
  time: time,
  warmup: warmup,
  memory_time: time / 2,
  print: [configuration: false]
)

IO.puts("\n== NIF marshalling overhead (solve wall minus solver-reported time, HiGHS) ==")
IO.puts("   (input pre-transformed; overhead = prepare + NIF encode/decode)\n")

for {label, %{si: si}} <- Enum.sort(cases) do
  runs =
    for _ <- 1..3 do
      {wall_us, {:ok, sol}} =
        :timer.tc(fn -> Optex.Solver.HiGHS.solve(si, threads: 1) end)

      wall_ms = wall_us / 1000
      solver_ms = sol.stats.solve_time * 1000
      {wall_ms, solver_ms, wall_ms - solver_ms}
    end

  {wall, solver, overhead} =
    runs
    |> Enum.min_by(fn {_, _, o} -> o end)

  :io.format("~-32s wall ~10.1f ms   solver ~10.1f ms   overhead ~10.1f ms~n", [
    label,
    wall,
    solver,
    overhead
  ])
end
