defmodule Optex.GenConstraintsTest do
  # Native general constraints: neutral layer, DSL surface, and the strict
  # capability rejection. Actual solves live in the backend test files.
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{Aff, Model, Solver, Transform}

  describe "Model.add_indicator_constraint/6" do
    test "stores a normalized indicator with defaults" do
      m = Model.new()
      {_b, m} = Model.add_variable(m, name: :b, type: :bin)
      {_x, m} = Model.add_variable(m, name: :x)

      m = Model.add_indicator_constraint(m, :b, [{:x, 2.0}], :le, 10.0, name: :cap)

      [ind] = m.indicators
      assert ind.bin_id == 0
      assert ind.active_value == 1
      assert ind.aff.terms == %{1 => 2.0}
      assert {ind.sense, ind.rhs} == {:le, 10.0}
      assert ind.name == :cap
    end

    test "folds the affine constant into the rhs and honors active_when: 0" do
      m = Model.new()
      {b, m} = Model.add_variable(m, name: :b, type: :bin)
      {x, m} = Model.add_variable(m, name: :x)

      aff = %Aff{terms: %{x.id => 1.0}, constant: 3.0}
      m = Model.add_indicator_constraint(m, b, aff, :ge, 5.0, active_when: 0)

      [ind] = m.indicators
      assert ind.aff.constant == 0.0
      assert ind.rhs == 2.0
      assert ind.active_value == 0
    end

    test "rejects a non-binary indicator variable" do
      m = Model.new()
      {_x, m} = Model.add_variable(m, name: :x)

      assert_raise ArgumentError, ~r/must be a :bin variable/, fn ->
        Model.add_indicator_constraint(m, :x, [{:x, 1.0}], :le, 1.0)
      end
    end
  end

  describe "Model.add_abs/3" do
    test "a bare variable argument needs no auxiliary" do
      m = Model.new()
      {x, m} = Model.add_variable(m, name: :x, lb: :neg_infinity)
      {t, m} = Model.add_abs(m, x, name: :t)

      assert m.abs_defs == [{t.id, x.id}]
      assert m.constraints == []
      assert t.lb == 0.0
    end

    test "an expression argument gets a free aux variable pinned by a row" do
      m = Model.new()
      {x, m} = Model.add_variable(m, name: :x)
      {y, m} = Model.add_variable(m, name: :y)

      aff = Aff.add(Aff.from_var(x), Aff.scale(Aff.from_var(y), -1.0))
      {t, m} = Model.add_abs(m, aff, name: :t)

      # aux var u with u == x - y, then t = |u|
      [{res_id, arg_id}] = m.abs_defs
      assert res_id == t.id

      aux = m.vars[arg_id]
      assert aux.name == {:t, :arg}
      assert {aux.lb, aux.ub} == {:neg_infinity, :infinity}

      [row] = m.constraints
      assert row.name == {:t, :def}
      assert row.sense == :eq
      assert row.aff.terms == %{arg_id => 1.0, x.id => -1.0, y.id => 1.0}
    end
  end

  describe "DSL surface" do
    test "if: turns a constraint into an indicator, including families" do
      cap = %{1 => 4.0, 2 => 6.0}

      m =
        model do
          variable open[s], s <- [1, 2], type: :bin
          variable ship[s], s <- [1, 2], lb: 0.0
          constraint ship[1] + ship[2] >= 5
          constraint(ship[s] <= cap[s], s <- [1, 2], if: open[s], name: {:cap, s})
          objective ship[1] + ship[2]
        end

      assert m.con_counter == 1
      assert length(m.indicators) == 2

      [i2, i1] = m.indicators
      assert i1.name == {:cap, 1}
      assert i1.active_value == 1
      assert {i1.sense, i1.rhs} == {:le, 4.0}
      assert i2.name == {:cap, 2}
    end

    test "if: {b, 0} activates when the binary is off" do
      m =
        model do
          variable b, type: :bin
          variable x, lb: 0.0
          constraint(x <= 1, if: {b, 0})
          objective x + b
        end

      [ind] = m.indicators
      assert ind.active_value == 0
    end

    test "bound: on a constraint is rejected as unnecessary" do
      assert_raise ArgumentError, ~r/need no big-M/, fn ->
        Code.eval_string("""
        import Optex.DSL

        model do
          variable b, type: :bin
          variable x
          constraint x <= 1, if: b, bound: 100
          objective x
        end
        """)
      end
    end

    test "variable t = abs(expr) defines a native abs, scalar and indexed" do
      m =
        model do
          variable x, lb: :neg_infinity
          variable t = abs(x)
          variable y[i], i <- [1, 2], lb: :neg_infinity
          variable d[i] = abs(y[i] - 1), i <- [1, 2]
          objective t + d[1] + d[2]
        end

      # t = |x| directly; each d[i] gets an aux for y[i] - 1
      assert length(m.abs_defs) == 3
      assert [{_, x_id} | _] = Enum.reverse(m.abs_defs)
      assert m.vars[x_id].name == :x

      names = m.vars |> Map.values() |> Enum.map(& &1.name)
      assert {:d, 1} in names
      assert {{:d, 1}, :arg} in names
    end

    test "abs deep inside an expression raises with guidance" do
      assert_raise ArgumentError, ~r/define it as a variable first/, fn ->
        Code.eval_string("""
        import Optex.DSL

        model do
          variable x
          constraint abs(x) <= 5
          objective x
        end
        """)
      end
    end

    test "max/min inside expressions raise instead of silently comparing structs" do
      assert_raise ArgumentError, ~r/silently compare/, fn ->
        Code.eval_string("""
        import Optex.DSL

        model do
          variable x
          variable y
          constraint max(x, y) <= 5
          objective x
        end
        """)
      end
    end

    test "maxi/mini misspellings point at the native spelling" do
      assert_raise ArgumentError, ~r/spelled variable t = max/, fn ->
        Code.eval_string("""
        import Optex.DSL

        model do
          variable x
          variable t = maxi(x, 3)
          objective t
        end
        """)
      end
    end
  end

  describe "min/max defined variables" do
    test "scalar max folds constants and reuses bare variables, no aux" do
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          variable t = max(x, y, 2, 7)
          objective t
        end

      [{res, :max, arg_ids, constant}] = m.minmax_defs
      assert m.vars[res].name == :t
      assert Enum.map(arg_ids, &m.vars[&1].name) == [:x, :y]
      assert constant == 7.0

      # bare variables reuse their ids: only x, y, t exist, no def rows
      assert map_size(m.vars) == 3
      assert m.constraints == []

      # result defaults unbounded (unlike abs)
      assert {m.vars[res].lb, m.vars[res].ub} == {:neg_infinity, :infinity}
    end

    test "min folds constants with the minimum" do
      m =
        model do
          variable x, lb: 0.0
          variable t = min(x, 2, 7)
          objective t
        end

      [{_res, :min, _arg_ids, constant}] = m.minmax_defs
      assert constant == 2.0
    end

    test "expression arguments get position-indexed aux vars and def rows" do
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          variable t = max(x + 1, 2 * y)
          objective t
        end

      [{_res, :max, [a0, a1], nil}] = m.minmax_defs
      assert m.vars[a0].name == {:t, {:arg, 0}}
      assert m.vars[a1].name == {:t, {:arg, 1}}

      con_names = Enum.map(m.constraints, & &1.name)
      assert {:t, {:def, 0}} in con_names
      assert {:t, {:def, 1}} in con_names
    end

    test "indexed families bind per key" do
      m =
        model do
          variable x[i], i <- [1, 2], lb: 0.0
          variable t[i] = max(x[i], 0), i <- [1, 2]
          objective t[1] + t[2]
        end

      assert length(m.minmax_defs) == 2
      names = m.vars |> Map.values() |> Enum.map(& &1.name)
      assert {:t, 1} in names
      assert {:t, 2} in names
    end

    test "a min/max of constants only is rejected" do
      assert_raise ArgumentError, ~r/at least one variable/, fn ->
        Model.add_minmax(Model.new(), :max, [1, 2.5])
      end
    end

    test "quadratic arguments are rejected at build time" do
      assert_raise ArgumentError, ~r/min\/max arguments/, fn ->
        Code.eval_string("""
        import Optex.DSL

        model do
          variable x
          variable y
          variable t = max(x * x, y)
          objective t
        end
        """)
      end
    end

    test "the transform carries min/max onto the wire; every non-Gurobi backend rejects" do
      m =
        model do
          variable x, lb: 0.0
          variable t = max(x, 3.5)
          objective t
        end

      si = Transform.to_solver_input(m)
      assert Optex.SolverInput.required_capabilities(si) == [:min_max]

      [mm] = si.minmax_defs
      assert %Optex.SolverInput.MinMax{op: :max, constant: 3.5, res_col: 1} = mm
      assert mm.arg_cols == [0]

      assert {:error, {:unsupported, :min_max, Solver.HiGHS}} = Optex.optimize(m)

      assert {:error, {:unsupported, :min_max, Solver.CPLEX}} =
               Optex.optimize(m, solver: Solver.CPLEX)

      assert_raise ArgumentError, ~r/cannot emit MPS/, fn -> Optex.MPS.emit(si) end
      assert_raise ArgumentError, ~r/cannot emit LP/, fn -> Optex.LP.emit(m) end
    end

    test "the pretty printer renders min/max definitions" do
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          variable t = max(x, y, 3.5)
          objective t
        end

      assert Optex.Format.pretty(m) =~ "t = max(x, y; 3.5)"
    end
  end

  describe "Model.add_pwl/4" do
    test "stores breakpoints as floats with an aux for expressions" do
      m = Model.new()
      {x, m} = Model.add_variable(m, name: :x, lb: :neg_infinity)
      {y, m} = Model.add_pwl(m, x, [{0, 0}, {10, 5}], name: :y)

      assert m.pwl_defs == [{y.id, x.id, [0.0, 10.0], [0.0, 5.0]}]
      assert {y.lb, y.ub} == {:neg_infinity, :infinity}

      # expression argument gets the same aux pattern as abs
      aff = Aff.scale(Aff.from_var(x), 2.0)
      {z, m} = Model.add_pwl(m, aff, [{0, 0}, {1, 1}], name: :z)
      [{res, arg, _, _} | _] = m.pwl_defs
      assert res == z.id
      assert m.vars[arg].name == {:z, :arg}
    end

    test "rejects malformed breakpoints" do
      m = Model.new()
      {x, m} = Model.add_variable(m, name: :x)

      assert_raise ArgumentError, ~r/at least two/, fn ->
        Model.add_pwl(m, x, [{0, 0}])
      end

      assert_raise ArgumentError, ~r/non-decreasing/, fn ->
        Model.add_pwl(m, x, [{5, 0}, {1, 1}])
      end

      assert_raise ArgumentError, ~r/number pairs/, fn ->
        Model.add_pwl(m, x, [{0, 0}, {:a, 1}])
      end
    end

    test "accepts interior jumps and rejects the degenerate repeated-x forms" do
      m = Model.new()
      {x, m} = Model.add_variable(m, name: :x)

      # the minimal valid jump: a step function
      {_y, m2} = Model.add_pwl(m, x, [{0, 0}, {5, 0}, {5, 10}, {10, 10}], name: :y)
      [{_, _, xs, ys}] = m2.pwl_defs
      assert xs == [0.0, 5.0, 5.0, 10.0]
      assert ys == [0.0, 0.0, 10.0, 10.0]

      # a jump in the first or last pair leaves no segment for the
      # extension slopes
      assert_raise ArgumentError, ~r/interior/, fn ->
        Model.add_pwl(m, x, [{0, 0}, {0, 1}])
      end

      assert_raise ArgumentError, ~r/interior/, fn ->
        Model.add_pwl(m, x, [{0, 0}, {5, 1}, {5, 2}])
      end

      # three points on one x never mean anything
      assert_raise ArgumentError, ~r/at most two equal x/, fn ->
        Model.add_pwl(m, x, [{0, 0}, {5, 1}, {5, 2}, {5, 3}, {10, 4}])
      end

      # equal x AND equal y is a duplicate point, not a jump
      assert_raise ArgumentError, ~r/must change y/, fn ->
        Model.add_pwl(m, x, [{0, 0}, {5, 1}, {5, 1}, {10, 2}])
      end
    end
  end

  describe "pwl DSL surface" do
    test "variable y = pwl(x, points) defines the construct, scalar and indexed" do
      curve = [{0, 0}, {10, 10}, {20, 30}]

      m =
        model do
          variable x, lb: 0.0
          variable y = pwl(x, curve)
          variable w[i], i <- [1, 2], lb: 0.0
          variable c[i] = pwl(w[i] + 1, curve), i <- [1, 2]
          objective y + c[1] + c[2]
        end

      assert length(m.pwl_defs) == 3
      # scalar over a bare variable: no aux
      {_, arg, xs, _ys} = List.last(m.pwl_defs)
      assert m.vars[arg].name == :x
      assert xs == [0.0, 10.0, 20.0]

      names = m.vars |> Map.values() |> Enum.map(& &1.name)
      assert {{:c, 1}, :arg} in names
    end

    test "pwl deep inside an expression raises with guidance" do
      assert_raise ArgumentError, ~r/define it as a variable first/, fn ->
        Code.eval_string("""
        import Optex.DSL

        model do
          variable x
          constraint pwl(x, [{0, 0}, {1, 1}]) <= 5
          objective x
        end
        """)
      end
    end
  end

  describe "capabilities" do
    defp indicator_model do
      model do
        variable b, type: :bin
        variable x, lb: 0.0
        constraint(x <= 4, if: b)
        objective x + b
      end
    end

    test "the transform carries constructs onto the wire" do
      si = Transform.to_solver_input(indicator_model())

      assert Optex.SolverInput.required_capabilities(si) == [:indicator]
      [ind] = si.indicators
      assert ind.bin_col == 0
      assert ind.cols == [1]
      assert ind.coefs == [1.0]
      assert {ind.sense, ind.rhs} == {:le, 4.0}
    end

    test "HiGHS strictly rejects inputs with constructs it lacks" do
      si = Transform.to_solver_input(indicator_model())

      assert {:error, {:unsupported, :indicator, Solver.HiGHS}} = Solver.HiGHS.solve(si)

      assert {:error, {:unsupported, :indicator, Solver.HiGHS}} =
               Optex.optimize(indicator_model())
    end

    test "MPS and LP emitters refuse models with constructs" do
      m = indicator_model()

      assert_raise ArgumentError, ~r/cannot emit MPS/, fn ->
        Optex.MPS.emit(Transform.to_solver_input(m))
      end

      assert_raise ArgumentError, ~r/cannot emit LP/, fn ->
        Optex.LP.emit(m)
      end
    end

    test "explain_infeasibility flags constructs the IIS cannot examine" do
      # the linear rows are infeasible on their own; the indicator is
      # outside IIS scope and must be flagged
      m =
        model do
          variable b, type: :bin
          variable x, lb: 0.0
          constraint(x >= 3, name: :lo)
          constraint(x <= 1, name: :hi)
          constraint(x <= 9, if: b)
          objective x + b
        end

      {:ok, %{constraints: cons, not_examined: not_examined}} = Optex.explain_infeasibility(m)

      names = Enum.map(cons, fn {name, _} -> name end)
      assert :lo in names
      assert :hi in names
      assert not_examined == [:indicator]
    end

    test "the pretty printer renders indicators and abs definitions" do
      m =
        model do
          variable pick, type: :bin
          variable x, lb: :neg_infinity
          variable t = abs(x - 2)
          constraint(x <= 9, if: pick, name: :gate)
          objective t + pick
        end

      text = Optex.Format.pretty(m)

      assert text =~ "gate: pick = 1 -> x <= 9"
      assert text =~ "t = |t[:arg]|"
    end
  end
end
