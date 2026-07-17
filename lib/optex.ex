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
             duals: rekey_duals(model, sol.duals)
         }}

      {:error, reason} ->
        {:error, reason}
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
