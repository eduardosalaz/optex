defmodule Optex.Sos do
  @moduledoc """
  A special ordered set in its own id space: `type` is `:sos1` (at most one
  member nonzero) or `:sos2` (at most two, adjacent in weight order);
  `var_ids` and `weights` are parallel lists, weights distinct because they
  define the set's order. Solved natively by capable backends (Gurobi,
  CPLEX, COPT); backends without SOS support reject the model at solve
  time.
  """

  defstruct [:id, :name, :type, :var_ids, :weights]

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          name: term() | nil,
          type: :sos1 | :sos2,
          var_ids: [non_neg_integer()],
          weights: [float()]
        }
end
