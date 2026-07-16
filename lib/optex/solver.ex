defmodule Optex.Solver do
  @moduledoc """
  The behaviour a solver backend implements. This is the only contract between
  the solver-abstraction layer and a backend; a second solver implements this
  and touches nothing above it.
  """

  @callback solve(Optex.SolverInput.t(), keyword()) ::
              {:ok, Optex.Solution.t()} | {:error, term()}
end
