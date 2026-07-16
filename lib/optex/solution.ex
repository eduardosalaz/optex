defmodule Optex.Solution do
  @moduledoc """
  The result of a solve: a decoded status, the objective value, and primal
  variable values keyed by variable id (`Optex.optimize/2` rekeys them by the
  user-facing variable names).
  """

  defstruct [:status, :objective, :values]

  @type status ::
          :optimal | :infeasible | :unbounded | :unbounded_or_infeasible | {:other, integer()}
  @type t :: %__MODULE__{status: status(), objective: float(), values: %{term() => float()}}
end
