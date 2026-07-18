defmodule Optex do
  @moduledoc """
  Optex: an Elixir library for modeling and solving mixed-integer linear
  programs, with an in-process HiGHS binding via Rustler.

  Build a model with the `Optex.DSL`, then call `optimize/2`:

      iex> import Optex.DSL
      iex> m =
      ...>   model sense: :max do
      ...>     variable x, lb: 0.0
      ...>     variable y, lb: 0.0
      ...>     constraint x + 2 * y <= 4
      ...>     constraint 3 * x + y <= 6
      ...>     objective x + y
      ...>   end
      iex> {:ok, sol} = Optex.optimize(m)
      iex> sol.status
      :optimal
      iex> Float.round(sol.objective, 6)
      2.8
      iex> {Float.round(sol.values[:x], 6), Float.round(sol.values[:y], 6)}
      {1.6, 1.2}

  Indexed variables are read back by the same key used to declare them:
  `sol.values[{:y, 2}]` for `variable y[i], i <- [1, 2, 3]`.
  """

  @doc """
  Transform the model to solver input, solve it, and return the solution with
  values keyed by the user-facing variable names.

  Options:

    * `:solver` - a module implementing the `Optex.Solver` behaviour.
      Defaults to `Optex.Solver.HiGHS` (the only backend in v1; the option is
      the seam a future backend slots into).

  Any remaining options are passed to the solver; `Optex.Solver.HiGHS`
  understands `:time_limit`, `:mip_gap`, `:threads`, and `:log`.
  `Optex.Solver.Gurobi` additionally accepts `qcp_duals: true` to return
  quadratic constraint duals (in `Optex.Solution.qcon_duals`, keyed by
  qconstraint name); backends without that capability reject the option
  with `{:error, {:unsupported, :qcp_duals, backend}}`.

  Values are keyed by each variable's `name`: the bare atom for scalar
  variables (`:x`), `{family, index}` for indexed families (`{:y, 1}`,
  `{:w, {1, :a}}`). A variable created without a name falls back to its
  integer id.
  """
  @spec optimize(Optex.Model.t(), keyword()) ::
          {:ok, Optex.Solution.t()} | {:error, term()}
  def optimize(%Optex.Model{} = model, opts \\ []) do
    {solver, solver_opts} = Keyword.pop(opts, :solver, Optex.Solver.HiGHS)
    input = Optex.Transform.to_solver_input(model)

    case solver.solve(input, solver_opts) do
      {:ok, %Optex.Solution{} = sol} ->
        {:ok,
         %{
           sol
           | values: rekey_by_name(model, sol.values),
             reduced_costs: rekey_by_name(model, sol.reduced_costs),
             duals: rekey_duals(model, sol.duals),
             qcon_duals: rekey_qcon_duals(model, sol.qcon_duals)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Explain why a model is infeasible.

  Computes an irreducible infeasible subsystem (IIS): a minimal set of
  constraints and variable bounds that is infeasible together (for MIPs, of
  the LP relaxation). Returns `{:ok, %{constraints: [...], variables: [...],
  constructs: [...], not_examined: [...]}}` where constraint/variable
  members are `{name_or_id, involvement}` (involvement says which side
  participates: `:lower`, `:upper`, `:boxed`, ...) and construct members
  are `{kind, name_or_id}` (defined variables report under their result
  variable's name). Empty lists mean no IIS was found among what was
  examined (the model is feasible or the search failed).

  Scope depends on the backend. A construct-aware backend (Gurobi, via its
  native IIS over general and quadratic constraints) examines the FULL
  model, and conflicting constructs land in `constructs`. Everywhere else
  the IIS examines the linear relaxation: constructs (indicators,
  abs/pwl/min-max definitions, quadratic constraints) are stripped before
  analysis, so any IIS found is genuine, and `not_examined` names the
  stripped construct kinds since the real conflict may live there.

  Options: `:solver` as in `optimize/2`; the backend must export the optional
  `iis/2` callback of the `Optex.Solver` behaviour or `{:error,
  :not_supported}` is returned.
  """
  @spec explain_infeasibility(Optex.Model.t(), keyword()) ::
          {:ok,
           %{
             constraints: list(),
             variables: list(),
             constructs: [{atom(), term()}],
             not_examined: [atom()]
           }}
          | {:error, term()}
  def explain_infeasibility(%Optex.Model{} = model, opts \\ []) do
    {solver, solver_opts} = Keyword.pop(opts, :solver, Optex.Solver.HiGHS)

    if Code.ensure_loaded?(solver) and function_exported?(solver, :iis, 2) do
      full_input = Optex.Transform.to_solver_input(model)

      {input, not_examined} =
        if construct_iis?(solver, full_input) do
          {full_input, []}
        else
          # analyze the linear relaxation: strip everything outside IIS
          # scope (dropping constructs only relaxes, so any IIS found is
          # genuine)
          stripped = %{
            full_input
            | indicators: [],
              abs_defs: [],
              pwl_defs: [],
              minmax_defs: [],
              qconstraints: [],
              cones: [],
              soss: [],
              q_cols: [],
              q_rows: [],
              q_vals: []
          }

          kinds =
            for {kind, present?} <- [
                  indicator: model.indicators != [],
                  abs: model.abs_defs != [],
                  pwl: model.pwl_defs != [],
                  min_max: model.minmax_defs != [],
                  quadratic_constraint: model.qconstraints != [],
                  second_order_cone: model.cones != [],
                  sos: model.soss != []
                ],
                present?,
                do: kind

          {stripped, kinds}
        end

      case solver.iis(input, solver_opts) do
        {:ok, %{variables: vars, constraints: cons} = result} ->
          {:ok,
           %{
             variables: Enum.map(vars, fn {id, status} -> {var_key(model, id), status} end),
             constraints: Enum.map(cons, fn {id, status} -> {con_key(model, id), status} end),
             constructs: rekey_constructs(model, Map.get(result, :constructs, %{})),
             not_examined: not_examined
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_supported}
    end
  end

  # a backend examines constructs natively only when it says so AND it can
  # actually solve everything this input carries
  defp construct_iis?(solver, input) do
    function_exported?(solver, :construct_iis?, 0) and solver.construct_iis?() and
      function_exported?(solver, :capabilities, 0) and
      Optex.SolverInput.required_capabilities(input) -- solver.capabilities() == []
  end

  # Construct IIS members arrive as positions in each kind's wire order.
  # Indicators and qconstraints have their own contiguous id spaces (wire
  # position == id); defined variables report under their result variable's
  # name, the handle users know them by.
  defp rekey_constructs(%Optex.Model{} = m, constructs) do
    ind_names = Map.new(m.indicators, fn ind -> {ind.id, ind.name} end)
    qc_names = Map.new(m.qconstraints, fn qc -> {qc.id, qc.name} end)
    sos_names = Map.new(m.soss, fn s -> {s.id, s.name} end)
    cone_names = Map.new(m.cones, fn c -> {c.id, c.name} end)

    abs_res = m.abs_defs |> Enum.reverse() |> Enum.map(fn {res, _arg} -> res end)
    mm_res = m.minmax_defs |> Enum.reverse() |> Enum.map(fn {res, _, _, _} -> res end)
    pwl_res = m.pwl_defs |> Enum.reverse() |> Enum.map(fn {res, _, _, _} -> res end)

    by_id = fn names, id ->
      case names do
        %{^id => nil} -> id
        %{^id => name} -> name
        _ -> id
      end
    end

    by_res_var = fn res_ids, pos ->
      id = Enum.at(res_ids, pos)

      case m.vars[id] do
        %Optex.Var{name: nil} -> id
        %Optex.Var{name: name} -> name
        nil -> pos
      end
    end

    Enum.flat_map(
      [
        {:indicator, &by_id.(ind_names, &1)},
        {:abs, &by_res_var.(abs_res, &1)},
        {:pwl, &by_res_var.(pwl_res, &1)},
        {:min_max, &by_res_var.(mm_res, &1)},
        {:quadratic_constraint, &by_id.(qc_names, &1)},
        {:second_order_cone, &by_id.(cone_names, &1)},
        {:sos, &by_id.(sos_names, &1)}
      ],
      fn {kind, namer} ->
        constructs |> Map.get(kind, []) |> Enum.map(fn pos -> {kind, namer.(pos)} end)
      end
    )
  end

  defp var_key(%Optex.Model{vars: vars}, id) do
    case Map.fetch!(vars, id) do
      %Optex.Var{name: nil} -> id
      %Optex.Var{name: name} -> name
    end
  end

  defp con_key(%Optex.Model{constraints: cs}, id) do
    case Enum.find(cs, &(&1.id == id)) do
      %Optex.Constraint{name: nil} -> id
      %Optex.Constraint{name: name} -> name
      nil -> id
    end
  end

  defp rekey_duals(%Optex.Model{}, nil), do: nil

  defp rekey_duals(%Optex.Model{constraints: cs}, duals_by_id) do
    names = Map.new(cs, fn c -> {c.id, c.name} end)

    Map.new(duals_by_id, fn {id, v} ->
      case names do
        %{^id => nil} -> {id, v}
        %{^id => name} -> {name, v}
        _ -> {id, v}
      end
    end)
  end

  # Quadratic constraints live in their own id space, so they get their own
  # rekeying against model.qconstraints; ids never mix with linear rows.
  defp rekey_qcon_duals(%Optex.Model{}, nil), do: nil

  defp rekey_qcon_duals(%Optex.Model{qconstraints: qcs}, duals_by_id) do
    names = Map.new(qcs, fn qc -> {qc.id, qc.name} end)

    Map.new(duals_by_id, fn {id, v} ->
      case names do
        %{^id => nil} -> {id, v}
        %{^id => name} -> {name, v}
        _ -> {id, v}
      end
    end)
  end

  defp rekey_by_name(%Optex.Model{}, nil), do: nil

  defp rekey_by_name(%Optex.Model{vars: vars}, values_by_id) do
    Map.new(values_by_id, fn {id, v} ->
      case Map.fetch!(vars, id) do
        %Optex.Var{name: nil} -> {id, v}
        %Optex.Var{name: name} -> {name, v}
      end
    end)
  end
end
