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

  @doc """
  The native general-constraint capabilities this backend supports (subset of
  `[:indicator, :abs]`). A backend must reject inputs requiring capabilities
  it lacks with `{:error, {:unsupported, capability, backend}}`; constructs
  are never reformulated onto incapable solvers. Absent callback means no
  capabilities.
  """
  @callback capabilities() :: [atom()]

  @optional_callbacks iis: 2, capabilities: 0
end
