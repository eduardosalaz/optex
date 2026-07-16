defmodule Optex.TransformTest do
  use ExUnit.Case, async: true

  alias Optex.{Aff, Model, SolverInput, Transform}

  # x0 cont lb 0, x1 int [1, 4], x2 bin; three constraints, objective x0 + 5 x2
  defp reference_model do
    m = Model.new()
    {x0, m} = Model.add_variable(m, name: :x0)
    {x1, m} = Model.add_variable(m, name: :x1, type: :int, lb: 1.0, ub: 4.0)
    {x2, m} = Model.add_variable(m, name: :x2, type: :bin)

    m =
      m
      |> Model.add_constraint(%Aff{terms: %{x0.id => 2.0, x1.id => 3.0}}, :le, 10.0)
      |> Model.add_constraint(%Aff{terms: %{x1.id => 1.0, x2.id => -1.0}}, :ge, 1.0)
      |> Model.add_constraint(%Aff{terms: %{x0.id => 1.0, x2.id => 1.0}}, :eq, 2.0)

    Model.set_objective(m, %Aff{terms: %{x0.id => 1.0, x2.id => 5.0}}, :min)
  end

  test "round-trip: every array's contents and lengths are exact" do
    si = Transform.to_solver_input(reference_model())

    assert %SolverInput{num_vars: 3, num_cons: 3, sense: :min} = si

    assert si.obj == [1.0, 0.0, 5.0]
    assert si.col_lb == [0.0, 1.0, 0.0]
    assert si.col_ub == [:infinity, 4.0, 1.0]
    assert si.col_type == [:cont, :int, :bin]

    # CSC: col0 -> rows 0, 2; col1 -> rows 0, 1; col2 -> rows 1, 2
    assert si.col_start == [0, 2, 4, 6]
    assert si.row_index == [0, 2, 0, 1, 1, 2]
    assert si.values == [2.0, 1.0, 3.0, 1.0, -1.0, 1.0]

    assert length(si.col_start) == si.num_vars + 1
    assert List.last(si.col_start) == length(si.values)
    assert length(si.row_index) == length(si.values)

    assert si.row_lb == [:neg_infinity, 1.0, 2.0]
    assert si.row_ub == [10.0, :infinity, 2.0]
  end

  test "column slices match the intended entries" do
    si = Transform.to_solver_input(reference_model())

    for {col, expected} <- %{
          0 => [{0, 2.0}, {2, 1.0}],
          1 => [{0, 3.0}, {1, 1.0}],
          2 => [{1, -1.0}, {2, 1.0}]
        } do
      lo = Enum.at(si.col_start, col)
      hi = Enum.at(si.col_start, col + 1)

      slice =
        Enum.zip(
          Enum.slice(si.row_index, lo, hi - lo),
          Enum.slice(si.values, lo, hi - lo)
        )

      assert slice == expected, "column #{col} mismatch"
    end
  end

  test "a variable referenced twice in one constraint yields one summed entry" do
    m = Model.new()
    {x, m} = Model.add_variable(m)
    # x + x builds through Aff.add, summing into a single map cell
    aff = Aff.add(Aff.from_var(x), Aff.from_var(x))
    m = Model.add_constraint(m, aff, :le, 4.0)

    si = Transform.to_solver_input(m)

    assert si.col_start == [0, 1]
    assert si.row_index == [0]
    assert si.values == [2.0]
  end

  test "sense to range mapping for all three senses" do
    m = Model.new()
    {x, m} = Model.add_variable(m)
    aff = Aff.from_var(x)

    m =
      m
      |> Model.add_constraint(aff, :le, 7.0)
      |> Model.add_constraint(aff, :ge, -2.0)
      |> Model.add_constraint(aff, :eq, 3.0)

    si = Transform.to_solver_input(m)

    assert si.row_lb == [:neg_infinity, -2.0, 3.0]
    assert si.row_ub == [7.0, :infinity, 3.0]
  end

  test "empty model transforms without error" do
    si = Transform.to_solver_input(Model.new())

    assert %SolverInput{num_vars: 0, num_cons: 0} = si
    assert si.obj == []
    assert si.col_start == [0]
    assert si.row_index == []
    assert si.values == []
    assert si.row_lb == []
    assert si.row_ub == []
  end

  test "a variable in no constraint produces an empty column" do
    m = Model.new()
    {x, m} = Model.add_variable(m)
    {_unused, m} = Model.add_variable(m)
    m = Model.add_constraint(m, Aff.from_var(x), :le, 1.0)

    si = Transform.to_solver_input(m)

    assert si.num_vars == 2
    assert si.col_start == [0, 1, 1]
  end
end
