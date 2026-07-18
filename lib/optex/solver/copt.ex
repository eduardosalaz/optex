defmodule Optex.Solver.COPT do
  @moduledoc """
  COPT (Cardinal Optimizer) backend. Implements the same `Optex.Solver`
  contract as the other backends and accepts the same neutral options; use
  it with `Optex.optimize(m, solver: Optex.Solver.COPT)`.

  Requires an installed, licensed COPT: the native crate is compile-gated
  on `COPT_HOME` (check `available?/0`). All constants, attribute names,
  and parameter names were verified against COPT 8.0.5's copt.h (and are
  byte-identical to 7.2.11's, where they were first verified).

  Supported options: `:time_limit`, `:mip_gap`, `:threads`, `:log`
  (`false` | `true` | pid receiving `{:optex_copt_log, line}`), `:cancel`
  (token from `cancel_token/0`). `qcp_duals: true` is rejected as
  unsupported: COPT's C API exposes quadratic constraint slacks but no dual
  multipliers (`COPT_GetQConstrInfo` rejects the "Dual" info name), so QCP
  duals remain Gurobi-only.

  Capabilities: indicator constraints, convex quadratic objectives
  (including MIQP), and convex quadratic constraints (`<=`/`>=` only, like
  CPLEX). No abs/pwl/min-max general constraints: COPT has no native
  equivalents, and constructs are never reformulated.
  """

  @behaviour Optex.Solver

  defmodule Options do
    @moduledoc false
    # Wire struct for the NIF: string-named params pre-grouped by value
    # type (COPT params are set on the problem). qcp_duals asks the NIF to
    # fetch quadratic constraint duals after a continuous solve.
    defstruct int_params: [],
              dbl_params: [],
              log_pid: nil,
              cancel: nil,
              qcp_duals: false,
              progress_pid: nil,
              progress_every_ms: 1000,
              incumbent_pid: nil
  end

  # Mapped to vtype chars in Rust: 0 -> 'C', 1 -> 'I', 2 -> 'B'
  # (COPT_CONTINUOUS/COPT_INTEGER/COPT_BINARY, copt.h:54-56).
  @vartype %{cont: 0, int: 1, bin: 2}

  @dual_feasible 2

  @doc "Whether the native COPT binding was compiled (COPT_HOME at build)."
  def available?, do: Optex.Solver.COPT.Native.available?()

  @doc "Create a cancellation token to pass as the `:cancel` solve option."
  def cancel_token, do: Optex.Solver.COPT.Native.cancel_token()

  @doc "Ask the solve holding this token to terminate."
  def cancel(token), do: Optex.Solver.COPT.Native.cancel(token)

  # Indicators map onto COPT_AddIndicator; quadratic objectives (convex,
  # incl. MIQP) onto COPT_SetQuadObj; quadratic constraints (convex, <=/>=
  # only) onto COPT_AddQConstr. abs/pwl/min-max have no COPT equivalent:
  # the nonlinear-expression API does carry an abs opcode, but it is a
  # LOCAL solver (COPT_STATUS_LOCAL_OPTIMAL; probed empirically) and would
  # break the exact-even-when-maximized contract. See DECISIONS.md.
  @impl true
  def capabilities,
    do: [:indicator, :sos, :second_order_cone, :quadratic_objective, :quadratic_constraint]

  # Native calls go through apply/3: in the COPT_HOME-less stub build the
  # type checker would otherwise prove the {:ok, ...} clauses unreachable
  # and fail --warnings-as-errors.
  @impl true
  def solve(%Optex.SolverInput{} = input, opts \\ []) do
    with :ok <- check_capabilities(input),
         :ok <- check_quadratic_equality(input),
         {:ok, options} <- build_options(opts) do
      case apply(Optex.Solver.COPT.Native, :solve, [prepare(input), options]) do
        {:ok, %Optex.SolveResult{} = result} ->
          {:ok, to_solution(result, mip?(input))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def iis(%Optex.SolverInput{} = input, _opts \\ []) do
    case apply(Optex.Solver.COPT.Native, :iis, [prepare(input)]) do
      {:ok, %Optex.IisResult{} = result} ->
        {:ok,
         %{
           variables: decode_members(result.cols, result.col_statuses),
           constraints: decode_members(result.rows, result.row_statuses),
           # always empty here: COPT's IIS reports rows/cols only
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

  defp check_capabilities(input) do
    case Optex.SolverInput.required_capabilities(input) -- capabilities() do
      [] -> :ok
      [cap | _] -> {:error, {:unsupported, cap, __MODULE__}}
    end
  end

  # COPT's quadratic constraints are convex <=/>= only (like CPLEX); an
  # equality would need the nonconvex machinery this backend does not
  # enable, so it is rejected pre-NIF with the shared reason
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
      status: decode_status(r.status, mip?),
      objective: r.objective,
      values: index_map(r.values),
      duals: if(duals?, do: index_map(r.row_duals)),
      reduced_costs: if(duals?, do: index_map(r.col_duals)),
      qcon_duals: if(r.qcon_duals, do: index_map(r.qcon_duals)),
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

  # Neutral option names to COPT parameter names (verified against 8.0.5).
  defp build_options(opts) do
    Enum.reduce_while(opts, {:ok, %Options{}}, fn
      {:time_limit, v}, {:ok, acc} when is_number(v) and v > 0 ->
        {:cont, {:ok, %{acc | dbl_params: [{"TimeLimit", v * 1.0} | acc.dbl_params]}}}

      {:mip_gap, v}, {:ok, acc} when is_number(v) and v >= 0 ->
        {:cont, {:ok, %{acc | dbl_params: [{"RelGap", v * 1.0} | acc.dbl_params]}}}

      {:threads, v}, {:ok, acc} when is_integer(v) and v > 0 ->
        {:cont, {:ok, %{acc | int_params: [{"Threads", v} | acc.int_params]}}}

      {:log, v}, {:ok, acc} when is_boolean(v) ->
        {:cont, {:ok, %{acc | int_params: [{"Logging", if(v, do: 1, else: 0)} | acc.int_params]}}}

      {:log, v}, {:ok, acc} when is_pid(v) ->
        # log lines must be generated but go to the callback, not the
        # console; LogToConsole is applied first so enabling Logging does
        # not echo the parameter change to the console
        {:cont,
         {:ok,
          %{
            acc
            | log_pid: v,
              int_params: [{"LogToConsole", 0}, {"Logging", 1} | acc.int_params]
          }}}

      {:cancel, v}, {:ok, acc} when is_reference(v) ->
        {:cont, {:ok, %{acc | cancel: v}}}

      # the C API has qconstraint slacks only, no dual multipliers
      # (GetQConstrInfo rejects "Dual"; verified empirically on 8.0.5)
      {:qcp_duals, false}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {:qcp_duals, true}, {:ok, _acc} ->
        {:halt, {:error, {:unsupported, :qcp_duals, __MODULE__}}}

      {:progress, v}, {:ok, acc} when is_pid(v) ->
        {:cont, {:ok, %{acc | progress_pid: v}}}

      {:progress_every, v}, {:ok, acc} when is_integer(v) and v >= 0 ->
        {:cont, {:ok, %{acc | progress_every_ms: v}}}

      {:incumbents, v}, {:ok, acc} when is_pid(v) ->
        {:cont, {:ok, %{acc | incumbent_pid: v}}}

      {key, v}, {:ok, _acc}
      when key in [
             :time_limit,
             :mip_gap,
             :threads,
             :log,
             :cancel,
             :qcp_duals,
             :progress,
             :progress_every,
             :incumbents
           ] ->
        {:halt, {:error, {:invalid_option_value, key, v}}}

      {key, _v}, {:ok, _acc} ->
        {:halt, {:error, {:unknown_option, key}}}
    end)
  end

  # COPT status codes, verified against copt.h 8.0.5. LP (LpStatus,
  # copt.h:111-120) and MIP (MipStatus, copt.h:123-131) enumerations OVERLAP
  # numerically, so decoding needs the MIP flag: 1 optimal, 2 infeasible,
  # 3 unbounded, 4 inf-or-unb (MIP only), 8 timeout, 10 interrupted.
  defp decode_status(1, _mip?), do: :optimal
  defp decode_status(2, _mip?), do: :infeasible
  defp decode_status(3, _mip?), do: :unbounded
  defp decode_status(4, true), do: :unbounded_or_infeasible
  defp decode_status(8, _mip?), do: :time_limit
  defp decode_status(10, _mip?), do: :interrupted
  defp decode_status(other, _mip?), do: {:other, other}

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
