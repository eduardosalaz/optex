defmodule Optex.PerfRegressionTest do
  # Guards against complexity regressions in the hot phases. Absolute-time
  # assertions are flaky across machines, so these assert SCALING: each
  # phase is timed (best of three) at two sizes ~10x apart, and the time
  # ratio must stay within a generous linear-with-slack envelope. A
  # quadratic regression shows up as ~100x at 10x size and fails
  # unmistakably (the MPS emitter bug fixed in bench/BASELINE.md was
  # exactly that shape). Full absolute numbers live in bench/.
  use ExUnit.Case, async: false

  import Optex.DSL

  @small 32
  @large 100
  # vars scale by (100/32)^2 ~ 9.77; allow log factors, allocator noise,
  # and CI jitter on top of linear
  @size_ratio 9.77
  @slack 3.5

  setup_all do
    small = transport(@small)
    large = transport(@large)

    %{
      small: small,
      large: large,
      small_si: Optex.Transform.to_solver_input(small),
      large_si: Optex.Transform.to_solver_input(large)
    }
  end

  defp transport(p) do
    plants = Enum.to_list(1..p)
    supply = Map.new(plants, fn i -> {i, p * 2.0} end)

    model do
      variable ship[{i, j}], i <- plants, j <- plants, lb: 0.0
      constraint(sum(ship[{i, j}], j <- plants) <= supply[i], i <- plants)
      constraint(sum(ship[{i, j}], i <- plants) >= p * 1.0, j <- plants)
      objective sum((rem(i + j, 7) + 1) * ship[{i, j}], i <- plants, j <- plants)
    end
  end

  defp best_of(n, fun) do
    1..n |> Enum.map(fn _ -> fun |> :timer.tc() |> elem(0) end) |> Enum.min()
  end

  defp assert_scales(label, small_fun, large_fun) do
    small_us = best_of(3, small_fun)
    large_us = best_of(3, large_fun)

    # floor the denominator so sub-millisecond small runs cannot inflate
    # the ratio with timer noise
    ratio = large_us / max(small_us, 500)
    limit = @size_ratio * @slack

    assert ratio <= limit,
           "#{label} scaled superlinearly: #{Float.round(small_us / 1000, 2)} ms -> " <>
             "#{Float.round(large_us / 1000, 2)} ms is #{Float.round(ratio, 1)}x for a " <>
             "#{@size_ratio}x size increase (limit #{Float.round(limit, 1)}x); " <>
             "profile against bench/BASELINE.md"
  end

  test "model build (DSL) scales linearly" do
    assert_scales("build", fn -> transport(@small) end, fn -> transport(@large) end)
  end

  test "transform scales linearly", %{small: s, large: l} do
    assert_scales(
      "transform",
      fn -> Optex.Transform.to_solver_input(s) end,
      fn -> Optex.Transform.to_solver_input(l) end
    )
  end

  test "MPS emit scales linearly", %{small_si: s, large_si: l} do
    assert_scales(
      "emit MPS",
      fn -> :erlang.iolist_size(Optex.MPS.emit(s)) end,
      fn -> :erlang.iolist_size(Optex.MPS.emit(l)) end
    )
  end

  test "LP emit scales linearly", %{small: s, large: l} do
    assert_scales(
      "emit LP",
      fn -> :erlang.iolist_size(Optex.LP.emit(s)) end,
      fn -> :erlang.iolist_size(Optex.LP.emit(l)) end
    )
  end

  test "pretty print scales linearly", %{small: s, large: l} do
    assert_scales(
      "pretty print",
      fn -> byte_size(Optex.Format.pretty(s)) end,
      fn -> byte_size(Optex.Format.pretty(l)) end
    )
  end
end
