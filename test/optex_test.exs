defmodule OptexTest do
  use ExUnit.Case

  # Milestone 0 toolchain check: confirms the compiled Rust NIF artifact loads
  # and runs. Remove once Milestone 4 lands the real solve NIF.
  test "trivial NIF bridges Rust and Elixir" do
    assert Optex.Solver.HiGHS.Native.add(2, 3) == 5
    assert Optex.Solver.HiGHS.Native.add(-10, 4) == -6
  end
end
