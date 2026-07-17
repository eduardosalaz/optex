defmodule Optex.Solver.HiGHS do
  @moduledoc """
  HiGHS backend. Maps neutral variable types to HiGHS vartype ints, translates
  neutral solver options to HiGHS option names, and decodes HiGHS status
  codes; symbolic :infinity bounds pass through to the NIF, which substitutes
  HiGHS's own infinity value (see DECISIONS.md).

  Supported options (anything else returns `{:error, {:unknown_option, key}}`):

    * `:time_limit` - wall-clock limit in seconds (number)
    * `:mip_gap` - relative MIP gap tolerance (number)
    * `:threads` - number of solver threads (positive integer)
    * `:log` - enable solver logging to stdout (boolean, default false)

  All constants and option names were verified against highs-sys 1.15.0 /
  HiGHS 1.15.0.
  """

  @behaviour Optex.Solver

  defmodule Options do
    @moduledoc false
    # Wire struct for the NIF: options pre-grouped by HiGHS value type.
    defstruct bool_opts: [], int_opts: [], double_opts: []
  end

  # VAR_TYPE_CONTINUOUS = 0, VAR_TYPE_INTEGER = 1; binary is integer with the
  # [0, 1] bounds already forced at variable creation.
  @vartype %{cont: 0, int: 1, bin: 1}

  # kHighsSolutionStatusFeasible: the dual arrays hold a meaningful solution.
  @dual_feasible 2

  @impl true
  def solve(%Optex.SolverInput{} = input, opts \\ []) do
    with {:ok, options} <- build_options(opts) do
      prepared = prepare(input)

      case Optex.Solver.HiGHS.Native.solve(prepared, options) do
        {:ok, %Optex.SolveResult{} = result} ->
          {:ok, to_solution(result)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp to_solution(%Optex.SolveResult{} = r) do
    duals? = r.dual_status == @dual_feasible

    %Optex.Solution{
      status: decode_status(r.status),
      objective: r.objective,
      values: index_map(r.values),
      duals: if(duals?, do: index_map(r.row_duals)),
      reduced_costs: if(duals?, do: index_map(r.col_duals))
    }
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

  # Neutral option names to HiGHS option names, grouped by value type.
  defp build_options(opts) do
    Enum.reduce_while(opts, {:ok, %Options{}}, fn
      {:time_limit, v}, {:ok, acc} when is_number(v) and v > 0 ->
        {:cont, {:ok, %{acc | double_opts: [{"time_limit", v * 1.0} | acc.double_opts]}}}

      {:mip_gap, v}, {:ok, acc} when is_number(v) and v >= 0 ->
        {:cont, {:ok, %{acc | double_opts: [{"mip_rel_gap", v * 1.0} | acc.double_opts]}}}

      {:threads, v}, {:ok, acc} when is_integer(v) and v > 0 ->
        {:cont, {:ok, %{acc | int_opts: [{"threads", v} | acc.int_opts]}}}

      {:log, v}, {:ok, acc} when is_boolean(v) ->
        {:cont, {:ok, %{acc | bool_opts: [{"output_flag", v} | acc.bool_opts]}}}

      {key, v}, {:ok, _acc} when key in [:time_limit, :mip_gap, :threads, :log] ->
        {:halt, {:error, {:invalid_option_value, key, v}}}

      {key, _v}, {:ok, _acc} ->
        {:halt, {:error, {:unknown_option, key}}}
    end)
  end

  # kHighsModelStatus values, verified against HiGHS 1.15.0 (highs-sys src):
  # 7 = optimal, 8 = infeasible, 9 = unbounded-or-infeasible, 10 = unbounded,
  # 13 = reached time limit.
  defp decode_status(7), do: :optimal
  defp decode_status(8), do: :infeasible
  defp decode_status(9), do: :unbounded_or_infeasible
  defp decode_status(10), do: :unbounded
  defp decode_status(13), do: :time_limit
  defp decode_status(other), do: {:other, other}

  defp index_map(list) do
    list
    |> Enum.with_index()
    |> Map.new(fn {v, id} -> {id, v} end)
  end
end
