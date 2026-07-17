defmodule Optex.Indicator do
  @moduledoc """
  An indicator constraint: a linear row that must hold when a binary variable
  takes a given value (`bin = active_value -> a^T x SENSE rhs`). Stored
  normalized like `Optex.Constraint` (pure a^T x on the left). Solved natively
  by capable backends; never reformulated.
  """

  defstruct [:id, :name, :bin_id, :active_value, :aff, :sense, :rhs]

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          name: term(),
          bin_id: non_neg_integer(),
          active_value: 0 | 1,
          aff: Optex.Aff.t(),
          sense: :le | :ge | :eq,
          rhs: number()
        }
end
