defmodule Optex.ModelTest do
  use ExUnit.Case, async: true

  alias Optex.{Aff, Model, Var}

  describe "add_variable/2" do
    test "assigns contiguous ids from 0 and registers each var" do
      m = Model.new()
      {v0, m} = Model.add_variable(m)
      {v1, m} = Model.add_variable(m, name: :x)
      {v2, m} = Model.add_variable(m, type: :int, lb: 1.0, ub: 5.0)

      assert v0.id == 0
      assert v1.id == 1
      assert v2.id == 2
      assert m.var_counter == 3
      assert Map.keys(m.vars) |> Enum.sort() == [0, 1, 2]
      assert m.vars[1].name == :x
      assert m.vars[2] == %Var{id: 2, type: :int, lb: 1.0, ub: 5.0}
    end

    test "defaults are cont type, lb 0.0, ub :infinity" do
      {v, _m} = Model.add_variable(Model.new())

      assert v.type == :cont
      assert v.lb == 0.0
      assert v.ub == :infinity
    end

    test "binary variable creation forces lb 0.0 and ub 1.0" do
      {v, _m} = Model.add_variable(Model.new(), type: :bin, lb: -5.0, ub: 99.0)

      assert v.type == :bin
      assert v.lb == 0.0
      assert v.ub == 1.0
    end

    test "variable ids are independent of constraint ids" do
      m = Model.new()
      {v0, m} = Model.add_variable(m)
      m = Model.add_constraint(m, Aff.from_var(v0), :le, 1.0)
      {v1, _m} = Model.add_variable(m)

      # the constraint did not consume a variable id
      assert v1.id == 1
    end
  end

  describe "add_constraint/4" do
    test "moves a nonzero affine constant to the rhs with correct sign" do
      # 2x + 5 <= 10 must store as 2x <= 5
      m = Model.new()
      {x, m} = Model.add_variable(m)
      aff = %Aff{terms: %{x.id => 2.0}, constant: 5.0}
      m = Model.add_constraint(m, aff, :le, 10.0)

      [c] = m.constraints
      assert c.aff == %Aff{terms: %{x.id => 2.0}, constant: 0.0}
      assert c.rhs == 5.0
      assert c.sense == :le
    end

    test "negative constant increases the rhs" do
      m = Model.new()
      {x, m} = Model.add_variable(m)
      aff = %Aff{terms: %{x.id => 1.0}, constant: -3.0}
      m = Model.add_constraint(m, aff, :ge, 2.0)

      [c] = m.constraints
      assert c.rhs == 5.0
    end

    test "assigns contiguous constraint ids and stores reversed" do
      m = Model.new()
      {x, m} = Model.add_variable(m)
      aff = Aff.from_var(x)

      m =
        m
        |> Model.add_constraint(aff, :le, 1.0)
        |> Model.add_constraint(aff, :ge, 0.0)
        |> Model.add_constraint(aff, :eq, 0.5)

      assert Enum.map(m.constraints, & &1.id) == [2, 1, 0]
      assert m.con_counter == 3
    end

    test "rejects an invalid sense" do
      m = Model.new()
      {x, m} = Model.add_variable(m)

      # apply/3 keeps the compile-time type checker from flagging the bad atom;
      # the point is the runtime guard.
      assert_raise FunctionClauseError, fn ->
        apply(Model, :add_constraint, [m, Aff.from_var(x), :lt, 1.0])
      end
    end
  end

  describe "name-based terms lists" do
    defp named_model do
      m = Model.new()
      {_x, m} = Model.add_variable(m, name: :x)
      {_y1, m} = Model.add_variable(m, name: {:y, 1})
      {unnamed, m} = Model.add_variable(m)
      {m, unnamed}
    end

    test "add_variable maintains the name index, skipping unnamed vars" do
      {m, _unnamed} = named_model()

      assert m.name_index == %{:x => 0, {:y, 1} => 1}
    end

    test "duplicate names resolve last-wins" do
      m = Model.new()
      {_a, m} = Model.add_variable(m, name: :x)
      {_b, m} = Model.add_variable(m, name: :x)

      assert m.name_index == %{x: 1}
    end

    test "add_constraint resolves names and Var structs, coercing coefs to floats" do
      {m, unnamed} = named_model()
      m = Model.add_constraint(m, [{:x, 2}, {{:y, 1}, -1.0}, {unnamed, 3}], :le, 10.0)

      [c] = m.constraints
      assert c.aff.terms == %{0 => 2.0, 1 => -1.0, 2 => 3.0}
      assert {c.sense, c.rhs} == {:le, 10.0}
    end

    test "add_constraint stores a name from opts in both forms" do
      {m, _} = named_model()
      m = Model.add_constraint(m, [{:x, 1.0}], :le, 5.0, name: :cap)
      m = Model.add_constraint(m, Aff.from_var(%Optex.Var{id: 0}), :ge, 0.0, name: {:lo, 1})

      [c2, c1] = m.constraints
      assert c1.name == :cap
      assert c2.name == {:lo, 1}
    end

    test "duplicate references in one terms list sum" do
      {m, _} = named_model()
      m = Model.add_constraint(m, [{:x, 2.0}, {:x, 3.0}], :eq, 4.0)

      [c] = m.constraints
      assert c.aff.terms == %{0 => 5.0}
    end

    test "set_objective accepts a terms list" do
      {m, _} = named_model()
      m = Model.set_objective(m, [{:x, 1.0}, {{:y, 1}, 2.5}], :max)

      assert m.objective.terms == %{0 => 1.0, 1 => 2.5}
      assert m.sense == :max
    end

    test "an unknown name raises ArgumentError naming the known names" do
      {m, _} = named_model()

      assert_raise ArgumentError, ~r/unknown variable name :z/, fn ->
        Model.add_constraint(m, [{:z, 1.0}], :le, 1.0)
      end
    end

    test "a name-built model solves end to end" do
      m = Model.new()
      {_x, m} = Model.add_variable(m, name: :x, lb: 0.0)
      {_y, m} = Model.add_variable(m, name: :y, lb: 0.0)

      m =
        m
        |> Model.add_constraint([{:x, 1.0}, {:y, 2.0}], :le, 4.0)
        |> Model.add_constraint([{:x, 3.0}, {:y, 1.0}], :le, 6.0)
        |> Model.set_objective([{:x, 1.0}, {:y, 1.0}], :max)

      assert {:ok, sol} = Optex.optimize(m)
      assert_in_delta sol.objective, 2.8, 1.0e-6
      assert_in_delta sol.values[:x], 1.6, 1.0e-6
    end
  end

  describe "set_objective/3" do
    test "sets objective and sense" do
      m = Model.new()
      {x, m} = Model.add_variable(m)
      obj = Aff.from_var(x)
      m = Model.set_objective(m, obj, :max)

      assert m.objective == obj
      assert m.sense == :max
    end

    test "rejects an invalid sense" do
      assert_raise FunctionClauseError, fn ->
        apply(Model, :set_objective, [Model.new(), %Aff{}, :maximize])
      end
    end
  end
end
