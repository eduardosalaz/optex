defmodule Optex.GenConstraintsSolveTest do
  # End-to-end solves of native general constraints on every capable backend,
  # cross-checked against a manually linearized equivalent solved by HiGHS.
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{Solution, Solver}

  @moduletag :gen_solve

  defp capable_backends do
    Enum.filter([Solver.Gurobi, Solver.CPLEX], & &1.available?())
  end

  # SOS and cones are COPT capabilities too; include it only when its
  # license probe passed (available?/0 cannot see an expired license)
  defp commercial_backends do
    copt = if Application.get_env(:optex, :copt_usable, false), do: [Solver.COPT], else: []
    capable_backends() ++ copt
  end

  defp solve!(backend, model, opts \\ []) do
    {:ok, %Solution{} = sol} = Optex.optimize(model, [solver: backend] ++ opts)
    sol
  end

  test "indicator capacity gating matches the manually linked HiGHS model" do
    sites = [1, 2]
    cap = %{1 => 70, 2 => 90}
    fixed = %{1 => 40, 2 => 55}
    ship_cost = %{1 => 2, 2 => 3}

    native =
      model do
        variable open[s], s <- sites, type: :bin
        variable ship[s], s <- sites, lb: 0.0
        constraint(ship[1] + ship[2] == 100, name: :demand)
        constraint(ship[s] <= cap[s], s <- sites, if: open[s], name: {:cap, s})
        # an indicator only constrains when active; cap shipping when closed too
        constraint(ship[s] <= 0, s <- sites, if: {open[s], 0}, name: {:closed, s})

        objective sum(fixed[s] * open[s], s <- sites) +
                    sum(ship_cost[s] * ship[s], s <- sites)
      end

    manual =
      model do
        variable open[s], s <- sites, type: :bin
        variable ship[s], s <- sites, lb: 0.0
        constraint ship[1] + ship[2] == 100
        constraint(ship[s] - cap[s] * open[s] <= 0, s <- sites)

        objective sum(fixed[s] * open[s], s <- sites) +
                    sum(ship_cost[s] * ship[s], s <- sites)
      end

    {:ok, %Solution{status: :optimal, objective: reference}} =
      Optex.optimize(manual, solver: Solver.HiGHS)

    assert_in_delta reference, 325.0, 1.0e-6

    for backend <- capable_backends() do
      sol = solve!(backend, native)
      assert sol.status == :optimal, "#{inspect(backend)} did not solve"

      assert_in_delta sol.objective, reference, 1.0e-6, "objective mismatch (#{inspect(backend)})"
    end
  end

  test "a negated indicator activates when the binary is off" do
    m =
      model sense: :max do
        variable b, type: :bin
        variable x, lb: 0.0, ub: 5.0
        constraint(x <= 1, if: {b, 0})
        objective x - 10 * b
      end

    for backend <- capable_backends() do
      sol = solve!(backend, m)

      # b = 1 would allow x = 5 but costs 10; best is b = 0 with x forced to 1
      assert sol.status == :optimal
      assert_in_delta sol.objective, 1.0, 1.0e-6, "objective mismatch (#{inspect(backend)})"
      assert_in_delta sol.values[:b], 0.0, 1.0e-9
    end
  end

  test "native abs is exact even when maximized (where epigraphs fail)" do
    m =
      model sense: :max do
        variable x, lb: -3.0, ub: 2.0
        variable t = abs(x)
        objective t
      end

    for backend <- capable_backends() do
      sol = solve!(backend, m)

      assert sol.status == :optimal
      assert_in_delta sol.objective, 3.0, 1.0e-6, "objective mismatch (#{inspect(backend)})"
      assert_in_delta sol.values[:x], -3.0, 1.0e-6
    end
  end

  test "pwl interpolates between breakpoints on both backends" do
    # convex cost curve: marginal cost 1 up to 10 units, then 2
    m =
      model do
        variable x, lb: 0.0
        variable y = pwl(x, [{0, 0}, {10, 10}, {20, 30}])
        constraint x >= 15
        objective y
      end

    for backend <- capable_backends() do
      sol = solve!(backend, m)

      assert sol.status == :optimal
      assert_in_delta sol.values[:x], 15.0, 1.0e-6
      assert_in_delta sol.values[:y], 20.0, 1.0e-6, "interpolation mismatch (#{inspect(backend)})"
    end
  end

  test "pwl end-segment extension semantics agree across backends" do
    # curve defined on [0, 30]; probe beyond both ends: the first segment
    # (slope 2) and last segment (slope 1) must extend
    curve = [{0, 0}, {10, 20}, {30, 40}]

    for {fixed_x, expected_y} <- [{25.0, 35.0}, {40.0, 50.0}, {-5.0, -10.0}] do
      m =
        model do
          variable x, lb: :neg_infinity
          variable y = pwl(x, curve)
          constraint x == fixed_x
          objective y
        end

      for backend <- capable_backends() do
        sol = solve!(backend, m)

        assert sol.status == :optimal, "#{inspect(backend)} failed at x = #{fixed_x}"

        assert_in_delta sol.values[:y],
                        expected_y,
                        1.0e-6,
                        "pwl(#{fixed_x}) mismatch (#{inspect(backend)})"
      end
    end
  end

  test "pwl jump semantics agree across backends: either value at the jump" do
    # step function 0 -> 10 at x = 5; at the jump both values are feasible
    # and the objective direction picks one, pinning the vertical-segment
    # semantics on both backends
    step = [{0, 0}, {5, 0}, {5, 10}, {10, 10}]

    for {sense, expected_at_jump} <- [{:max, 10.0}, {:min, 0.0}] do
      m =
        model sense: sense do
          variable x, lb: :neg_infinity
          variable y = pwl(x, step)
          constraint x == 5
          objective y
        end

      for backend <- capable_backends() do
        sol = solve!(backend, m)

        assert sol.status == :optimal, "#{inspect(backend)} failed at the jump (#{sense})"

        assert_in_delta sol.values[:y],
                        expected_at_jump,
                        1.0e-6,
                        "jump value mismatch (#{inspect(backend)}, #{sense})"
      end
    end

    # interior and outside probes: the jump changes nothing away from x = 5,
    # including the flat end-segment extension
    for {fixed_x, expected_y} <- [{2.0, 0.0}, {7.0, 10.0}, {-3.0, 0.0}, {12.0, 10.0}] do
      m =
        model do
          variable x, lb: :neg_infinity
          variable y = pwl(x, step)
          constraint x == fixed_x
          objective y
        end

      for backend <- capable_backends() do
        sol = solve!(backend, m)

        assert sol.status == :optimal

        assert_in_delta sol.values[:y],
                        expected_y,
                        1.0e-6,
                        "step(#{fixed_x}) mismatch (#{inspect(backend)})"
      end
    end
  end

  test "the pwl firewall rejects degenerate jumps pushed past the model layer" do
    m =
      model do
        variable x, lb: 0.0
        variable y = pwl(x, [{0, 0}, {5, 0}, {5, 10}, {10, 10}])
        constraint x == 2
        objective y
      end

    input = Optex.Transform.to_solver_input(m)
    [pwl] = input.pwl_defs
    # triple-equal x can only arrive through a hand-built input
    bad = %{input | pwl_defs: [%{pwl | xs: [0.0, 5.0, 5.0, 5.0], ys: [0.0, 0.0, 5.0, 10.0]}]}

    for backend <- capable_backends() do
      assert {:error, reason} = backend.solve(bad)
      assert reason =~ "invalid pwl definition", "firewall miss (#{inspect(backend)})"

      # the VM survived and a clean solve still works
      sol = solve!(backend, m)
      assert sol.status == :optimal
    end
  end

  @tag :gurobi
  test "native min/max reach the analytic optimum on Gurobi" do
    # max(1, 2, 3.5) = 3.5: the constant operand wins
    m =
      model do
        variable x, lb: 0.0
        variable y, lb: 0.0
        constraint x == 1
        constraint y == 2
        variable t = max(x, y, 3.5)
        objective t
      end

    sol = solve!(Solver.Gurobi, m)
    assert sol.status == :optimal
    assert_in_delta sol.objective, 3.5, 1.0e-6

    # min twin: min(1, 2, 3.5) = 1.0, a variable operand wins
    m =
      model do
        variable x, lb: 0.0
        variable y, lb: 0.0
        constraint x == 1
        constraint y == 2
        variable t = min(x, y, 3.5)
        objective t
      end

    sol = solve!(Solver.Gurobi, m)
    assert_in_delta sol.objective, 1.0, 1.0e-6
  end

  @tag :gurobi
  test "maximizing the max is exact (where epigraphs fail) on Gurobi" do
    # an epigraph t >= x, t >= y is unbounded under maximization; the native
    # construct pins t == max(x, y) = 3 at y's upper bound
    m =
      model sense: :max do
        variable x, lb: 0.0, ub: 2.0
        variable y, lb: 0.0, ub: 3.0
        variable t = max(x, y)
        objective t
      end

    sol = solve!(Solver.Gurobi, m)
    assert sol.status == :optimal
    assert_in_delta sol.objective, 3.0, 1.0e-6
  end

  @tag :gurobi
  test "min/max expression arguments go through position-indexed aux vars" do
    # max(2x, y - 1) with x = 2, y = 6: max(4, 5) = 5
    m =
      model do
        variable x, lb: 0.0
        variable y, lb: 0.0
        constraint x == 2
        constraint y == 6
        variable t = max(2 * x, y - 1)
        objective t
      end

    sol = solve!(Solver.Gurobi, m)

    assert sol.status == :optimal
    assert_in_delta sol.objective, 5.0, 1.0e-6
    assert_in_delta sol.values[{:t, {:arg, 0}}], 4.0, 1.0e-6
    assert_in_delta sol.values[{:t, {:arg, 1}}], 5.0, 1.0e-6
  end

  @tag :gurobi
  test "the min/max firewall rejects malformed definitions without crashing the VM" do
    m =
      model do
        variable x, lb: 0.0
        variable t = max(x, 1)
        objective t
      end

    input = Optex.Transform.to_solver_input(m)
    [mm] = input.minmax_defs
    bad = %{input | minmax_defs: [%{mm | arg_cols: [99]}]}

    assert {:error, reason} = Solver.Gurobi.solve(bad)
    assert reason =~ "invalid min/max definition"

    # the VM survived and a clean solve still works
    sol = solve!(Solver.Gurobi, m)
    assert sol.status == :optimal
  end

  test "quadratic cones reach the analytic optimum on every capable backend" do
    # min t s.t. t >= ||(x, y)|| with x = 3, y = 4: the 3-4-5 triangle.
    # This also pins COPT's heads-first index convention: any other member
    # ordering would not solve to exactly 5.
    m =
      model do
        variable t, lb: 0.0
        variable x, lb: :neg_infinity
        variable y, lb: :neg_infinity
        constraint(x == 3, name: :px)
        constraint(y == 4, name: :py)
        constraint(norm(x, y) <= t, name: :ball)
        objective t
      end

    for backend <- commercial_backends() do
      sol = solve!(backend, m)

      assert sol.status == :optimal, "#{inspect(backend)} did not solve"
      assert_in_delta sol.objective, 5.0, 1.0e-5, "cone mismatch (#{inspect(backend)})"
    end
  end

  test "rotated cones use the 2*h1*h2 convention on every capable backend" do
    # min h1 s.t. 2*h1*h2 >= x^2, h2 = 2, x = 4: h1 = 16 / (2 * 2) = 4.
    # A backend using h1*h2 >= sum instead would return 8; the factor of 2
    # is pinned here.
    alias Optex.Model

    m = Model.new()
    {h1, m} = Model.add_variable(m, name: :h1, lb: 0.0)
    {h2, m} = Model.add_variable(m, name: :h2, lb: 0.0)
    {x, m} = Model.add_variable(m, name: :x, lb: 0.0)
    m = Model.add_constraint(m, [{:h2, 1.0}], :eq, 2.0)
    m = Model.add_constraint(m, [{:x, 1.0}], :eq, 4.0)
    m = Model.add_rotated_cone(m, h1, h2, [x], name: :rball)
    m = Model.set_objective(m, [{:h1, 1.0}], :min)

    for backend <- commercial_backends() do
      sol = solve!(backend, m)

      assert sol.status == :optimal, "#{inspect(backend)} did not solve"
      assert_in_delta sol.objective, 4.0, 1.0e-5, "rquad factor mismatch (#{inspect(backend)})"
    end
  end

  test "MISOCP: integers inside a cone" do
    # max x + y over integers with ||(x, y)|| <= r <= 5: the best lattice
    # point on the disc is (3, 4) (or (4, 3)), objective 7
    m =
      model sense: :max do
        variable x, type: :int, lb: 0.0
        variable y, type: :int, lb: 0.0
        variable r, lb: 0.0
        constraint(r <= 5, name: :radius)
        constraint(norm(x, y) <= r, name: :disc)
        objective x + y
      end

    for backend <- commercial_backends() do
      sol = solve!(backend, m)

      assert sol.status == :optimal, "#{inspect(backend)} did not solve"
      assert_in_delta sol.objective, 7.0, 1.0e-5, "MISOCP mismatch (#{inspect(backend)})"
    end
  end

  @tag :gurobi
  test "a cone in the conflict is named by the construct-aware IIS" do
    m =
      model do
        variable r, lb: 0.0, ub: 1.0
        variable x, lb: :neg_infinity
        constraint(x == 3, name: :pin)
        constraint(norm(x) <= r, name: :ball)
        objective r
      end

    {:ok, %{constructs: constructs, not_examined: not_examined}} =
      Optex.explain_infeasibility(m, solver: Solver.Gurobi)

    assert {:second_order_cone, :ball} in constructs
    assert not_examined == []
  end

  @tag :gurobi
  test "qcp_duals stays correct with a cone in the model (QCPi prefix)" do
    # one REAL qconstraint plus one cone: on Gurobi the cone is an extra
    # qconstraint internally, so this pins that the QCPi fetch returns
    # exactly the real qconstraint's dual (0.5 at the ball tangent) and
    # nothing for the cone
    m =
      model sense: :max do
        variable x, lb: 0.0
        variable y, lb: 0.0
        variable w, lb: 0.0
        variable z, lb: :neg_infinity
        constraint(x * x + y * y <= 2, name: :ball_q)
        constraint(z == 0.5, name: :pin)
        constraint(norm(z) <= w, name: :cone_w)
        objective x + y
      end

    {:ok, sol} = Optex.optimize(m, solver: Solver.Gurobi, qcp_duals: true)

    assert sol.status == :optimal
    assert map_size(sol.qcon_duals) == 1
    assert_in_delta sol.qcon_duals[:ball_q], 0.5, 1.0e-4
  end

  test "SOS1 permits one nonzero member; SOS2 enforces adjacency" do
    # without the SOS, the LP optimum is x = 3, y = 2 (objective 5);
    # sos1 allows only one nonzero, so the best single member wins: 3
    sos1_m =
      model sense: :max do
        variable x, lb: 0.0, ub: 3.0
        variable y, lb: 0.0, ub: 2.0
        constraint(sos1([{x, 1}, {y, 2}]), name: :pick)
        objective x + y
      end

    # z1 and z3 are not adjacent in weight order, so sos2 forbids the
    # unconstrained optimum z1 = z3 = 1 (objective 2); best is 1
    sos2_m =
      model sense: :max do
        variable z[i], i <- [1, 2, 3], lb: 0.0, ub: 1.0
        constraint(sos2([{z[1], 1}, {z[2], 2}, {z[3], 3}]), name: :adj)
        objective z[1] + z[3]
      end

    for backend <- commercial_backends() do
      sol = solve!(backend, sos1_m)
      assert sol.status == :optimal
      assert_in_delta sol.objective, 3.0, 1.0e-6, "sos1 mismatch (#{inspect(backend)})"

      sol = solve!(backend, sos2_m)
      assert sol.status == :optimal
      assert_in_delta sol.objective, 1.0, 1.0e-6, "sos2 mismatch (#{inspect(backend)})"
    end
  end

  @tag :gurobi
  test "an SOS in the conflict is named by the construct-aware IIS" do
    # both members are forced nonzero, which sos1 cannot allow
    m =
      model do
        variable x, lb: 0.0
        variable y, lb: 0.0
        constraint(x >= 1, name: :x_floor)
        constraint(y >= 1, name: :y_floor)
        constraint(sos1([{x, 1}, {y, 2}]), name: :pick)
        objective x + y
      end

    {:ok, %{constructs: constructs, not_examined: not_examined}} =
      Optex.explain_infeasibility(m, solver: Solver.Gurobi)

    assert {:sos, :pick} in constructs
    assert not_examined == []
  end

  @tag :gurobi
  test "the SOS firewall rejects duplicate weights without crashing the VM" do
    m =
      model sense: :max do
        variable x, lb: 0.0, ub: 3.0
        variable y, lb: 0.0, ub: 2.0
        constraint(sos1([{x, 1}, {y, 2}]), name: :pick)
        objective x + y
      end

    input = Optex.Transform.to_solver_input(m)
    [sos] = input.soss
    bad = %{input | soss: [%{sos | weights: [1.0, 1.0]}]}

    assert {:error, reason} = Solver.Gurobi.solve(bad)
    assert reason =~ "invalid sos"

    sol = solve!(Solver.Gurobi, m)
    assert sol.status == :optimal
  end

  test "abs of an expression goes through the aux variable" do
    m =
      model do
        variable x, lb: :neg_infinity
        variable y, lb: :neg_infinity
        variable d = abs(x - y)
        constraint x == 5
        constraint y == 2
        objective d
      end

    for backend <- capable_backends() do
      sol = solve!(backend, m)

      assert sol.status == :optimal
      assert_in_delta sol.objective, 3.0, 1.0e-6, "objective mismatch (#{inspect(backend)})"
      assert_in_delta sol.values[:d], 3.0, 1.0e-6
      assert_in_delta sol.values[{:d, :arg}], 3.0, 1.0e-6
    end
  end
end
