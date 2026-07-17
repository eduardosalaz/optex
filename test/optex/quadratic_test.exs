defmodule Optex.QuadraticTest do
  # Quadratic objectives: the algebra, the DSL, the objective-only rule, and
  # solves. HiGHS supports convex continuous QP, so the solve tests run
  # everywhere; MIQP and three-way agreement add the commercial backends.
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{Aff, Solution, Solver, Transform, Var}

  describe "quadratic algebra" do
    test "x * y produces a normalized qterm; y * x sums into the same cell" do
      x = Aff.from_var(%Var{id: 0})
      y = Aff.from_var(%Var{id: 1})

      q = Aff.add(Aff.mul(x, y), Aff.mul(y, x))
      assert q.qterms == %{{0, 1} => 2.0}
      assert q.terms == %{}
    end

    test "x * x lands on the diagonal" do
      x = Aff.from_var(%Var{id: 3})
      assert Aff.mul(x, x).qterms == %{{3, 3} => 1.0}
    end

    test "(x + 2)(y + 3) expands fully" do
      x = Aff.add(Aff.from_var(%Var{id: 0}), Aff.to_aff(2))
      y = Aff.add(Aff.from_var(%Var{id: 1}), Aff.to_aff(3))

      p = Aff.mul(x, y)
      assert p.qterms == %{{0, 1} => 1.0}
      assert p.terms == %{0 => 3.0, 1 => 2.0}
      assert p.constant == 6.0
    end

    test "scale and add act on qterms" do
      x = Aff.from_var(%Var{id: 0})
      q = Aff.mul(x, x)

      assert Aff.scale(q, 2.5).qterms == %{{0, 0} => 2.5}
      assert Aff.add(q, q).qterms == %{{0, 0} => 2.0}
    end

    test "degree three raises NonlinearError" do
      x = Aff.from_var(%Var{id: 0})
      sq = Aff.mul(x, x)

      assert_raise Optex.NonlinearError, ~r/degree > 2/, fn -> Aff.mul(sq, x) end
      assert_raise Optex.NonlinearError, fn -> Aff.mul(sq, sq) end
    end

    test "constant-only expressions still scale even with the new fields" do
      x = Aff.from_var(%Var{id: 0})
      sq = Aff.mul(x, x)

      assert Aff.mul(sq, Aff.to_aff(3)).qterms == %{{0, 0} => 3.0}
    end
  end

  describe "objective-only rule" do
    test "the DSL accepts a quadratic objective" do
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          constraint x + y >= 1
          objective x * x + 2 * x * y + 3 * y * y - 4 * x
        end

      assert m.objective.qterms == %{{0, 0} => 1.0, {0, 1} => 2.0, {1, 1} => 3.0}
      assert m.objective.terms == %{0 => -4.0}
    end

    test "a quadratic constraint lands in its own id space, normalized" do
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          constraint(x * x + y * y + 1 <= 5, name: :ball)
          constraint x + y >= 1
          objective x
        end

      assert m.qcon_counter == 1
      assert m.con_counter == 1

      [qc] = m.qconstraints
      assert qc.name == :ball
      assert qc.aff.qterms == %{{0, 0} => 1.0, {1, 1} => 1.0}
      assert qc.aff.constant == 0.0
      assert {qc.sense, qc.rhs} == {:le, 4.0}
    end

    test "quadratic terms in indicator rows and abs arguments still reject" do
      assert_raise ArgumentError, ~r/only the objective/, fn ->
        m = Optex.Model.new()
        {b, m} = Optex.Model.add_variable(m, name: :b, type: :bin)
        {x, m} = Optex.Model.add_variable(m, name: :x)

        sq = Aff.mul(Aff.from_var(x), Aff.from_var(x))
        Optex.Model.add_indicator_constraint(m, b, sq, :le, 4.0)
      end
    end

    test "the transform emits normalized lower-triangle triplets" do
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          constraint x + y >= 1
          objective 2 * x * x + 3 * x * y
        end

      si = Transform.to_solver_input(m)

      assert Optex.SolverInput.required_capabilities(si) == [:quadratic_objective]
      assert si.q_cols == [0, 0]
      assert si.q_rows == [0, 1]
      assert si.q_vals == [2.0, 3.0]
    end

    test "LP emit refuses quadratic objectives; pretty renders them" do
      m =
        model do
          variable x, lb: 0.0
          constraint x >= 1
          objective x * x - 2 * x
        end

      assert_raise ArgumentError, ~r/quadratic/, fn -> Optex.LP.emit(m) end

      text = Optex.Format.pretty(m)
      assert text =~ "min x*x - 2 x"
    end
  end

  describe "QP solves (HiGHS, always available)" do
    test "separable convex QP reaches the analytic optimum with literal coefficients" do
      # min x^2 + y^2 - 4x - 6y: gradient zero at (2, 3), objective -13.
      # This value is only correct if coefficients are literal, so it pins
      # the 1/2 x'Qx conversion in every backend.
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          objective x * x + y * y - 4 * x - 6 * y
        end

      {:ok, %Solution{} = sol} = Optex.optimize(m)

      assert sol.status == :optimal
      assert_in_delta sol.objective, -13.0, 1.0e-5
      assert_in_delta sol.values[:x], 2.0, 1.0e-4
      assert_in_delta sol.values[:y], 3.0, 1.0e-4
    end

    test "cross terms: min x^2 + xy + y^2 - 3x - 3y" do
      # gradient [2x + y - 3, x + 2y - 3] = 0 at (1, 1), objective -3
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          objective x * x + x * y + y * y - 3 * x - 3 * y
        end

      {:ok, sol} = Optex.optimize(m)

      assert sol.status == :optimal
      assert_in_delta sol.objective, -3.0, 1.0e-5
      assert_in_delta sol.values[:x], 1.0, 1.0e-4
      assert_in_delta sol.values[:y], 1.0, 1.0e-4
    end

    test "HiGHS rejects quadratic constraints entirely" do
      m =
        model do
          variable x, lb: 0.0
          constraint x * x <= 4
          objective x
        end

      si = Transform.to_solver_input(m)
      assert Optex.SolverInput.required_capabilities(si) == [:quadratic_constraint]

      assert {:error, {:unsupported, :quadratic_constraint, Solver.HiGHS}} = Optex.optimize(m)
    end

    test "HiGHS rejects quadratic objectives with integer variables" do
      m =
        model do
          variable x, type: :int, lb: 0.0
          objective x * x - 5 * x
        end

      assert {:error, {:unsupported, :quadratic_objective_with_integers, Solver.HiGHS}} =
               Optex.optimize(m)
    end
  end

  describe "QP/MIQP on commercial backends" do
    @describetag :gen_solve

    defp capable_backends do
      Enum.filter([Solver.Gurobi, Solver.CPLEX], & &1.available?())
    end

    test "all available backends agree on the QP optimum" do
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          objective x * x + x * y + y * y - 3 * x - 3 * y
        end

      for backend <- [Solver.HiGHS | capable_backends()] do
        {:ok, sol} = Optex.optimize(m, solver: backend)

        assert sol.status == :optimal, "#{inspect(backend)} did not solve"

        assert_in_delta sol.objective,
                        -3.0,
                        1.0e-5,
                        "objective mismatch (#{inspect(backend)})"
      end
    end

    test "convex QCP: maximize a linear objective inside a ball" do
      # max x + y s.t. x^2 + y^2 <= 2: tangent at (1, 1), objective 2
      m =
        model sense: :max do
          variable x, lb: 0.0
          variable y, lb: 0.0
          constraint(x * x + y * y <= 2, name: :ball)
          objective x + y
        end

      for backend <- capable_backends() do
        {:ok, sol} = Optex.optimize(m, solver: backend)

        assert sol.status == :optimal, "#{inspect(backend)} did not solve"
        assert_in_delta sol.objective, 2.0, 1.0e-4, "objective mismatch (#{inspect(backend)})"
        assert_in_delta sol.values[:x], 1.0, 1.0e-3
        assert_in_delta sol.values[:y], 1.0, 1.0e-3
      end
    end

    test "MIQCP: integrality with a quadratic constraint" do
      # max x + y, x^2 + y^2 <= 8, integers: (2, 2) fits exactly
      m =
        model sense: :max do
          variable x, type: :int, lb: 0.0
          variable y, type: :int, lb: 0.0
          constraint x * x + y * y <= 8
          objective x + y
        end

      for backend <- capable_backends() do
        {:ok, sol} = Optex.optimize(m, solver: backend)

        assert sol.status == :optimal
        assert_in_delta sol.objective, 4.0, 1.0e-5, "objective mismatch (#{inspect(backend)})"
      end
    end

    @tag :gurobi
    test "nonconvex QCP solves on Gurobi (outside-the-ball constraint)" do
      # min x + y s.t. x^2 + y^2 >= 2 in [0, 2]^2: touch the circle on an
      # axis, objective sqrt(2)
      m =
        model do
          variable x, lb: 0.0, ub: 2.0
          variable y, lb: 0.0, ub: 2.0
          constraint x * x + y * y >= 2
          objective x + y
        end

      {:ok, sol} = Optex.optimize(m, solver: Solver.Gurobi)

      assert sol.status == :optimal
      assert_in_delta sol.objective, :math.sqrt(2), 1.0e-4
    end

    @tag :cplex
    test "CPLEX rejects quadratic equality constraints specifically" do
      m =
        model do
          variable x, lb: 0.0
          constraint x * x == 4
          objective x
        end

      assert {:error, {:unsupported, :quadratic_equality_constraint, Solver.CPLEX}} =
               Optex.optimize(m, solver: Solver.CPLEX)
    end

    test "MIQP: integrality with a quadratic objective" do
      # min x^2 - 5.2x over integers: continuous optimum 2.6, integer x = 3
      m =
        model do
          variable x, type: :int, lb: 0.0, ub: 10.0
          objective x * x - 5.2 * x
        end

      for backend <- capable_backends() do
        {:ok, sol} = Optex.optimize(m, solver: backend)

        assert sol.status == :optimal
        assert_in_delta sol.values[:x], 3.0, 1.0e-6, "value mismatch (#{inspect(backend)})"
        assert_in_delta sol.objective, -6.6, 1.0e-5, "objective mismatch (#{inspect(backend)})"
      end
    end
  end
end
