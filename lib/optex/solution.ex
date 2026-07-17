defmodule Optex.Solution do
  @moduledoc """
  The result of a solve: a decoded status, the objective value, primal
  variable values, and, for LPs, dual information.

  `values` is keyed by variable id from the solver backend;
  `Optex.optimize/2` rekeys it (and `reduced_costs`) by the user-facing
  variable names, and rekeys `duals` by constraint name (`name:` option on
  `constraint`), falling back to the constraint id in declaration order for
  unnamed rows. `duals` and `reduced_costs` are `nil` when the solver
  produced no dual solution, which is always the case for models with
  integer or binary variables.
  """

  defstruct [:status, :objective, :values, :duals, :reduced_costs]

  @type status ::
          :optimal
          | :infeasible
          | :unbounded
          | :unbounded_or_infeasible
          | :time_limit
          | {:other, integer()}
  @type t :: %__MODULE__{
          status: status(),
          objective: float(),
          values: %{term() => float()},
          duals: %{term() => float()} | nil,
          reduced_costs: %{term() => float()} | nil
        }
end
