# Scale benchmarks across every problem type. Run with:
#
#     mix run bench/scale.exs             # small + medium sizes
#     BENCH_LARGE=1 mix run bench/scale.exs   # adds ~100k-variable cases
#
# For each {type, size}: model build and transform are timed (best of two),
# and the solve is timed on EVERY capable available backend (HiGHS, Gurobi,
# CPLEX, COPT), one line per backend, with the marshalling overhead split
# out (wall minus solver-reported time; valid for any terminal status, so
# MIP families run under a time limit). The emitters and pretty printer are
# timed on the large LP to check the linearity claims at ~200k nnz. Record
# findings in bench/BASELINE.md.

defmodule Bench.Scale do
  @moduledoc false
  import Optex.DSL

  # transportation LP: p x p grid -> p^2 vars, 2p rows, 2p^2 nnz
  def lp(p) do
    plants = Enum.to_list(1..p)
    supply = Map.new(plants, fn i -> {i, p * 2.0} end)

    model do
      variable ship[{i, j}], i <- plants, j <- plants, lb: 0.0
      constraint sum(ship[{i, j}], j <- plants) <= supply[i], i <- plants
      constraint sum(ship[{i, j}], i <- plants) >= p * 1.0, j <- plants
      objective sum((rem(i + j, 7) + 1) * ship[{i, j}], i <- plants, j <- plants)
    end
  end

  # capacitated facility MILP: f sites, c customers -> f*(c+1) vars
  def milp(f, c) do
    sites = Enum.to_list(1..f)
    customers = Enum.to_list(1..c)

    model do
      variable open[s], s <- sites, type: :bin
      variable ship[{s, k}], s <- sites, k <- customers, lb: 0.0
      constraint sum(ship[{s, k}], s <- sites) == 1.0, k <- customers
      constraint sum(ship[{s, k}], k <- customers) - c * open[s] <= 0, s <- sites
      objective sum(10 * open[s], s <- sites) +
                  sum((rem(s + k, 5) + 1) * ship[{s, k}], s <- sites, k <- customers)
    end
  end

  # separable-plus-tridiagonal QP: n vars, 2n-1 qterms, one budget row
  def qp(n) do
    vars = Enum.to_list(1..n)

    model do
      variable x[i], i <- vars, lb: 0.0
      constraint sum(x[i], i <- vars) >= n / 2
      objective sum(x[i] * x[i], i <- vars) +
                  sum(0.5 * x[i] * x[i + 1], i <- Enum.to_list(1..(n - 1))) -
                  sum(x[i], i <- vars)
    end
  end

  # qp over integer lots (commercial backends)
  def miqp(n) do
    vars = Enum.to_list(1..n)

    model do
      variable x[i], i <- vars, type: :int, lb: 0.0, ub: 10.0
      constraint sum(x[i], i <- vars) >= n * 1.0
      objective sum(x[i] * x[i], i <- vars) - sum(2 * x[i], i <- vars)
    end
  end

  # linear objective inside one big ball (commercial backends)
  def qcp(n) do
    vars = Enum.to_list(1..n)

    model sense: :max do
      variable x[i], i <- vars, lb: 0.0
      constraint sum(x[i] * x[i], i <- vars) <= n * 1.0
      objective sum(x[i], i <- vars)
    end
  end

  # fixed-charge pairs: n binaries gating n continuous vars, 2n indicators
  def indicator(n) do
    pairs = Enum.to_list(1..n)

    model do
      variable open[i], i <- pairs, type: :bin
      variable y[i], i <- pairs, lb: 0.0
      constraint y[i] <= 5, i <- pairs, if: open[i]
      constraint y[i] <= 0, i <- pairs, if: {open[i], 0}
      constraint sum(y[i], i <- pairs) >= n * 2.5
      objective sum(open[i] + y[i], i <- pairs)
    end
  end

  # n absolute deviations from fixed targets
  def abs_devs(n) do
    items = Enum.to_list(1..n)

    model do
      variable x[i], i <- items, lb: :neg_infinity
      variable d[i] = abs(x[i] - rem(i, 13)), i <- items
      constraint x[i] == rem(i, 7), i <- items
      objective sum(d[i], i <- items)
    end
  end

  # n piecewise-linear costs over fixed inputs
  def pwl_costs(n) do
    items = Enum.to_list(1..n)
    curve = [{0, 0}, {5, 5}, {10, 15}]

    model do
      variable x[i], i <- items, lb: 0.0
      variable c[i] = pwl(x[i], curve), i <- items
      constraint x[i] == rem(i, 11), i <- items
      objective sum(c[i], i <- items)
    end
  end

  # n native maxes against fixed floors (Gurobi-only capability)
  def minmax(n) do
    items = Enum.to_list(1..n)

    model do
      variable x[i], i <- items, lb: 0.0
      variable m[i] = max(x[i], rem(i, 9)), i <- items
      constraint x[i] == rem(i, 7), i <- items
      objective sum(m[i], i <- items)
    end
  end
end

defmodule Bench.ScaleRunner do
  @moduledoc false

  def best_of(times, fun) do
    1..times |> Enum.map(fn _ -> :timer.tc(fun) end) |> Enum.min_by(&elem(&1, 0))
  end

  def ms(us), do: Float.round(us / 1000, 1)

  # every backend that is compiled AND can solve this input; the solve is
  # timed once per backend so the sweep doubles as a cross-solver comparison
  def capable_backends(si) do
    required = Optex.SolverInput.required_capabilities(si)
    mip? = Enum.any?(si.col_type, &(&1 in [:int, :bin]))

    [Optex.Solver.HiGHS, Optex.Solver.Gurobi, Optex.Solver.CPLEX, Optex.Solver.COPT]
    |> Enum.filter(fn backend ->
      available? = backend == Optex.Solver.HiGHS or backend.available?()

      available? and required -- backend.capabilities() == [] and
        not (backend == Optex.Solver.HiGHS and si.q_vals != [] and mip?)
    end)
  end

  def row(label, build_fn) do
    {build_us, model} = best_of(2, build_fn)
    {tf_us, si} = best_of(2, fn -> Optex.Transform.to_solver_input(model) end)

    :io.format("~-16s ~8w vars ~9w nnz  build ~8.1f ms  transform ~8.1f ms~n", [
      label,
      si.num_vars,
      length(si.values),
      build_us / 1000,
      tf_us / 1000
    ])

    case capable_backends(si) do
      [] ->
        IO.puts("    (no capable backend compiled)")

      backends ->
        for backend <- backends do
          name = backend |> inspect() |> String.replace("Optex.Solver.", "")

          case :timer.tc(fn -> backend.solve(si, threads: 1, time_limit: 60.0) end) do
            {wall_us, {:ok, sol}} ->
              overhead = wall_us / 1000 - sol.stats.solve_time * 1000

              :io.format("    ~-8s ~10.1f ms wall / ~8.1f ms ovh  (~s)~n", [
                name,
                wall_us / 1000,
                overhead,
                sol.status
              ])

            {_wall_us, {:error, reason}} ->
              IO.puts("    #{String.pad_trailing(name, 8)} error: #{inspect(reason)}")
          end
        end
    end

    {model, si}
  end
end

alias Bench.{Scale, ScaleRunner}

large? = System.get_env("BENCH_LARGE") == "1"

IO.puts("== scale sweep across problem types (best of 2; solve includes 60s limit) ==\n")

ScaleRunner.row("lp 32x32", fn -> Scale.lp(32) end)
ScaleRunner.row("lp 100x100", fn -> Scale.lp(100) end)

{lp_large, lp_large_si} =
  if large?, do: ScaleRunner.row("lp 316x316", fn -> Scale.lp(316) end), else: {nil, nil}

ScaleRunner.row("milp 8x127", fn -> Scale.milp(8, 127) end)
ScaleRunner.row("milp 25x400", fn -> Scale.milp(25, 400) end)
if large?, do: ScaleRunner.row("milp 80x1250", fn -> Scale.milp(80, 1250) end)

ScaleRunner.row("qp 1k", fn -> Scale.qp(1_000) end)
ScaleRunner.row("qp 10k", fn -> Scale.qp(10_000) end)
if large?, do: ScaleRunner.row("qp 100k", fn -> Scale.qp(100_000) end)

ScaleRunner.row("miqp 1k", fn -> Scale.miqp(1_000) end)
ScaleRunner.row("miqp 5k", fn -> Scale.miqp(5_000) end)

ScaleRunner.row("qcp 1k", fn -> Scale.qcp(1_000) end)
ScaleRunner.row("qcp 10k", fn -> Scale.qcp(10_000) end)

ScaleRunner.row("indicator 500", fn -> Scale.indicator(500) end)
ScaleRunner.row("indicator 5k", fn -> Scale.indicator(5_000) end)
if large?, do: ScaleRunner.row("indicator 50k", fn -> Scale.indicator(50_000) end)

ScaleRunner.row("abs 500", fn -> Scale.abs_devs(500) end)
ScaleRunner.row("abs 5k", fn -> Scale.abs_devs(5_000) end)

ScaleRunner.row("pwl 500", fn -> Scale.pwl_costs(500) end)
ScaleRunner.row("pwl 5k", fn -> Scale.pwl_costs(5_000) end)

ScaleRunner.row("minmax 500", fn -> Scale.minmax(500) end)
ScaleRunner.row("minmax 5k", fn -> Scale.minmax(5_000) end)

if large? do
  IO.puts("\n== emitters at ~200k nnz (large LP) ==\n")

  {us, _} = Bench.ScaleRunner.best_of(2, fn -> :erlang.iolist_size(Optex.MPS.emit(lp_large_si)) end)
  IO.puts("emit MPS:      #{ScaleRunner.ms(us)} ms")

  {us, _} = Bench.ScaleRunner.best_of(2, fn -> :erlang.iolist_size(Optex.LP.emit(lp_large)) end)
  IO.puts("emit LP:       #{ScaleRunner.ms(us)} ms")

  {us, _} = Bench.ScaleRunner.best_of(2, fn -> byte_size(Optex.Format.pretty(lp_large)) end)
  IO.puts("pretty print:  #{ScaleRunner.ms(us)} ms")
end
