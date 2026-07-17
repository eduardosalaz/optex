defmodule Optex.SolveResult do
  @moduledoc false
  # Raw wire struct returned by the native solve NIF: undecoded HiGHS model
  # status, objective, column values, dual arrays, and the raw
  # kHighsSolutionStatus for the duals. Internal to the binding.
  defstruct [:status, :objective, :values, :col_duals, :row_duals, :dual_status]
end
