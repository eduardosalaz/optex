defmodule Optex.Var do
  @moduledoc "A decision variable. Created by the model, carries its own id."

  # type: :cont | :int | :bin
  # lb/ub: number | :infinity | :neg_infinity
  defstruct [:id, :name, type: :cont, lb: 0.0, ub: :infinity]

  @type bound :: number() | :infinity | :neg_infinity
  @type t :: %__MODULE__{
          id: non_neg_integer(),
          name: term(),
          type: :cont | :int | :bin,
          lb: bound(),
          ub: bound()
        }
end
