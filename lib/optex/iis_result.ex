defmodule Optex.IisResult do
  @moduledoc false
  # Raw wire struct returned by the native iis NIF: column/row indices of the
  # irreducible infeasible subsystem with raw IisBoundStatus ints per member.
  # Internal to the binding.
  defstruct [:cols, :col_statuses, :rows, :row_statuses]
end
