# The data stack round trip: Explorer in, Nx in the middle, Optex to
# optimize, Explorer back out.
#
# Monthly asset returns live in an Explorer DataFrame (in real life:
# DF.from_csv/from_parquet/from_query). Nx turns them into a covariance
# matrix. Optex sweeps a Markowitz efficient frontier: one min-variance QP
# per target return, all solved concurrently with Task.async_stream, and
# the frontier lands back in a DataFrame. Plain Elixir data structures are
# the seams: Explorer columns -> lists -> Nx tensor -> a coefficient map ->
# model -> solution values -> DataFrame columns.
#
# Run OUTSIDE the repo's Mix project (Mix.install refuses to run inside
# one), with plain elixir, not mix run:
#
#     elixir examples/standalone/explorer_nx_frontier.exs
#
# First run downloads deps, including Optex's precompiled HiGHS NIF: no
# Rust toolchain needed. The code lives in a module because a script's
# top level is compiled before Mix.install runs: `import Optex.DSL` can
# only appear inside a module (or a Livebook cell), never at the top of
# a Mix.install script.

Mix.install([
  {:explorer, "~> 0.10"},
  {:nx, "~> 0.9"},
  {:optex, "~> 0.1.1"}
])

defmodule Frontier do
  import Optex.DSL

  alias Explorer.DataFrame, as: DF
  alias Explorer.Series

  def run do
    # ---- 1. the data, as a DataFrame ----

    # monthly returns IN PERCENT, deliberately: fractional returns give
    # covariances around 1e-6, and coefficients that small are numerically
    # hostile to any QP solver (HiGHS crawls and may stop at a poor point).
    # If a tiny QP is inexplicably slow, rescale your units first.
    returns =
      DF.new(%{
        "tech" => [6.2, -3.1, 4.5, 8.8, -5.2, 7.1, 2.4, -1.8, 9.5, -4.1, 5.8, 3.3],
        "energy" => [1.8, 4.2, -2.5, 1.1, 4.9, -0.8, 3.1, 2.2, -1.5, 3.8, 0.5, 2.7],
        "health" => [2.1, 0.8, 1.9, -1.2, 2.5, 1.4, -0.6, 2.8, 1.1, 1.6, -0.9, 2.2],
        "bonds" => [0.4, 0.6, 0.3, 0.5, 0.2, 0.7, 0.4, 0.3, 0.6, 0.5, 0.4, 0.5]
      })

    assets = DF.names(returns)
    IO.inspect(returns, label: "monthly returns")

    mu = Map.new(assets, fn a -> {a, Series.mean(returns[a])} end)

    # ---- 2. the covariance matrix, with Nx ----

    x = Nx.tensor(Enum.map(assets, fn a -> Series.to_list(returns[a]) end)) |> Nx.transpose()
    n = elem(Nx.shape(x), 0)
    centered = Nx.subtract(x, Nx.mean(x, axes: [0]))
    sigma = Nx.divide(Nx.dot(Nx.transpose(centered), centered), n - 1)

    cov =
      for {row, i} <- Enum.with_index(Nx.to_list(sigma)),
          {v, j} <- Enum.with_index(row),
          into: %{} do
        {{Enum.at(assets, i), Enum.at(assets, j)}, v}
      end

    # ---- 3. the frontier: one QP per target return, solved concurrently ----

    lo = mu |> Map.values() |> Enum.min()
    hi = mu |> Map.values() |> Enum.max()
    targets = Enum.map(0..7, fn k -> lo + (hi - lo) * k / 7 end)

    frontier =
      targets
      |> Task.async_stream(
        fn target ->
          m =
            model do
              variable w[a], a <- assets, lb: 0.0
              constraint(sum(w[a], a <- assets) == 1.0, name: :fully_invested)
              constraint(sum(mu[a] * w[a], a <- assets) >= target, name: :return_target)
              objective sum(cov[{a, b}] * w[a] * w[b], a <- assets, b <- assets)
            end

          {:ok, sol} = Optex.optimize(m, threads: 1)
          {target, sol}
        end,
        max_concurrency: System.schedulers_online(),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    statuses = frontier |> Enum.map(fn {_t, sol} -> sol.status end) |> Enum.uniq()
    IO.puts("\nall #{length(frontier)} solves: #{Enum.join(statuses, ", ")}")

    # ---- 4. back into a DataFrame ----

    columns =
      %{
        "target_return" => Enum.map(frontier, fn {t, _} -> Float.round(t, 4) end),
        "volatility" =>
          Enum.map(frontier, fn {_, sol} -> Float.round(:math.sqrt(sol.objective), 4) end)
      }
      |> Map.merge(
        Map.new(assets, fn a ->
          {a, Enum.map(frontier, fn {_, sol} -> Float.round(sol.values[{:w, a}], 3) end)}
        end)
      )

    IO.inspect(DF.new(columns), label: "efficient frontier")
  end
end

Frontier.run()

# Expected: every solve prints optimal; volatility rises monotonically
# with the target return; low targets sit almost entirely in bonds and the
# top of the frontier is 100% tech (the highest-mean asset). From here it
# is one DF.to_csv/2 to a file or one Kino.DataTable.new/1 to a Livebook
# cell. Two hard-won notes baked in above: returns are in percent because
# fraction-scale covariances stall QP solvers, and Task.async_stream
# carries timeout: :infinity because its 5-second default kills solver
# tasks (the first solve also pays the one-time NIF load).
