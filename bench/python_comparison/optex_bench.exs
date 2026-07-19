# Optex leg of the Python-binding comparison. Mirrors models.py exactly
# (same integer remainder formulas, so coefficients are bit-identical).
#
# Run from the repo root: mix run bench/python_comparison/optex_bench.exs
#
# Writes results/optex_<backend>.json next to the Python results. Fields
# match harness.py: three build timings (median reported), transform time
# (model to CSC wire, informational; the Python bindings do this work
# inside their build calls), solve wall time, solver-reported time, RSS
# deltas via tasklist (OS-level, coarse, same as psutil on the Python
# side).

defmodule OptexBench do
  import Optex.DSL

  # ---- data, mirroring models.py ----

  def transport_data do
    plants = Enum.to_list(1..300)
    markets = Enum.to_list(1..400)

    cost =
      for p <- plants, m <- markets, into: %{} do
        {{p, m}, rem(p * 31 + m * 17, 40) + 1.0}
      end

    supply = Map.new(plants, &{&1, 170.0})
    demand = Map.new(markets, &{&1, rem(&1 * 7, 50) + 100.0})
    {plants, markets, cost, supply, demand}
  end

  def assign_data do
    idx = Enum.to_list(1..250)

    cost =
      for i <- idx, j <- idx, into: %{} do
        {{i, j}, rem(i * 53 + j * 71 + i * j, 100) + 1.0}
      end

    {idx, cost}
  end

  def portfolio_data do
    idx = Enum.to_list(1..300)
    f = Map.new(idx, &{&1, rem(&1 * 17, 23) / 23})
    g = Map.new(idx, &{&1, rem(&1 * 29, 31) / 31})
    d = Map.new(idx, &{&1, rem(&1 * 13, 11) / 11 + 0.5})
    mu = Map.new(idx, &{&1, rem(&1 * 7, 13) + 1.0})

    q =
      for i <- idx, j <- idx, j >= i, into: %{} do
        v = 4.0 * f[i] * f[j] + 2.0 * g[i] * g[j]
        v = if i == j, do: v + d[i], else: v * 2.0
        {{i, j}, v}
      end

    {idx, q, mu, 8.0}
  end

  def knapsack_data do
    items = Enum.to_list(1..120)
    w1 = Map.new(items, &{&1, rem(&1 * 7919, 199) + 11})
    w2 = Map.new(items, &{&1, rem(&1 * 6733, 211) + 7})
    w3 = Map.new(items, &{&1, rem(&1 * 104_729, 223) + 13})
    value = Map.new(items, &{&1, rem(&1 * 31_337, 197) + 19})
    cap1 = w1 |> Map.values() |> Enum.sum() |> div(3)
    cap2 = w2 |> Map.values() |> Enum.sum() |> div(3)
    cap3 = w3 |> Map.values() |> Enum.sum() |> div(3)
    {items, w1, w2, w3, value, cap1, cap2, cap3}
  end

  # ---- builds ----

  def build_transport({plants, markets, cost, supply, demand}) do
    model do
      variable x[{p, mk}], p <- plants, mk <- markets, lb: 0.0

      constraint sum(x[{p, mk}], mk <- markets) <= supply[p], p <- plants
      constraint sum(x[{p, mk}], p <- plants) == demand[mk], mk <- markets

      objective sum(cost[{p, mk}] * x[{p, mk}], p <- plants, mk <- markets)
    end
  end

  def build_assign({idx, cost}) do
    model do
      variable x[{i, j}], i <- idx, j <- idx, type: :bin

      constraint sum(x[{i, j}], j <- idx) == 1.0, i <- idx
      constraint sum(x[{i, j}], i <- idx) == 1.0, j <- idx

      objective sum(cost[{i, j}] * x[{i, j}], i <- idx, j <- idx)
    end
  end

  def build_portfolio({idx, q, mu, target}) do
    model do
      variable w[a], a <- idx, lb: 0.0

      constraint sum(w[a], a <- idx) == 1.0
      constraint sum(mu[a] * w[a], a <- idx) >= target

      objective sum(q[{a, b}] * w[a] * w[b], a <- idx, b <- idx, b >= a)
    end
  end

  def build_knapsack({items, w1, w2, w3, value, cap1, cap2, cap3}) do
    model sense: :max do
      variable take[i], i <- items, type: :bin

      constraint sum(w1[i] * take[i], i <- items) <= cap1
      constraint sum(w2[i] * take[i], i <- items) <= cap2
      constraint sum(w3[i] * take[i], i <- items) <= cap3

      objective sum(value[i] * take[i], i <- items)
    end
  end

  # ---- measurement ----

  def rss_bytes do
    :erlang.garbage_collect()
    {out, 0} = System.cmd("tasklist", ["/FI", "PID eq #{System.pid()}", "/FO", "CSV", "/NH"])

    kb =
      out
      |> String.split("\",\"")
      |> List.last()
      |> String.replace(~r/[^0-9]/, "")
      |> String.to_integer()

    kb * 1024
  end

  def run_case(results, binding, backend, name, build_fun, extra_opts) do
    # memory protocol mirrors harness.py: sample around the FIRST build
    # (clean baseline, no prior garbage pending release to the OS) and
    # the solve; the extra timed builds and the standalone transform
    # measurement happen afterwards and only feed timing columns
    rss_before_build = rss_bytes()
    {b1, m} = :timer.tc(build_fun)
    rss_after_build = rss_bytes()

    opts = [solver: backend, threads: 1] ++ extra_opts
    {s_us, {:ok, sol}} = :timer.tc(fn -> Optex.optimize(m, opts) end)
    rss_after_solve = rss_bytes()

    {b2, _} = :timer.tc(build_fun)
    {b3, _} = :timer.tc(build_fun)
    build_s = Enum.map([b1, b2, b3], &Float.round(&1 / 1.0e6, 4))

    # optimize/2 performs its own transform internally either way
    {t_us, _wire} = :timer.tc(Optex.Transform, :to_solver_input, [m])

    row = %{
      "binding" => binding,
      "model" => name,
      "build_s" => build_s,
      "build_median_s" => Enum.at(Enum.sort(build_s), 1),
      "transform_s" => Float.round(t_us / 1.0e6, 4),
      "solve_wall_s" => Float.round(s_us / 1.0e6, 4),
      "solver_time_s" => Float.round(sol.stats.solve_time * 1.0, 4),
      "objective" => sol.objective,
      "status" => to_string(sol.status),
      "build_rss_mb" => Float.round((rss_after_build - rss_before_build) / 1_048_576, 1),
      "solve_rss_mb" => Float.round((rss_after_solve - rss_after_build) / 1_048_576, 1)
    }

    IO.puts(
      "#{String.pad_trailing(binding, 12)} #{String.pad_trailing(name, 10)} " <>
        "build #{row["build_median_s"]}s  solve #{row["solve_wall_s"]}s  " <>
        "obj #{row["objective"]}  #{row["status"]}"
    )

    [row | results]
  end

  # ---- minimal JSON encoding (flat rows: numbers, strings, number lists) ----

  def to_json(rows) do
    encoded =
      Enum.map_join(rows, ",\n", fn row ->
        fields =
          Enum.map_join(row, ", ", fn {k, v} -> "\"#{k}\": #{encode_value(v)}" end)

        "  {#{fields}}"
      end)

    "[\n" <> encoded <> "\n]\n"
  end

  defp encode_value(v) when is_binary(v), do: "\"#{v}\""
  defp encode_value(v) when is_list(v), do: "[" <> Enum.map_join(v, ", ", &encode_value/1) <> "]"
  defp encode_value(v) when is_float(v), do: :erlang.float_to_binary(v, [:short])
  defp encode_value(v) when is_integer(v), do: Integer.to_string(v)

  def run do
    backends =
      [
        {"optex_highs", Optex.Solver.HiGHS},
        {"optex_gurobi", Optex.Solver.Gurobi},
        {"optex_cplex", Optex.Solver.CPLEX},
        {"optex_copt", Optex.Solver.COPT}
      ]
      |> Enum.filter(fn {_name, mod} ->
        not function_exported?(mod, :available?, 0) or mod.available?()
      end)

    mip = [mip_gap: 1.0e-9]

    cases = [
      {"transport", transport_data(), &build_transport/1, []},
      {"assign", assign_data(), &build_assign/1, mip},
      {"portfolio", portfolio_data(), &build_portfolio/1, []},
      {"knapsack", knapsack_data(), &build_knapsack/1, mip}
    ]

    out_dir = Path.join(Path.dirname(__ENV__.file), "results")
    File.mkdir_p!(out_dir)

    for {binding, backend} <- backends do
      rows =
        Enum.reduce(cases, [], fn {name, data, build, extra}, acc ->
          run_case(acc, binding, backend, name, fn -> build.(data) end, extra)
        end)

      path = Path.join(out_dir, "#{binding}.json")
      File.write!(path, to_json(Enum.reverse(rows)))
      IO.puts("wrote #{path}")
    end
  end
end

OptexBench.run()
