defmodule Optex.SolveResult do
  @moduledoc false
  # Raw wire struct returned by the native solve NIF: undecoded HiGHS model
  # status, objective, column values, dual arrays with their raw
  # kHighsSolutionStatus, and solve statistics. Internal to the binding.
  defstruct [
    :status,
    :objective,
    :values,
    :col_duals,
    :row_duals,
    :dual_status,
    :solve_time,
    :simplex_iterations,
    :nodes,
    :mip_gap
  ]
end
