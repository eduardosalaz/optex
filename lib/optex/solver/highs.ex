defmodule Optex.Solver.HiGHS do
  @moduledoc """
  HiGHS backend. Maps neutral variable types to HiGHS vartype ints and decodes
  HiGHS model-status codes; symbolic :infinity bounds pass through to the NIF,
  which substitutes HiGHS's own infinity value (see DECISIONS.md).

  All constants below were verified against highs-sys 1.15.0 / HiGHS 1.15.0.
  """

  @behaviour Optex.Solver

  # VAR_TYPE_CONTINUOUS = 0, VAR_TYPE_INTEGER = 1; binary is integer with the
  # [0, 1] bounds already forced at variable creation.
  @vartype %{cont: 0, int: 1, bin: 1}

  @impl true
  def solve(%Optex.SolverInput{} = input, _opts \\ []) do
    prepared = prepare(input)

    case Optex.Solver.HiGHS.Native.solve(prepared) do
      {:ok, %Optex.SolveResult{status: st, objective: obj, values: vals}} ->
        {:ok,
         %Optex.Solution{
           status: decode_status(st),
           objective: obj,
           values: index_values(input, vals)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Map neutral types to HiGHS ints and force float coefficient arrays (the
  # NIF decodes them as f64). Bounds stay symbolic; the NIF substitutes
  # HiGHS's infinity so no solver constant appears on the Elixir side.
  defp prepare(%Optex.SolverInput{} = input) do
    %{
      input
      | col_type: Enum.map(input.col_type, &Map.fetch!(@vartype, &1)),
        obj: Enum.map(input.obj, &(&1 * 1.0)),
        values: Enum.map(input.values, &(&1 * 1.0))
    }
  end

  # kHighsModelStatus values, verified against HiGHS 1.15.0 (highs-sys src):
  # 7 = optimal, 8 = infeasible, 9 = unbounded-or-infeasible, 10 = unbounded.
  defp decode_status(7), do: :optimal
  defp decode_status(8), do: :infeasible
  defp decode_status(9), do: :unbounded_or_infeasible
  defp decode_status(10), do: :unbounded
  defp decode_status(other), do: {:other, other}

  defp index_values(%Optex.SolverInput{}, vals) do
    vals
    |> Enum.with_index()
    |> Map.new(fn {v, id} -> {id, v} end)
  end
end
