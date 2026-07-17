defmodule Optex.DSLTest do
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{Aff, Model, Var}

  defp constraints_in_order(%Model{constraints: cs}), do: Enum.reverse(cs)

  test "scalar variable produces a %Var{} and registers it" do
    m =
      model do
        variable(x, lb: 1.0, ub: 4.0)
        objective(x)
      end

    assert %Model{} = m
    assert m.var_counter == 1
    assert %Var{id: 0, name: :x, lb: 1.0, ub: 4.0, type: :cont} = m.vars[0]
  end

  test "indexed variable with a single index binds a map keyed by the index" do
    m =
      model do
        variable(y[i], i <- [1, 2, 3], lb: 0.0)
        constraint(y[1] + y[2] + y[3] <= 5)
        objective(y[1])
      end

    assert m.var_counter == 3
    names = m.vars |> Map.values() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == [{:y, 1}, {:y, 2}, {:y, 3}]
  end

  test "indexed variable with a tuple key registers all index combinations" do
    m =
      model do
        variable(w[{i, j}], i <- [1, 2], j <- [:a, :b])
        constraint(w[{1, :a}] + w[{2, :b}] <= 1)
        objective(w[{1, :b}])
      end

    assert m.var_counter == 4
    names = m.vars |> Map.values() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == [{:w, {1, :a}}, {:w, {1, :b}}, {:w, {2, :a}}, {:w, {2, :b}}]
  end

  test "generator filters restrict the index set" do
    m =
      model do
        variable(y[i], i <- 1..4, rem(i, 2) == 0)
        objective(y[2])
      end

    assert m.var_counter == 2
    names = m.vars |> Map.values() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == [{:y, 2}, {:y, 4}]
  end

  test "x[i] in a constraint contributes the right term" do
    m =
      model do
        variable(y[i], i <- [1, 2])
        constraint(3 * y[2] <= 6)
        objective(y[1])
      end

    [c] = constraints_in_order(m)
    y2_id = 1
    assert c.aff.terms == %{y2_id => 3.0}
    assert c.rhs == 6.0
  end

  test "sum without a filter folds all terms" do
    m =
      model do
        variable(y[i], i <- [1, 2, 3])
        constraint(sum(y[i], i <- [1, 2, 3]) <= 10)
        objective(y[1])
      end

    [c] = constraints_in_order(m)
    assert c.aff.terms == %{0 => 1.0, 1 => 1.0, 2 => 1.0}
    assert c.sense == :le
    assert c.rhs == 10.0
  end

  test "sum with a filter only includes matching indices" do
    m =
      model do
        variable(y[i], i <- [1, 2, 3])
        constraint(sum(y[i], i <- [1, 2, 3], i > 1) == 4)
        objective(y[1])
      end

    [c] = constraints_in_order(m)
    assert c.aff.terms == %{1 => 1.0, 2 => 1.0}
    assert c.sense == :eq
    assert c.rhs == 4.0
  end

  test "sum also accepts a literal for comprehension" do
    m =
      model do
        variable(y[i], i <- [1, 2, 3])
        constraint(sum(for i <- [1, 2, 3], i > 1, do: 2 * y[i]) <= 8)
        objective(y[1])
      end

    [c] = constraints_in_order(m)
    assert c.aff.terms == %{1 => 2.0, 2 => 2.0}
  end

  test "a constraint family generates one constraint per binding" do
    supply = %{p1: 60, p2: 50}

    m =
      model do
        variable ship[{p, mk}], p <- [:p1, :p2], mk <- [:m1, :m2]
        constraint(sum(ship[{p, mk}], mk <- [:m1, :m2]) <= supply[p], p <- [:p1, :p2])
        objective ship[{:p1, :m1}]
      end

    assert m.con_counter == 2
    # ids: {p1,m1}=0, {p1,m2}=1, {p2,m1}=2, {p2,m2}=3
    [c1, c2] = constraints_in_order(m)
    assert c1.aff.terms == %{0 => 1.0, 1 => 1.0}
    assert {c1.sense, c1.rhs} == {:le, 60.0}
    assert c2.aff.terms == %{2 => 1.0, 3 => 1.0}
    assert {c2.sense, c2.rhs} == {:le, 50.0}
  end

  test "a constraint family honors filters and multiple generators" do
    m =
      model do
        variable x[{i, j}], i <- 1..2, j <- 1..2
        constraint(x[{i, j}] <= 1, i <- 1..2, j <- 1..2, i != j)
        objective x[{1, 1}]
      end

    assert m.con_counter == 2

    for c <- m.constraints do
      assert map_size(c.aff.terms) == 1
      assert {c.sense, c.rhs} == {:le, 1.0}
    end

    # the filtered-in cells are the off-diagonal ones: ids {1,2}=1 and {2,1}=2
    ids = m.constraints |> Enum.flat_map(&Map.keys(&1.aff.terms)) |> Enum.sort()
    assert ids == [1, 2]
  end

  test "a constraint family can reference neighboring indices" do
    m =
      model do
        variable y[i], i <- [1, 2, 3]
        constraint(y[i] <= y[i + 1], i <- [1, 2])
        objective y[1]
      end

    [c1, c2] = constraints_in_order(m)
    assert c1.aff.terms == %{0 => 1.0, 1 => -1.0}
    assert c2.aff.terms == %{1 => 1.0, 2 => -1.0}
  end

  test "a scalar constraint takes a name option" do
    m =
      model do
        variable x
        constraint(2 * x <= 40, name: :carpentry)
        objective x
      end

    [c] = constraints_in_order(m)
    assert c.name == :carpentry
  end

  test "a constraint family evaluates the name per binding" do
    cap = %{1 => 4, 2 => 5}

    m =
      model do
        variable x[t], t <- [1, 2]
        constraint(x[t] <= cap[t], t <- [1, 2], name: {:cap, t})
        objective x[1]
      end

    [c1, c2] = constraints_in_order(m)
    assert c1.name == {:cap, 1}
    assert c2.name == {:cap, 2}
    assert c1.rhs == 4.0
    assert c2.rhs == 5.0
  end

  test "unnamed constraints keep a nil name" do
    m =
      model do
        variable x
        constraint x <= 1
        objective x
      end

    [c] = constraints_in_order(m)
    assert c.name == nil
  end

  test "constant folding moves constants to the rhs" do
    m =
      model do
        variable(x)
        constraint(2 * x + 5 <= 10)
        objective(x)
      end

    [c] = constraints_in_order(m)
    assert c.aff.terms == %{0 => 2.0}
    assert c.aff.constant == 0.0
    assert c.rhs == 5.0
  end

  test "both literal orders 2 * x and x * 2 give coefficient 2" do
    m =
      model do
        variable(x)
        constraint(2 * x <= 10)
        constraint(x * 2 <= 10)
        objective(x)
      end

    [c1, c2] = constraints_in_order(m)
    assert c1.aff.terms == %{0 => 2.0}
    assert c2.aff.terms == %{0 => 2.0}
  end

  test "a runtime numeric coefficient works on either side" do
    a = 3.0

    m =
      model do
        variable(x)
        constraint(a * x <= 6)
        constraint(x * a >= 1)
        objective(x)
      end

    [c1, c2] = constraints_in_order(m)
    assert c1.aff.terms == %{0 => 3.0}
    assert c2.aff.terms == %{0 => 3.0}
  end

  test "variables and constants on both sides of a constraint" do
    m =
      model do
        variable(x)
        variable(z)
        constraint(2 * x + 1 <= z + 4)
        objective(x)
      end

    [c] = constraints_in_order(m)
    # 2x + 1 - z - 4 <= 0  ->  2x - z <= 3
    assert c.aff.terms == %{0 => 2.0, 1 => -1.0}
    assert c.rhs == 3.0
  end

  # since the quadratic features, x * y is representable: in the objective
  # as a quadratic objective term, in a constraint as a quadratic constraint
  test "x * y in a constraint becomes a quadratic constraint" do
    m =
      model do
        variable(x)
        variable(y)
        constraint(x * y <= 1)
        objective(x)
      end

    assert m.con_counter == 0
    assert [%Optex.QConstraint{sense: :le}] = m.qconstraints
  end

  test "binary variable through the DSL forces [0, 1] bounds" do
    m =
      model do
        variable(z, type: :bin)
        objective(z)
      end

    assert %Var{type: :bin} = m.vars[0]
    assert m.vars[0].lb == 0.0
    assert m.vars[0].ub == 1.0
  end

  test "objective and sense: option are applied; sense defaults to :min" do
    m_default =
      model do
        variable(x)
        objective(2 * x + 1)
      end

    assert m_default.sense == :min
    assert m_default.objective == %Aff{terms: %{0 => 2.0}, constant: 1.0}

    m_max =
      model sense: :max do
        variable(x)
        objective(x)
      end

    assert m_max.sense == :max
  end

  test "the full required-surface example builds the expected model" do
    m =
      model sense: :min do
        variable(x, lb: 0.0)
        variable(y[i], i <- [1, 2, 3], lb: 0.0)
        variable(z, type: :bin)

        constraint(2 * x + sum(y[i], i <- [1, 2, 3]) <= 10)
        constraint(x - y[1] >= 0)
        constraint(sum(y[i], i <- [1, 2, 3], i > 1) == 4)

        objective(x + 2 * y[1] + z)
      end

    assert %Model{} = m
    assert m.var_counter == 5
    assert m.con_counter == 3
    assert m.sense == :min

    [c1, c2, c3] = constraints_in_order(m)
    # ids: x=0, y1=1, y2=2, y3=3, z=4
    assert c1.aff.terms == %{0 => 2.0, 1 => 1.0, 2 => 1.0, 3 => 1.0}
    assert {c1.sense, c1.rhs} == {:le, 10.0}
    assert c2.aff.terms == %{0 => 1.0, 1 => -1.0}
    assert {c2.sense, c2.rhs} == {:ge, 0.0}
    assert c3.aff.terms == %{2 => 1.0, 3 => 1.0}
    assert {c3.sense, c3.rhs} == {:eq, 4.0}

    assert m.objective == %Aff{terms: %{0 => 1.0, 1 => 2.0, 4 => 1.0}, constant: 0.0}
  end

  test "user variable names cannot collide with the threaded model variable" do
    # a user variable literally named `model` must not break the threading
    m =
      model do
        variable(model, lb: 2.0)
        constraint(model <= 5)
        objective(model)
      end

    assert %Model{} = m
    assert m.vars[0].name == :model
  end
end
