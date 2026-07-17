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
    * `:log` - `false` (default, silent), `true` (solver log to stdout), or a
      pid that receives each log line as `{:optex_highs_log, line}`
    * `:cancel` - a token from `cancel_token/0`; calling `cancel/1` on it
      from another process interrupts the running solve, which then returns
      with status `:interrupted`

  All constants and option names were verified against highs-sys 1.15.0 /
  HiGHS 1.15.0.
  """

  @behaviour Optex.Solver

  defmodule Options do
    @moduledoc false
    # Wire struct for the NIF: options pre-grouped by HiGHS value type, plus
    # the log destination pid and the cancellation token resource.
    defstruct bool_opts: [], int_opts: [], double_opts: [], log_pid: nil, cancel: nil
  end

  # VAR_TYPE_CONTINUOUS = 0, VAR_TYPE_INTEGER = 1; binary is integer with the
  # [0, 1] bounds already forced at variable creation.
  @vartype %{cont: 0, int: 1, bin: 1}

  # kHighsSolutionStatusFeasible: the dual arrays hold a meaningful solution.
  @dual_feasible 2

  @doc "Create a cancellation token to pass as the `:cancel` solve option."
  def cancel_token, do: Optex.Solver.HiGHS.Native.cancel_token()

  @doc "Ask the solve holding this token to stop at its next interrupt check."
  def cancel(token), do: Optex.Solver.HiGHS.Native.cancel(token)

  @impl true
  def solve(%Optex.SolverInput{} = input, opts \\ []) do
    with {:ok, options} <- build_options(opts) do
      prepared = prepare(input)

      case Optex.Solver.HiGHS.Native.solve(prepared, options) do
        {:ok, %Optex.SolveResult{} = result} ->
          {:ok, to_solution(result, mip?(input))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def iis(%Optex.SolverInput{} = input, _opts \\ []) do
    case Optex.Solver.HiGHS.Native.iis(prepare(input)) do
      {:ok, %Optex.IisResult{} = result} ->
        {:ok,
         %{
           variables: decode_members(result.cols, result.col_statuses),
           constraints: decode_members(result.rows, result.row_statuses)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mip?(%Optex.SolverInput{col_type: types}), do: Enum.any?(types, &(&1 in [:int, :bin]))

  defp to_solution(%Optex.SolveResult{} = r, mip?) do
    duals? = r.dual_status == @dual_feasible

    %Optex.Solution{
      status: decode_status(r.status),
      objective: r.objective,
      values: index_map(r.values),
      duals: if(duals?, do: index_map(r.row_duals)),
      reduced_costs: if(duals?, do: index_map(r.col_duals)),
      stats: %{
        solve_time: r.solve_time,
        simplex_iterations: r.simplex_iterations,
        # HiGHS reports -1 nodes and an infinite gap when there is no MIP data
        nodes: if(mip?, do: max(r.nodes, 0), else: 0),
        mip_gap: if(mip?, do: r.mip_gap)
      }
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
        obj_offset: input.obj_offset * 1.0,
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

      {:log, v}, {:ok, acc} when is_pid(v) ->
        # log lines must be generated (output_flag) but go to the callback,
        # not the console
        {:cont,
         {:ok,
          %{
            acc
            | log_pid: v,
              bool_opts: [{"output_flag", true}, {"log_to_console", false} | acc.bool_opts]
          }}}

      {:cancel, v}, {:ok, acc} when is_reference(v) ->
        {:cont, {:ok, %{acc | cancel: v}}}

      {key, v}, {:ok, _acc} when key in [:time_limit, :mip_gap, :threads, :log, :cancel] ->
        {:halt, {:error, {:invalid_option_value, key, v}}}

      {key, _v}, {:ok, _acc} ->
        {:halt, {:error, {:unknown_option, key}}}
    end)
  end

  # kHighsModelStatus values, verified against HiGHS 1.15.0 (highs-sys src):
  # 7 = optimal, 8 = infeasible, 9 = unbounded-or-infeasible, 10 = unbounded,
  # 13 = reached time limit, 17 = reached interrupt (cancellation).
  defp decode_status(7), do: :optimal
  defp decode_status(8), do: :infeasible
  defp decode_status(9), do: :unbounded_or_infeasible
  defp decode_status(10), do: :unbounded
  defp decode_status(13), do: :time_limit
  defp decode_status(17), do: :interrupted
  defp decode_status(other), do: {:other, other}

  # IisBoundStatus, verified against HiGHS 1.15.0 (HighsIis.h):
  # -1 dropped, 0 null, 1 free, 2 lower, 3 upper, 4 boxed.
  defp decode_members(indices, statuses) do
    Enum.zip_with(indices, statuses, fn i, s -> {i, decode_bound_status(s)} end)
  end

  defp decode_bound_status(-1), do: :dropped
  defp decode_bound_status(0), do: :none
  defp decode_bound_status(1), do: :free
  defp decode_bound_status(2), do: :lower
  defp decode_bound_status(3), do: :upper
  defp decode_bound_status(4), do: :boxed
  defp decode_bound_status(other), do: {:other, other}

  defp index_map(list) do
    list
    |> Enum.with_index()
    |> Map.new(fn {v, id} -> {id, v} end)
  end
end
