defmodule Optex.Cone do
  @moduledoc """
  A second-order cone in its own id space. `type` `:quad` relates one head
  to its members: `head >= sqrt(sum member^2)`; `type` `:rquad` (rotated)
  relates two heads: `2 * h1 * h2 >= sum member^2`. Heads are guaranteed to
  carry a nonnegative lower bound (the model layer enforces it: the bound
  is part of the cone's meaning, and it is what makes the SOC-shaped
  quadratic encodings on Gurobi/CPLEX legal). Solved natively by capable
  backends (Gurobi, CPLEX, COPT); backends without cone support reject the
  model at solve time.
  """

  defstruct [:id, :name, :type, :head_ids, :member_ids]

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          name: term() | nil,
          type: :quad | :rquad,
          head_ids: [non_neg_integer()],
          member_ids: [non_neg_integer()]
        }
end
