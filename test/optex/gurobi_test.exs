defmodule Optex.Solver.GurobiTest do
  # The second backend: same contract, plus cross-solver agreement with
  # HiGHS, which is the proof that nothing above the Solver behaviour is
  # solver-specific.
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{Solution, Solver, Transform}

  @moduletag :gurobi

  defp gurobi_solve!(model, opts \\ []) do
    {:ok, %Solution{} = sol} =
      model |> Transform.to_solver_input() |> Solver.Gurobi.solve(opts)

    sol
  end

  defp lp_model do
    model sense: :max do
      variable x, lb: 0.0
      variable y, lb: 0.0
      constraint(x + 2 * y <= 4, name: :first)
      constraint 3 * x + y <= 6
      objective x + y
    end
  end

  test "LP solves to the known optimum with values and duals" do
    sol = gurobi_solve!(lp_model())

    assert sol.status == :optimal
    assert_in_delta sol.objective, 2.8, 1.0e-6
    assert_in_delta sol.values[0], 1.6, 1.0e-6
    assert_in_delta sol.values[1], 1.2, 1.0e-6
    assert_in_delta sol.duals[0], 0.4, 1.0e-6
    assert_in_delta sol.duals[1], 0.2, 1.0e-6
  end

  test "MIP respects integrality; stats and gap are reported" do
    m =
      model sense: :min do
        variable x, type: :int, lb: 0.0
        constraint x >= 2.5
        objective x + 5
      end

    sol = gurobi_solve!(m)

    assert sol.status == :optimal
    # objective constant travels through objcon
    assert_in_delta sol.objective, 8.0, 1.0e-6
    assert sol.duals == nil
    assert is_number(sol.stats.mip_gap)
    assert sol.stats.solve_time >= 0.0
  end

  test "binary variables use Gurobi's native B type" do
    m =
      model sense: :max do
        variable p, type: :bin
        variable q, type: :bin
        constraint p + q == 1
        objective 2 * p + q
      end

    sol = gurobi_solve!(m)
    assert_in_delta sol.objective, 2.0, 1.0e-6
    assert_in_delta sol.values[0], 1.0, 1.0e-9
  end

  test "infeasible and unbounded statuses decode" do
    infeasible =
      model do
        variable x, lb: 0.0, ub: 1.0
        constraint x >= 2
        objective x
      end

    assert gurobi_solve!(infeasible).status == :infeasible

    unbounded =
      model sense: :max do
        variable x, lb: 0.0
        objective x
      end

    # Gurobi may report INF_OR_UNBD unless presolve is told otherwise
    assert gurobi_solve!(unbounded).status in [:unbounded, :unbounded_or_infeasible]
  end

  test "options are honored and unknown options fail fast" do
    sol = gurobi_solve!(lp_model(), time_limit: 60.0, threads: 1, mip_gap: 1.0e-4, log: false)
    assert sol.status == :optimal

    input = Transform.to_solver_input(lp_model())
    assert {:error, {:unknown_option, :bogus}} = Solver.Gurobi.solve(input, bogus: 1)

    assert {:error, {:invalid_option_value, :threads, "x"}} =
             Solver.Gurobi.solve(input, threads: "x")
  end

  test "log: pid streams Gurobi log lines" do
    {:ok, %Solution{status: :optimal}} =
      lp_model() |> Transform.to_solver_input() |> Solver.Gurobi.solve(log: self())

    assert_receive {:optex_gurobi_log, line}, 5_000
    assert is_binary(line)
  end

  test "a pre-cancelled token interrupts the solve" do
    items = 1..40
    weight = Map.new(items, fn i -> {i, rem(i * 7919, 97) + 3} end)
    value = Map.new(items, fn i -> {i, rem(i * 6733, 89) + 5} end)
    cap = weight |> Map.values() |> Enum.sum() |> div(2)

    m =
      model sense: :max do
        variable take[i], i <- items, type: :bin
        constraint sum(weight[i] * take[i], i <- items) <= cap
        objective sum(value[i] * take[i], i <- items)
      end

    token = Solver.Gurobi.cancel_token()
    :ok = Solver.Gurobi.cancel(token)

    sol = gurobi_solve!(m, cancel: token)
    assert sol.status == :interrupted
  end

  test "the IIS names the conflicting constraints through explain_infeasibility" do
    m =
      model do
        variable x, lb: 0.0
        variable y, lb: 0.0
        constraint(x >= 3, name: :needs_lots)
        constraint(x <= 1, name: :allows_little)
        constraint(y <= 5, name: :innocent)
        objective x + y
      end

    {:ok, %{constraints: cons}} = Optex.explain_infeasibility(m, solver: Solver.Gurobi)

    names = Enum.map(cons, fn {name, _} -> name end)
    assert :needs_lots in names
    assert :allows_little in names
    refute :innocent in names
  end

  test "the malformed-input firewall holds without crashing the VM" do
    input = Transform.to_solver_input(lp_model())

    assert {:error, reason} = Solver.Gurobi.solve(%{input | obj: [1.0]})
    assert reason =~ "length mismatch"

    assert gurobi_solve!(lp_model()).status == :optimal
  end

  describe "construct-aware IIS" do
    test "an indicator in the conflict is named, with nothing unexamined" do
      m =
        model do
          variable b, type: :bin
          variable x, lb: 0.0
          constraint(b >= 1, name: :must_build)
          constraint(x <= 1, if: b, name: :gate)
          constraint(x >= 3, name: :need)
          objective x
        end

      {:ok, %{constraints: cons, constructs: constructs, not_examined: not_examined}} =
        Optex.explain_infeasibility(m, solver: Solver.Gurobi)

      assert {:indicator, :gate} in constructs
      assert :need in Enum.map(cons, fn {name, _} -> name end)
      assert not_examined == []
    end

    test "an abs definition in the conflict reports under its result variable" do
      # |5| can never fit under 2; the abs construct itself is the link
      m =
        model do
          variable x, lb: :neg_infinity
          variable t = abs(x)
          constraint(x == 5, name: :pin)
          constraint(t <= 2, name: :cap)
          objective t
        end

      {:ok, %{constraints: cons, constructs: constructs}} =
        Optex.explain_infeasibility(m, solver: Solver.Gurobi)

      assert {:abs, :t} in constructs

      names = Enum.map(cons, fn {name, _} -> name end)
      assert :pin in names
      assert :cap in names
    end

    test "quadratic constraints and min/max definitions are examined too" do
      qcp =
        model do
          variable x, lb: 5.0
          constraint(x * x <= 1, name: :ball)
          objective x
        end

      {:ok, %{constructs: constructs, variables: vars}} =
        Optex.explain_infeasibility(qcp, solver: Solver.Gurobi)

      assert {:quadratic_constraint, :ball} in constructs
      assert {:x, :lower} in vars

      mm =
        model do
          variable x, lb: 4.0
          variable t = max(x, 0)
          constraint(t <= 1, name: :cap)
          objective t
        end

      {:ok, %{constructs: constructs}} = Optex.explain_infeasibility(mm, solver: Solver.Gurobi)
      assert {:min_max, :t} in constructs
    end
  end

  describe "cross-solver agreement" do
    test "HiGHS and Gurobi agree on objectives and duals across the model zoo" do
      knapsack_items = [:a, :b, :c, :d]
      w = %{a: 4, b: 8, c: 5, d: 2}
      v = %{a: 10, b: 30, c: 25, d: 15}

      models = [
        lp: lp_model(),
        milp:
          model sense: :max do
            variable take[i], i <- knapsack_items, type: :bin
            constraint sum(w[i] * take[i], i <- knapsack_items) <= 15
            objective sum(v[i] * take[i], i <- knapsack_items)
          end,
        offset_lp:
          model sense: :min do
            variable x, lb: 0.0
            constraint x >= 2
            objective 3 * x + 5
          end,
        equality_mip:
          model sense: :max do
            variable p, type: :bin
            variable q, type: :bin
            constraint p + q == 1
            objective 2 * p + q
          end
      ]

      for {label, m} <- models do
        input = Transform.to_solver_input(m)

        {:ok, %Solution{status: :optimal, objective: highs_obj} = h} =
          Solver.HiGHS.solve(input)

        {:ok, %Solution{status: :optimal, objective: gurobi_obj} = g} =
          Solver.Gurobi.solve(input)

        assert_in_delta highs_obj, gurobi_obj, 1.0e-6, "objective mismatch on #{label}"

        if h.duals != nil and g.duals != nil do
          for {row, hd} <- h.duals do
            assert_in_delta hd, g.duals[row], 1.0e-6, "dual mismatch on #{label} row #{row}"
          end
        end
      end
    end
  end
end
