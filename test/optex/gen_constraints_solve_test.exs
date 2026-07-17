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
