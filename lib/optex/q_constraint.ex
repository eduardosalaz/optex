defmodule Optex.QConstraint do
  @moduledoc """
  A quadratic constraint x^T C x + a^T x SENSE rhs, stored normalized (the
  affine constant folded into the rhs) with literal coefficients. Lives in
  its own id space, separate from linear rows. Solved natively by capable
  backends: Gurobi (including nonconvex and equality), CPLEX (convex,
  `<=`/`>=` only); HiGHS rejects.
  """

  defstruct [:id, :name, :aff, :sense, :rhs]

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          name: term(),
          aff: Optex.Aff.t(),
          sense: :le | :ge | :eq,
          rhs: number()
        }
end
