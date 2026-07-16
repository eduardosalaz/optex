defmodule Optex.MPSTest do
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{MPS, Transform}

  @moduletag :oracle
  @moduletag :tmp_dir

  # Solve an MPS document with the standalone HiGHS binary; return
  # {status_string, objective_float_or_nil} parsed from the solution file,
  # whose format is uniform across LP and MIP (stdout summaries differ).
  defp oracle_solve(iodata, tmp_dir) do
    exe = Application.fetch_env!(:optex, :highs_exe)
    path = Path.join(tmp_dir, "model.mps")
    sol_path = Path.join(tmp_dir, "model.sol")
    File.write!(path, iodata)

    {_out, 0} = System.cmd(exe, ["--solution_file", sol_path, path], stderr_to_stdout: true)

    sol = File.read!(sol_path)
    [_, status] = Regex.run(~r/Model status\s*\r?\n(\w+)/, sol)

    obj =
      case Regex.run(~r/Objective\s+([-+0-9.eE]+)/, sol) do
        [_, s] -> parse_number(s)
        nil -> nil
      end

    {status, obj}
  end

  defp parse_number(s) do
    case Float.parse(s) do
      {f, ""} -> f
      _ -> raise "unparsable objective: #{s}"
    end
  end

  test "LP: max x + y with two constraints", %{tmp_dir: tmp_dir} do
    m =
      model sense: :max do
        variable x, lb: 0.0
        variable y, lb: 0.0
        constraint x + 2 * y <= 4
        constraint 3 * x + y <= 6
        objective x + y
      end

    {status, obj} = m |> Transform.to_solver_input() |> MPS.emit() |> oracle_solve(tmp_dir)

    assert status == "Optimal"
    # optimum at x = 8/5, y = 6/5
    assert_in_delta obj, 2.8, 1.0e-6
  end

  test "MILP: integrality forces rounding up", %{tmp_dir: tmp_dir} do
    m =
      model sense: :min do
        variable x, type: :int, lb: 0.0
        constraint x >= 2.5
        objective x
      end

    {status, obj} = m |> Transform.to_solver_input() |> MPS.emit() |> oracle_solve(tmp_dir)

    assert status == "Optimal"
    assert_in_delta obj, 3.0, 1.0e-6
  end

  test "binary knapsack with an equality row", %{tmp_dir: tmp_dir} do
    m =
      model sense: :max do
        variable p, type: :bin
        variable q, type: :bin
        constraint p + q == 1
        objective 2 * p + q
      end

    {status, obj} = m |> Transform.to_solver_input() |> MPS.emit() |> oracle_solve(tmp_dir)

    assert status == "Optimal"
    assert_in_delta obj, 2.0, 1.0e-6
  end

  test "infeasible model is reported infeasible by the oracle", %{tmp_dir: tmp_dir} do
    m =
      model do
        variable x, lb: 0.0, ub: 1.0
        constraint x >= 2
        objective x
      end

    {status, _obj} = m |> Transform.to_solver_input() |> MPS.emit() |> oracle_solve(tmp_dir)

    assert status == "Infeasible"
  end
end
