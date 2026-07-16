defmodule Optex.SolveResult do
  @moduledoc false
  # Raw wire struct returned by the native solve NIF: undecoded HiGHS model
  # status, objective, and column values in id order. Internal to the binding.
  defstruct [:status, :objective, :values]
end
