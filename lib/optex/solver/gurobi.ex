defmodule Optex.Solver.Gurobi do
  @moduledoc """
  Gurobi backend. Implements the same `Optex.Solver` contract as
  `Optex.Solver.HiGHS` and accepts the same neutral options; use it with
  `Optex.optimize(m, solver: Optex.Solver.Gurobi)`.

  Requires an installed, licensed Gurobi: the native crate is compile-gated
  on `GUROBI_HOME` (check `available?/0`). All constants and parameter names
  were verified against Gurobi 13.0.0's gurobi_c.h.

  Supported options (same set as HiGHS): `:time_limit`, `:mip_gap`,
  `:threads`, `:log` (`false` | `true` | pid receiving
  `{:optex_gurobi_log, line}`), `:cancel` (token from `cancel_token/0`).
  Gurobi additionally understands `:qcp_duals` (`true` sets QCPDual=1 and
  returns quadratic constraint duals in `Optex.Solution.qcon_duals` for
  continuous QCPs; other backends reject the option as unsupported).

  Limitation: genuine two-sided range rows (never produced by
  `Optex.Transform`) are rejected; Gurobi rows are sense + rhs.
  """

  @behaviour Optex.Solver

  defmodule Options do
    @moduledoc false
    # Wire struct for the NIF: params pre-grouped by Gurobi value type.
    # qcp_duals asks the NIF to fetch QCPi after the solve; the QCPDual=1
    # parameter that makes Gurobi compute them travels in int_params.
    # progress/incumbent stream targets mirror the HiGHS options.
    defstruct int_params: [],
              dbl_params: [],
              log_pid: nil,
              cancel: nil,
              qcp_duals: false,
              progress_pid: nil,
              progress_every_ms: 1000,
              incumbent_pid: nil
  end

  # Mapped to vtype chars in Rust: 0 -> 'C', 1 -> 'I', 2 -> 'B'. Gurobi has a
  # native binary type, so :bin keeps its identity here.
  @vartype %{cont: 0, int: 1, bin: 2}

  @dual_feasible 2

  @doc "Whether the native Gurobi binding was compiled (GUROBI_HOME at build)."
  def available?, do: Optex.Solver.Gurobi.Native.available?()

  @doc "Create a cancellation token to pass as the `:cancel` solve option."
  def cancel_token, do: Optex.Solver.Gurobi.Native.cancel_token()

  @doc "Ask the solve holding this token to terminate."
  def cancel(token), do: Optex.Solver.Gurobi.Native.cancel(token)

  # All general constraints map to native Gurobi constructs
  # (GRBaddgenconstrIndicator / GRBaddgenconstrAbs / GRBaddgenconstrPWL /
  # GRBaddgenconstrMax / GRBaddgenconstrMin); quadratic objectives
  # (including MIQP and nonconvex) via GRBaddqpterms; quadratic constraints
  # (including nonconvex and equality) via GRBaddqconstr.
  @impl true
  def capabilities,
    do: [
      :indicator,
      :abs,
      :pwl,
      :min_max,
      :sos,
      :second_order_cone,
      :quadratic_objective,
      :quadratic_constraint
    ]

  # Native calls go through apply/3: in the GUROBI_HOME-less stub build the
  # type checker would otherwise prove the {:ok, ...} clauses unreachable and
  # fail --warnings-as-errors.
  @impl true
  def solve(%Optex.SolverInput{} = input, opts \\ []) do
    with :ok <- check_capabilities(input),
         {:ok, options} <- build_options(opts) do
      case apply(Optex.Solver.Gurobi.Native, :solve, [prepare(input), options]) do
        {:ok, %Optex.SolveResult{} = result} ->
          {:ok, to_solution(result, mip?(input))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # GRBcomputeIIS examines the FULL model: linear rows, bounds, general
  # constraints (IISGenConstr), and quadratic constraints (IISQConstr), so
  # explain_infeasibility hands this backend the unstripped input.
  @impl true
  def construct_iis?, do: true

  @impl true
  def iis(%Optex.SolverInput{} = input, _opts \\ []) do
    case apply(Optex.Solver.Gurobi.Native, :iis, [prepare(input)]) do
      {:ok, %Optex.IisResult{} = result} ->
        {:ok,
         %{
           variables: decode_members(result.cols, result.col_statuses),
           constraints: decode_members(result.rows, result.row_statuses),
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

  # A no-op while Gurobi advertises every capability; kept generic so a
  # future gap rejects uniformly and pre-NIF like the other backends.
  defp check_capabilities(input) do
    case Optex.SolverInput.required_capabilities(input) -- capabilities() do
      [] -> :ok
      [cap | _] -> {:error, {:unsupported, cap, __MODULE__}}
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
      # independent of dual_status: QCPi exists exactly when the NIF could
      # fetch it (continuous QCP solved with QCPDual=1), Pi/RC may not
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

  # Neutral option names to Gurobi parameter names (verified against 13.0).
  defp build_options(opts) do
    Enum.reduce_while(opts, {:ok, %Options{}}, fn
      {:time_limit, v}, {:ok, acc} when is_number(v) and v > 0 ->
        {:cont, {:ok, %{acc | dbl_params: [{"TimeLimit", v * 1.0} | acc.dbl_params]}}}

      {:mip_gap, v}, {:ok, acc} when is_number(v) and v >= 0 ->
        {:cont, {:ok, %{acc | dbl_params: [{"MIPGap", v * 1.0} | acc.dbl_params]}}}

      {:threads, v}, {:ok, acc} when is_integer(v) and v > 0 ->
        {:cont, {:ok, %{acc | int_params: [{"Threads", v} | acc.int_params]}}}

      {:log, v}, {:ok, acc} when is_boolean(v) ->
        {:cont,
         {:ok, %{acc | int_params: [{"OutputFlag", if(v, do: 1, else: 0)} | acc.int_params]}}}

      {:log, v}, {:ok, acc} when is_pid(v) ->
        # log lines must be generated but go to the callback, not the console
        {:cont,
         {:ok,
          %{
            acc
            | log_pid: v,
              int_params: [{"OutputFlag", 1}, {"LogToConsole", 0} | acc.int_params]
          }}}

      {:cancel, v}, {:ok, acc} when is_reference(v) ->
        {:cont, {:ok, %{acc | cancel: v}}}

      # QCPDual verified against gurobi_c.h 13.0 (GRB_INT_PAR_QCPDUAL)
      {:qcp_duals, true}, {:ok, acc} ->
        {:cont, {:ok, %{acc | qcp_duals: true, int_params: [{"QCPDual", 1} | acc.int_params]}}}

      {:qcp_duals, false}, {:ok, acc} ->
        {:cont, {:ok, acc}}

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

  # Gurobi Status attr, verified against gurobi_c.h 13.0: 2 OPTIMAL,
  # 3 INFEASIBLE, 4 INF_OR_UNBD, 5 UNBOUNDED, 9 TIME_LIMIT, 11 INTERRUPTED.
  defp decode_status(2), do: :optimal
  defp decode_status(3), do: :infeasible
  defp decode_status(4), do: :unbounded_or_infeasible
  defp decode_status(5), do: :unbounded
  defp decode_status(9), do: :time_limit
  defp decode_status(11), do: :interrupted
  defp decode_status(other), do: {:other, other}

  # same member-status ints as the HiGHS backend: 2 lower, 3 upper, 4 boxed
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
