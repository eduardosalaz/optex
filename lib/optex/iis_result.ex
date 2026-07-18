defmodule Optex.IisResult do
  @moduledoc false
  # Raw wire struct returned by the native iis NIF: column/row indices of the
  # irreducible infeasible subsystem with raw IisBoundStatus ints per member,
  # plus per-kind construct positions (wire order) for backends with
  # construct-aware IIS (Gurobi); empty lists elsewhere. Internal to the
  # binding.
  defstruct cols: [],
            col_statuses: [],
            rows: [],
            row_statuses: [],
            indicators: [],
            abs_defs: [],
            minmax_defs: [],
            pwl_defs: [],
            qconstraints: []
end
