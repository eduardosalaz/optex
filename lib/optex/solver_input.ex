defmodule Optex.SolverInput do
  @moduledoc """
  Column-oriented problem ready for a solver. Variables 0..n-1, constraints 0..m-1.
  Constraint matrix is CSC: column j occupies row_index/values at
  col_start[j] .. col_start[j+1]-1.
  Each constraint is a range: row_lb <= a^T x <= row_ub.
  Bounds use :infinity/:neg_infinity; the binding substitutes the solver's value.
  """
  defstruct num_vars: 0,
            num_cons: 0,
            # :min | :max
            sense: :min,
            # length num_vars
            obj: [],
            # constant term of the objective, passed to the solver as offset
            obj_offset: 0.0,
            # length num_vars (numbers or :neg_infinity)
            col_lb: [],
            # length num_vars (numbers or :infinity)
            col_ub: [],
            # length num_vars, :cont | :int | :bin
            col_type: [],
            # length num_vars + 1
            col_start: [],
            # length nnz
            row_index: [],
            # length nnz
            values: [],
            # length num_cons (numbers or :neg_infinity)
            row_lb: [],
            # length num_cons (numbers or :infinity)
            row_ub: []

  @type t :: %__MODULE__{}
end
