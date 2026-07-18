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
  integer or binary variables. `duals` covers linear rows only: quadratic
  constraint duals live in `qcon_duals`, keyed by qconstraint name (id in
  the qconstraint id space as the fallback), and are populated only when
  the solve was run with `qcp_duals: true` on a backend that supports it
  (Gurobi); otherwise `qcon_duals` is `nil` (always nil for MIQCP, where no
  dual solution exists). Auxiliary variables introduced by defined
  variables (named `{name, :arg}`) appear in `values` like any other
  variable.
  """

  defstruct [:status, :objective, :values, :duals, :reduced_costs, :qcon_duals, :stats]

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
          qcon_duals: %{term() => float()} | nil,
          stats: stats()
        }
end
