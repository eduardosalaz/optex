defmodule Optex.Model do
  @moduledoc "The neutral model. Immutable; builder calls return a new struct."

  defstruct vars: %{},
            constraints: [],
            objective: %Optex.Aff{},
            sense: :min,
            var_counter: 0,
            con_counter: 0

  @type t :: %__MODULE__{
          vars: %{non_neg_integer() => Optex.Var.t()},
          constraints: [Optex.Constraint.t()],
          objective: Optex.Aff.t(),
          sense: :min | :max,
          var_counter: non_neg_integer(),
          con_counter: non_neg_integer()
        }

  def new, do: %__MODULE__{}

  def add_variable(%__MODULE__{var_counter: id, vars: vars} = m, opts \\ []) do
    var = struct(%Optex.Var{id: id}, normalize_var_opts(opts))
    {var, %{m | vars: Map.put(vars, id, var), var_counter: id + 1}}
  end

  def add_constraint(
        %__MODULE__{constraints: cs, con_counter: id} = m,
        %Optex.Aff{} = aff,
        sense,
        rhs
      )
      when sense in [:le, :ge, :eq] do
    # normalize: fold the affine constant into the rhs, leaving pure a^T x on the left
    c = %Optex.Constraint{
      id: id,
      aff: %{aff | constant: 0.0},
      sense: sense,
      rhs: rhs - aff.constant
    }

    %{m | constraints: [c | cs], con_counter: id + 1}
  end

  def set_objective(%__MODULE__{} = m, %Optex.Aff{} = aff, sense) when sense in [:min, :max] do
    %{m | objective: aff, sense: sense}
  end

  # A binary variable is integer with bounds forced to [0, 1].
  defp normalize_var_opts(opts) do
    case Keyword.get(opts, :type, :cont) do
      :bin -> Keyword.merge(opts, lb: 0.0, ub: 1.0, type: :bin)
      _ -> opts
    end
  end
end
