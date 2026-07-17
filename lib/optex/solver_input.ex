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
            row_ub: [],
            # native general constraints (see required_capabilities/1):
            # indicator rows as %Optex.SolverInput.Indicator{}
            indicators: [],
            # abs definitions as {result_col, argument_col}
            abs_defs: []

  @type t :: %__MODULE__{}

  defmodule Indicator do
    @moduledoc false
    # Wire form of an indicator row: sparse terms, neutral sense atom.
    defstruct [:bin_col, :active_value, :cols, :coefs, :sense, :rhs]
  end

  @doc """
  The solver capabilities this input requires beyond plain MILP. Backends
  compare against their `capabilities/0` and reject what they cannot solve
  natively; nothing is ever reformulated.
  """
  def required_capabilities(%__MODULE__{} = input) do
    caps = if input.indicators != [], do: [:indicator], else: []
    if input.abs_defs != [], do: [:abs | caps], else: caps
  end
end
