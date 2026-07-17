defmodule Optex.LPFormatTest do
  # Optex.LP emitter and Optex.Format pretty-printer.
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{Format, LP, Solution, Solver, Transform}

  defp mixed_model do
    model sense: :max do
      variable x, lb: 0.0
      variable y[i], i <- [1, 2], lb: 0.0, ub: 3.0
      variable pick, type: :bin
      variable n, type: :int, lb: 0.0, ub: 10.0

      constraint(x + y[1] + y[2] <= 8, name: :budget)
      constraint x - pick <= 4
      constraint(n >= 2, name: {:min_n, 1})

      objective x + 2 * y[1] + 1.5 * y[2] + 5 * pick + n
    end
  end

  describe "Optex.LP.emit/1" do
    test "emits the expected sections with sanitized names" do
      text = mixed_model() |> LP.emit() |> IO.iodata_to_binary()

      assert text =~ "Maximize"
      assert text =~ "Subject To"
      # y[1] sanitizes to y_1; the named constraints keep their names
      assert text =~ ~r/budget: .*x.*y_1.*y_2.*<= 8/
      assert text =~ "min_n_1:"
      # unnamed constraint falls back to c<id>
      assert text =~ "c1:"
      assert text =~ "Binary"
      assert text =~ "General"
      assert text =~ "End"
    end

    test "free and one-sided bounds render correctly" do
      m =
        model do
          variable f, lb: :neg_infinity, ub: :infinity
          variable below, lb: :neg_infinity, ub: 2.0
          variable above, lb: 3.0
          constraint f + below + above >= 0
          objective f + below + above
        end

      text = m |> LP.emit() |> IO.iodata_to_binary()

      assert text =~ " f free"
      assert text =~ "-infinity <= below <= 2"
      assert text =~ " above >= 3"
    end

    @tag :oracle
    @tag :tmp_dir
    test "the standalone solver reads the LP file and agrees with the NIF", %{tmp_dir: tmp_dir} do
      for {label, m} <- [mixed: mixed_model(), offset: offset_model()] do
        {:ok, %Solution{status: :optimal, objective: nif_obj}} =
          m |> Transform.to_solver_input() |> Solver.HiGHS.solve()

        path = Path.join(tmp_dir, "#{label}.lp")
        sol_path = Path.join(tmp_dir, "#{label}.sol")
        File.write!(path, LP.emit(m))

        exe = Application.fetch_env!(:optex, :highs_exe)
        {_out, 0} = System.cmd(exe, ["--solution_file", sol_path, path], stderr_to_stdout: true)

        sol = File.read!(sol_path)
        assert [_, "Optimal"] = Regex.run(~r/Model status\s*\r?\n(\w+)/, sol)
        [_, obj] = Regex.run(~r/Objective\s+([-+0-9.eE]+)/, sol)
        {oracle_obj, ""} = Float.parse(obj)

        assert_in_delta nif_obj, oracle_obj, 1.0e-6, "LP oracle disagrees on #{label}"
      end
    end
  end

  defp offset_model do
    model sense: :min do
      variable x, lb: 0.0
      constraint x >= 2
      objective 3 * x + 5
    end
  end

  describe "Optex.Format.pretty/1" do
    test "renders objective, named rows, and bounds with user-facing names" do
      text = Format.pretty(mixed_model())

      assert text =~ "max x + 2 y[1] + 1.5 y[2] + 5 pick + n"
      assert text =~ "budget: x + y[1] + y[2] <= 8"
      assert text =~ "c1: x - pick <= 4"
      assert text =~ "min_n[1]: n >= 2"
      assert text =~ "pick binary"
      assert text =~ "n integer in [0, 10]"
      assert text =~ "y[1] in [0, 3]"
      assert text =~ "x >= 0"
    end

    test "renders the objective constant and free variables" do
      m =
        model do
          variable x, lb: :neg_infinity, ub: :infinity
          constraint x >= -3
          objective 2 * x + 7
        end

      text = Format.pretty(m)

      assert text =~ "min 2 x + 7"
      assert text =~ "x free"
    end
  end
end
