defmodule Optex.Solver.CPLEX do
  @moduledoc """
  CPLEX backend. Implements the same `Optex.Solver` contract as the HiGHS
  and Gurobi backends and accepts the same neutral options; use it with
  `Optex.optimize(m, solver: Optex.Solver.CPLEX)`.

  Requires an installed, licensed CPLEX Studio: the native crate is
  compile-gated on the versioned `CPLEX_STUDIO_DIR*` env var (check
  `available?/0`). All constants and parameter ids were verified against
  CPLEX 22.1.1's cplex.h/cpxconst.h.

  Supported options (same set as the other backends): `:time_limit`,
  `:mip_gap`, `:threads`, `:log` (`false` | `true` | pid receiving
  `{:optex_cplex_log, line}`), `:cancel` (token from `cancel_token/0`).

  Unlike the Gurobi backend, genuine two-sided range rows are supported
  natively (CPLEX sense 'R').
  """

  @behaviour Optex.Solver

  defmodule Options do
    @moduledoc false
    # Wire struct for the NIF: numeric CPLEX parameter ids grouped by type.
    defstruct int_params: [], dbl_params: [], log_pid: nil, cancel: nil
  end

  # Mapped to ctype chars in Rust: 0 -> 'C', 1 -> 'I', 2 -> 'B'.
  @vartype %{cont: 0, int: 1, bin: 2}

  # CPLEX parameter ids, verified against cpxconst.h 22.1.1.
  @param_tilim 1039
  @param_epgap 2009
  @param_threads 1067
  @param_scrind 1035

  @dual_feasible 2

  @doc "Whether the native CPLEX binding was compiled (CPLEX_STUDIO_DIR* at build)."
  def available?, do: Optex.Solver.CPLEX.Native.available?()

  @doc "Create a cancellation token to pass as the `:cancel` solve option."
  def cancel_token, do: Optex.Solver.CPLEX.Native.cancel_token()

  @doc "Ask the solve holding this token to terminate."
  def cancel(token), do: Optex.Solver.CPLEX.Native.cancel(token)

  # All general constraints map to native CPLEX constructs: indicators via
  # CPXaddindconstr, abs and pwl via CPXaddpwl (pre/post slopes computed
  # from the first/last segments); quadratic objectives (convex, incl. MIQP)
  # via CPXcopyquad and the QP optimizer; quadratic constraints (convex,
  # <=/>= only, barrier optimizer) via CPXaddqconstr. Quadratic EQUALITY
  # constraints are a CPLEX limitation and rejected below.
  @impl true
  def capabilities,
    do: [:indicator, :abs, :pwl, :sos, :quadratic_objective, :quadratic_constraint]

  # Native calls go through apply/3: in the stub build the type checker
  # would otherwise prove the {:ok, ...} clauses unreachable and fail
  # --warnings-as-errors.
  @impl true
  def solve(%Optex.SolverInput{} = input, opts \\ []) do
    with :ok <- check_capabilities(input),
         :ok <- check_quadratic_equality(input),
         {:ok, options} <- build_options(opts) do
      case apply(Optex.Solver.CPLEX.Native, :solve, [prepare(input), options]) do
        {:ok, %Optex.SolveResult{} = result} ->
          {:ok, to_solution(result, mip?(input))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def iis(%Optex.SolverInput{} = input, _opts \\ []) do
    case apply(Optex.Solver.CPLEX.Native, :iis, [prepare(input)]) do
      {:ok, %Optex.IisResult{} = result} ->
        {:ok,
         %{
           variables: decode_members(result.cols, result.col_statuses),
           constraints: decode_members(result.rows, result.row_statuses),
           # always empty here: the conflict refiner reports rows/cols only
           constructs: %{
             indicator: result.indicators,
             abs: result.abs_defs,
             min_max: result.minmax_defs,
             pwl: result.pwl_defs,
             quadratic_constraint: result.qconstraints,
             second_order_cone: result.cones,
             sos: result.soss
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # CPLEX advertised every capability until :min_max (Gurobi-only) arrived;
  # the generic check keeps rejections uniform and pre-NIF.
  defp check_capabilities(input) do
    case Optex.SolverInput.required_capabilities(input) -- capabilities() do
      [] -> :ok
      [cap | _] -> {:error, {:unsupported, cap, __MODULE__}}
    end
  end

  # CPXaddqconstr accepts only 'L' and 'G'; quadratic equality does not
  # exist in CPLEX (Gurobi supports it as a nonconvex constraint)
  defp check_quadratic_equality(%Optex.SolverInput{qconstraints: qcs}) do
    if Enum.any?(qcs, &(&1.sense == :eq)) do
      {:error, {:unsupported, :quadratic_equality_constraint, __MODULE__}}
    else
      :ok
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
        nodes: if(mip?, do: max(r.nodes, 0), else: 0),
        mip_gap: if(mip?, do: r.mip_gap)
      }
    }
  end

  defp prepare(%Optex.SolverInput{} = input) do
    %{
      input
      | col_type: Enum.map(input.col_type, &Map.fetch!(@vartype, &1)),
        obj: Enum.map(input.obj, &(&1 * 1.0)),
        obj_offset: input.obj_offset * 1.0,
        values: Enum.map(input.values, &(&1 * 1.0)),
        q_vals: Enum.map(input.q_vals, &(&1 * 1.0))
    }
  end

  # Neutral option names to CPLEX numeric parameter ids.
  defp build_options(opts) do
    Enum.reduce_while(opts, {:ok, %Options{}}, fn
      {:time_limit, v}, {:ok, acc} when is_number(v) and v > 0 ->
        {:cont, {:ok, %{acc | dbl_params: [{@param_tilim, v * 1.0} | acc.dbl_params]}}}

      {:mip_gap, v}, {:ok, acc} when is_number(v) and v >= 0 ->
        {:cont, {:ok, %{acc | dbl_params: [{@param_epgap, v * 1.0} | acc.dbl_params]}}}

      {:threads, v}, {:ok, acc} when is_integer(v) and v > 0 ->
        {:cont, {:ok, %{acc | int_params: [{@param_threads, v} | acc.int_params]}}}

      {:log, v}, {:ok, acc} when is_boolean(v) ->
        {:cont,
         {:ok, %{acc | int_params: [{@param_scrind, if(v, do: 1, else: 0)} | acc.int_params]}}}

      {:log, v}, {:ok, acc} when is_pid(v) ->
        # channel function destinations receive messages regardless of the
        # screen indicator, so the console stays silent
        {:cont, {:ok, %{acc | log_pid: v}}}

      {:cancel, v}, {:ok, acc} when is_reference(v) ->
        {:cont, {:ok, %{acc | cancel: v}}}

      # the CPLEX C API exposes qconstraint slacks but no dual multipliers,
      # so requesting QCP duals is strictly unsupported; off is a no-op
      {:qcp_duals, false}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {:qcp_duals, true}, {:ok, _acc} ->
        {:halt, {:error, {:unsupported, :qcp_duals, __MODULE__}}}

      {key, v}, {:ok, _acc}
      when key in [:time_limit, :mip_gap, :threads, :log, :cancel, :qcp_duals] ->
        {:halt, {:error, {:invalid_option_value, key, v}}}

      {key, _v}, {:ok, _acc} ->
        {:halt, {:error, {:unknown_option, key}}}
    end)
  end

  # CPXgetstat codes, verified against cpxconst.h 22.1.1. The LP
  # (CPX_STAT_*) and MIP (CPXMIP_*) tables are disjoint, so one decode
  # covers both. 102 is optimal within the gap tolerance; 107/108 hit the
  # time limit with/without an incumbent; 113/114 aborted likewise.
  defp decode_status(1), do: :optimal
  defp decode_status(2), do: :unbounded
  defp decode_status(3), do: :infeasible
  defp decode_status(4), do: :unbounded_or_infeasible
  defp decode_status(11), do: :time_limit
  defp decode_status(13), do: :interrupted
  defp decode_status(101), do: :optimal
  defp decode_status(102), do: :optimal
  defp decode_status(103), do: :infeasible
  defp decode_status(107), do: :time_limit
  defp decode_status(108), do: :time_limit
  defp decode_status(113), do: :interrupted
  defp decode_status(114), do: :interrupted
  defp decode_status(118), do: :unbounded
  defp decode_status(119), do: :unbounded_or_infeasible
  defp decode_status(other), do: {:other, other}

  # shared member-status ints: 2 lower, 3 upper, 4 boxed
  defp decode_members(indices, statuses) do
    Enum.zip_with(indices, statuses, fn i, s -> {i, decode_bound_status(s)} end)
  end

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
