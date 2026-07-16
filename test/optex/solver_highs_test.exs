defmodule Optex.Solver.HiGHSTest do
  use ExUnit.Case, async: true

  import Optex.DSL

  alias Optex.{MPS, Solution, Solver, Transform}

  defp solve!(model) do
    {:ok, %Solution{} = sol} = model |> Transform.to_solver_input() |> Solver.HiGHS.solve()
    sol
  end

  defp lp_model do
    model sense: :max do
      variable x, lb: 0.0
      variable y, lb: 0.0
      constraint x + 2 * y <= 4
      constraint 3 * x + y <= 6
      objective x + y
    end
  end

  defp milp_model do
    model sense: :min do
      variable x, type: :int, lb: 0.0
      constraint x >= 2.5
      objective x
    end
  end

  defp binary_model do
    model sense: :max do
      variable p, type: :bin
      variable q, type: :bin
      constraint p + q == 1
      objective 2 * p + q
    end
  end

  test "tiny LP solves to the known optimum with correct primal values" do
    sol = solve!(lp_model())

    assert sol.status == :optimal
    # optimum at x = 8/5, y = 6/5, objective 14/5
    assert_in_delta sol.objective, 2.8, 1.0e-6
    assert_in_delta sol.values[0], 1.6, 1.0e-6
    assert_in_delta sol.values[1], 1.2, 1.0e-6
  end

  test "tiny MILP respects integrality and finds the known optimum" do
    sol = solve!(milp_model())

    assert sol.status == :optimal
    assert_in_delta sol.objective, 3.0, 1.0e-6
    assert_in_delta sol.values[0], 3.0, 1.0e-6
    # integrality of the reported value
    assert_in_delta sol.values[0], Float.round(sol.values[0]), 1.0e-9
  end

  test "binary model solves with integral 0/1 values" do
    sol = solve!(binary_model())

    assert sol.status == :optimal
    assert_in_delta sol.objective, 2.0, 1.0e-6
    assert_in_delta sol.values[0], 1.0, 1.0e-9
    assert_in_delta sol.values[1], 0.0, 1.0e-9
  end

  test "infeasible model returns :infeasible" do
    m =
      model do
        variable x, lb: 0.0, ub: 1.0
        constraint x >= 2
        objective x
      end

    sol = solve!(m)
    assert sol.status == :infeasible
  end

  test "unbounded model returns :unbounded" do
    m =
      model sense: :max do
        variable x, lb: 0.0
        objective x
      end

    sol = solve!(m)
    assert sol.status == :unbounded
  end

  test "unbounded variables below use :neg_infinity bounds through the NIF" do
    # min x with x free and x >= -7 as a row: bound substitution must let the
    # solver push x to the row bound, not to a fake numeric bound
    m =
      model do
        variable x, lb: :neg_infinity
        constraint x >= -7
        objective x
      end

    sol = solve!(m)
    assert sol.status == :optimal
    assert_in_delta sol.objective, -7.0, 1.0e-6
  end

  @tag :oracle
  @tag :tmp_dir
  test "NIF path and MPS oracle agree on the objective", %{tmp_dir: tmp_dir} do
    for {name, m} <- [lp: lp_model(), milp: milp_model(), binary: binary_model()] do
      si = Transform.to_solver_input(m)

      {:ok, %Solution{status: :optimal, objective: nif_obj}} = Solver.HiGHS.solve(si)
      {"Optimal", oracle_obj} = oracle_solve(MPS.emit(si), tmp_dir, name)

      assert_in_delta nif_obj, oracle_obj, 1.0e-6, "NIF and MPS oracle disagree on #{name}"
    end
  end

  test "malformed input is rejected by the length firewall without crashing the VM" do
    si = Transform.to_solver_input(lp_model())

    # obj shorter than num_vars
    assert {:error, reason} = Solver.HiGHS.solve(%{si | obj: [1.0]})
    assert reason =~ "length mismatch"

    # col_start inconsistent with nnz
    assert {:error, _} = Solver.HiGHS.solve(%{si | col_start: [0, 1, 2]})

    # row bounds shorter than num_cons
    assert {:error, _} = Solver.HiGHS.solve(%{si | row_lb: []})

    # the scheduler thread and VM survived: a normal solve still works
    assert %Solution{status: :optimal} = solve!(lp_model())
  end

  defp oracle_solve(iodata, tmp_dir, name) do
    exe = Application.fetch_env!(:optex, :highs_exe)
    path = Path.join(tmp_dir, "#{name}.mps")
    sol_path = Path.join(tmp_dir, "#{name}.sol")
    File.write!(path, iodata)

    {_out, 0} = System.cmd(exe, ["--solution_file", sol_path, path], stderr_to_stdout: true)

    sol = File.read!(sol_path)
    [_, status] = Regex.run(~r/Model status\s*\r?\n(\w+)/, sol)
    [_, obj] = Regex.run(~r/Objective\s+([-+0-9.eE]+)/, sol)
    {f, ""} = Float.parse(obj)
    {status, f}
  end
end
