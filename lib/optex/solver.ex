defmodule Optex.Solver do
  @moduledoc """
  The behaviour a solver backend implements. This is the only contract between
  the solver-abstraction layer and a backend; a second solver implements this
  and touches nothing above it.
  """

  @callback solve(Optex.SolverInput.t(), keyword()) ::
              {:ok, Optex.Solution.t()} | {:error, term()}

  @doc """
  Compute an irreducible infeasible subsystem for the (relaxed) model:
  a minimal set of variables (via their bounds) and constraints that is
  infeasible together. Optional; backends without IIS support simply do not
  export it.
  """
  @callback iis(Optex.SolverInput.t(), keyword()) ::
              {:ok, %{variables: list(), constraints: list()}} | {:error, term()}

  @optional_callbacks iis: 2
end
