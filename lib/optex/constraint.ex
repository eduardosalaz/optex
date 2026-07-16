defmodule Optex.Constraint do
  @moduledoc "One linear row, normalized: pure a^T x on the left, number on the right."

  # sense: :le | :ge | :eq
  defstruct [:id, :name, :aff, :sense, :rhs]

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          name: term(),
          aff: Optex.Aff.t(),
          sense: :le | :ge | :eq,
          rhs: number()
        }
end
