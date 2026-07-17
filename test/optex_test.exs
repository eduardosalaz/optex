defmodule OptexTest do
  use ExUnit.Case, async: true

  import Optex.DSL

  doctest Optex

  test "end to end: DSL block through optimize, values read by user-facing key" do
    m =
      model sense: :max do
        variable x, lb: 0.0
        variable y[i], i <- [1, 2], lb: 0.0, ub: 3.0
        variable pick, type: :bin

        constraint x + y[1] + y[2] <= 8
        constraint x - pick <= 4
        objective x + 2 * y[1] + 1.5 * y[2] + 5 * pick
      end

    assert {:ok, sol} = Optex.optimize(m)
    assert sol.status == :optimal

    # unique optimum: pick = 1, y1 = y2 = 3, x = 8 - 6 = 2
    # -> 2 + 6 + 4.5 + 5 = 17.5
    assert_in_delta sol.objective, 17.5, 1.0e-6
    assert_in_delta sol.values[:x], 2.0, 1.0e-6
    assert_in_delta sol.values[{:y, 1}], 3.0, 1.0e-6
    assert_in_delta sol.values[{:y, 2}], 3.0, 1.0e-6
    assert_in_delta sol.values[:pick], 1.0, 1.0e-9
  end

  test "explicit solver: option is honored" do
    m =
      model do
        variable x, lb: 1.0
        objective x
      end

    assert {:ok, sol} = Optex.optimize(m, solver: Optex.Solver.HiGHS)
    assert_in_delta sol.objective, 1.0, 1.0e-6
  end

  test "solver options pass through optimize; reduced costs are name-keyed" do
    m =
      model sense: :max do
        variable x, lb: 0.0, ub: 5.0
        variable idle, lb: 0.0
        constraint x + idle <= 10
        objective 2 * x - idle
      end

    assert {:ok, sol} = Optex.optimize(m, time_limit: 60.0, threads: 1)
    assert sol.status == :optimal

    # x is at its own upper bound (reduced cost 2), the row is slack
    # (dual 0), idle is nonbasic with reduced cost -1
    assert_in_delta sol.values[:x], 5.0, 1.0e-6
    assert_in_delta sol.reduced_costs[:x], 2.0, 1.0e-6
    assert_in_delta sol.reduced_costs[:idle], -1.0, 1.0e-6
    assert_in_delta sol.duals[0], 0.0, 1.0e-6

    assert {:error, {:unknown_option, :bogus}} = Optex.optimize(m, bogus: 1)
  end

  test "a hand-built model without names keys values by id" do
    m = Optex.Model.new()
    {x, m} = Optex.Model.add_variable(m, lb: 2.0)
    m = Optex.Model.set_objective(m, Optex.Aff.from_var(x), :min)

    assert {:ok, sol} = Optex.optimize(m)
    assert_in_delta sol.values[x.id], 2.0, 1.0e-6
  end

  test "duals come back keyed by constraint name, id fallback for unnamed rows" do
    m =
      model sense: :max do
        variable x, lb: 0.0
        variable y, lb: 0.0
        constraint(x + 2 * y <= 4, name: :carpentry)
        constraint 3 * x + y <= 6
        objective x + y
      end

    assert {:ok, sol} = Optex.optimize(m)
    assert sol.status == :optimal
    assert_in_delta sol.duals[:carpentry], 0.4, 1.0e-6
    assert_in_delta sol.duals[1], 0.2, 1.0e-6
    refute Map.has_key?(sol.duals, 0)
  end

  test "solver errors propagate as {:error, reason}" do
    defmodule FailingSolver do
      @behaviour Optex.Solver
      @impl true
      def solve(_input, _opts), do: {:error, :boom}
    end

    m =
      model do
        variable x
        objective x
      end

    assert {:error, :boom} = Optex.optimize(m, solver: FailingSolver)
  end
end
