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

    test "variable t = max(...) is rejected with the capability rationale" do
      assert_raise ArgumentError, ~r/only on Gurobi/, fn ->
        Code.eval_string("""
        import Optex.DSL

        model do
          variable x
          variable t = max(x, 3)
          objective t
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
