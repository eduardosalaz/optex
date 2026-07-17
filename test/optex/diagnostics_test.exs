defmodule Optex.DiagnosticsTest do
  # Stats, log streaming, cancellation, IIS, and the objective constant.
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{Solution, Solver}

  describe "solve statistics" do
    test "an LP reports time and iterations; nodes 0 and no mip gap" do
      m =
        model sense: :max do
          variable x, lb: 0.0
          variable y, lb: 0.0
          constraint x + 2 * y <= 4
          constraint 3 * x + y <= 6
          objective x + y
        end

      {:ok, %Solution{stats: stats}} = Optex.optimize(m)

      assert stats.solve_time >= 0.0
      assert is_integer(stats.simplex_iterations) and stats.simplex_iterations >= 0
      assert stats.nodes == 0
      assert stats.mip_gap == nil
    end

    test "a MIP reports a numeric gap and a node count" do
      m =
        model sense: :min do
          variable x, type: :int, lb: 0.0
          constraint x >= 2.5
          objective x
        end

      {:ok, %Solution{stats: stats}} = Optex.optimize(m)

      assert is_number(stats.mip_gap)
      assert is_integer(stats.nodes) and stats.nodes >= 0
    end
  end

  describe "objective constant" do
    test "the constant term reaches the reported objective" do
      m =
        model sense: :min do
          variable x, lb: 2.0
          objective x + 5
        end

      {:ok, sol} = Optex.optimize(m)
      assert_in_delta sol.objective, 7.0, 1.0e-6
    end
  end

  describe "log streaming" do
    test "log: pid streams solver log lines as messages" do
      m =
        model sense: :max do
          variable x, lb: 0.0, ub: 3.0
          objective x
        end

      {:ok, %Solution{status: :optimal}} = Optex.optimize(m, log: self())

      assert_receive {:optex_highs_log, line}, 2_000
      assert is_binary(line)
    end
  end

  describe "cancellation" do
    test "a pre-cancelled token interrupts the solve" do
      # enough structure that HiGHS reaches an interrupt check before solving
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

      token = Solver.HiGHS.cancel_token()
      :ok = Solver.HiGHS.cancel(token)

      {:ok, sol} = Optex.optimize(m, cancel: token)
      assert sol.status == :interrupted
    end

    test "an uncancelled token does not disturb the solve" do
      m =
        model do
          variable x, lb: 1.0
          objective x
        end

      token = Solver.HiGHS.cancel_token()

      {:ok, sol} = Optex.optimize(m, cancel: token)
      assert sol.status == :optimal
      assert_in_delta sol.objective, 1.0, 1.0e-6
    end
  end

  describe "infeasibility explanation" do
    test "the IIS names the conflicting constraints" do
      m =
        model do
          variable x, lb: 0.0
          variable y, lb: 0.0
          constraint(x >= 3, name: :needs_lots)
          constraint(x <= 1, name: :allows_little)
          # an unrelated satisfiable row must not appear in the IIS
          constraint(y <= 5, name: :innocent)
          objective x + y
        end

      {:ok, %{constraints: cons}} = Optex.explain_infeasibility(m)

      names = Enum.map(cons, fn {name, _status} -> name end)
      assert :needs_lots in names
      assert :allows_little in names
      refute :innocent in names
    end

    test "a variable bound in conflict shows up under variables" do
      m =
        model do
          variable x, lb: 0.0, ub: 1.0
          constraint(x >= 3, name: :too_demanding)
          objective x
        end

      {:ok, %{constraints: cons, variables: vars}} = Optex.explain_infeasibility(m)

      assert Enum.any?(cons, fn {name, _} -> name == :too_demanding end)
      assert Enum.any?(vars, fn {name, _} -> name == :x end)
    end

    test "a feasible model yields an empty IIS" do
      m =
        model do
          variable x, lb: 0.0
          constraint x <= 5
          objective x
        end

      assert {:ok, %{constraints: [], variables: []}} = Optex.explain_infeasibility(m)
    end

    test "a backend without iis support returns :not_supported" do
      defmodule NoIisSolver do
        @behaviour Optex.Solver
        @impl true
        def solve(_input, _opts), do: {:error, :boom}
      end

      m =
        model do
          variable x
          objective x
        end

      assert {:error, :not_supported} = Optex.explain_infeasibility(m, solver: NoIisSolver)
    end
  end
end
