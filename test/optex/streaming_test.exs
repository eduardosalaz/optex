defmodule Optex.StreamingTest do
  # Progress and incumbent streaming: option validation and the HiGHS
  # end-to-end path run everywhere; per-backend shape tests are tagged.
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{Solution, Solver}

  # a knapsack that actually branches, so MIP callbacks fire
  defp branching_mip(n) do
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

  defp drain(progress \\ [], incumbents \\ []) do
    receive do
      {:optex_progress, map} -> drain([map | progress], incumbents)
      {:optex_incumbent, map} -> drain(progress, [map | incumbents])
    after
      0 -> {Enum.reverse(progress), Enum.reverse(incumbents)}
    end
  end

  defp assert_streams!(backend, opts \\ []) do
    {:ok, %Solution{} = sol} =
      Optex.optimize(
        branching_mip(120),
        [
          solver: backend,
          progress: self(),
          progress_every: 0,
          incumbents: self(),
          threads: 1,
          mip_gap: 1.0e-9
        ] ++ opts
      )

    assert sol.status == :optimal
    {progress, incumbents} = drain()

    assert progress != [], "no progress events (#{inspect(backend)})"
    assert incumbents != [], "no incumbents (#{inspect(backend)})"

    # every progress message carries exactly the shared shape
    for map <- progress do
      assert %{best_obj: _, best_bound: _, gap: _, nodes: _, time: _} = map
      assert map_size(map) == 5
    end

    # the final incumbent is the returned solution, keyed by variable name
    last = List.last(incumbents)
    assert_in_delta last.objective, sol.objective, 1.0e-6
    assert Map.has_key?(last.values, {:take, 1})
    assert map_size(last.values) == 120

    {progress, incumbents}
  end

  test "HiGHS streams shaped progress and name-keyed incumbents" do
    {progress, _incumbents} = assert_streams!(Solver.HiGHS)

    # HiGHS reports node counts and running time directly
    assert Enum.any?(progress, fn p -> is_integer(p.nodes) end)
    assert Enum.any?(progress, fn p -> is_float(p.time) end)
  end

  test "an LP solve with streams requested emits nothing and errors nothing" do
    m =
      model sense: :max do
        variable x, lb: 0.0, ub: 1.0
        constraint x <= 1
        objective x
      end

    {:ok, %Solution{status: :optimal}} =
      Optex.optimize(m, progress: self(), incumbents: self())

    assert drain() == {[], []}
  end

  test "streaming options are validated pre-NIF" do
    m =
      model do
        variable x, lb: 0.0
        constraint x >= 1
        objective x
      end

    assert {:error, {:invalid_option_value, :progress, :nope}} =
             Optex.optimize(m, progress: :nope)

    assert {:error, {:invalid_option_value, :progress_every, -1}} =
             Optex.optimize(m, progress: self(), progress_every: -1)
  end

  test "a pre-NIF rejection with streams requested still returns the error" do
    m =
      model do
        variable b, type: :bin
        variable x, lb: 0.0
        constraint(x <= 1, if: b)
        objective x
      end

    assert {:error, {:unsupported, :indicator, Solver.HiGHS}} =
             Optex.optimize(m, incumbents: self(), progress: self())

    assert drain() == {[], []}
  end

  @tag :gurobi
  test "Gurobi streams both; nodes and time decode as numbers" do
    {progress, _} = assert_streams!(Solver.Gurobi)
    assert Enum.any?(progress, fn p -> is_integer(p.nodes) end)
  end

  @tag :cplex
  test "CPLEX streams both from its multithreaded generic callback" do
    {progress, _} = assert_streams!(Solver.CPLEX)
    assert Enum.any?(progress, fn p -> is_integer(p.nodes) end)
  end

  @tag :copt
  test "COPT streams both; nodes stay nil (not exposed by its callback)" do
    {progress, _} = assert_streams!(Solver.COPT)
    assert Enum.all?(progress, fn p -> p.nodes == nil end)
  end

  @tag :gurobi
  test "a progress receiver can cancel the solve (the stopping-rule pattern)" do
    token = Solver.Gurobi.cancel_token()
    parent = self()

    solve =
      Task.async(fn ->
        Optex.optimize(
          branching_mip(200),
          solver: Solver.Gurobi,
          progress: parent,
          progress_every: 0,
          cancel: token,
          threads: 1,
          mip_gap: 1.0e-9
        )
      end)

    # the user-side stopping rule: cancel on the first sign of progress
    receive do
      {:optex_progress, _} -> :ok = Solver.Gurobi.cancel(token)
    after
      10_000 -> flunk("no progress event arrived")
    end

    # interrupted on any realistic machine; :optimal only if the whole
    # solve outran the cancellation round trip (the interrupt semantics
    # themselves are pinned by the dedicated cancel tests)
    {:ok, %Solution{} = sol} = Task.await(solve, 30_000)
    assert sol.status in [:interrupted, :optimal]
    drain()
  end
end
