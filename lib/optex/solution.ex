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
  integer or binary variables; quadratic constraints carry no duals either
  way. Auxiliary variables introduced by defined variables (named
  `{name, :arg}`) appear in `values` like any other variable.
  """

  defstruct [:status, :objective, :values, :duals, :reduced_costs, :stats]

  @type status ::
          :optimal
          | :infeasible
          | :unbounded
          | :unbounded_or_infeasible
          | :time_limit
          | :interrupted
          | {:other, integer()}

  @typedoc """
  Solve statistics: wall-clock `:solve_time` in seconds, `:simplex_iterations`,
  branch-and-bound `:nodes`, and the relative `:mip_gap` actually achieved
  (nil for pure LPs, where the concept does not apply).
  """
  @type stats :: %{
          solve_time: float(),
          simplex_iterations: non_neg_integer(),
          nodes: non_neg_integer(),
          mip_gap: float() | nil
        }

  # objective is nil when the solver has no finite value to report (for
  # example an interrupted MIP with no incumbent, or an infeasible model)
  @type t :: %__MODULE__{
          status: status(),
          objective: float() | nil,
          values: %{term() => float()},
          duals: %{term() => float()} | nil,
          reduced_costs: %{term() => float()} | nil,
          stats: stats()
        }
end
