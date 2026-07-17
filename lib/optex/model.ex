defmodule Optex.Model do
  @moduledoc """
  The neutral model. Immutable; builder calls return a new struct.

  Constraints and the objective accept either a ready-made `Optex.Aff` or a
  terms list of `{reference, coefficient}` tuples, where a reference is a
  `%Optex.Var{}` or the name the variable was created with. The list form
  keeps programmatic model building pipeable:

      m
      |> Optex.Model.add_constraint([{:x, 1.0}, {{:y, 1}, 2.0}], :le, 4.0)
      |> Optex.Model.set_objective([{:x, 1.0}], :max)

  Name resolution is last-wins when the same name is registered twice
  (matching how solution values are keyed); variables created without a name
  can only be referenced by their `%Optex.Var{}` struct.
  """

  defstruct vars: %{},
            constraints: [],
            objective: %Optex.Aff{},
            sense: :min,
            var_counter: 0,
            con_counter: 0,
            name_index: %{}

  @type var_ref :: Optex.Var.t() | term()
  @type terms :: [{var_ref(), number()}]

  @type t :: %__MODULE__{
          vars: %{non_neg_integer() => Optex.Var.t()},
          constraints: [Optex.Constraint.t()],
          objective: Optex.Aff.t(),
          sense: :min | :max,
          var_counter: non_neg_integer(),
          con_counter: non_neg_integer(),
          name_index: %{term() => non_neg_integer()}
        }

  def new, do: %__MODULE__{}

  def add_variable(%__MODULE__{var_counter: id, vars: vars} = m, opts \\ []) do
    var = struct(%Optex.Var{id: id}, normalize_var_opts(opts))

    name_index =
      case var.name do
        nil -> m.name_index
        name -> Map.put(m.name_index, name, id)
      end

    {var, %{m | vars: Map.put(vars, id, var), var_counter: id + 1, name_index: name_index}}
  end

  def add_constraint(m, aff_or_terms, sense, rhs, opts \\ [])

  def add_constraint(
        %__MODULE__{constraints: cs, con_counter: id} = m,
        %Optex.Aff{} = aff,
        sense,
        rhs,
        opts
      )
      when sense in [:le, :ge, :eq] do
    # normalize: fold the affine constant into the rhs, leaving pure a^T x on the left
    c = %Optex.Constraint{
      id: id,
      name: Keyword.get(opts, :name),
      aff: %{aff | constant: 0.0},
      sense: sense,
      rhs: rhs - aff.constant
    }

    %{m | constraints: [c | cs], con_counter: id + 1}
  end

  def add_constraint(%__MODULE__{} = m, terms, sense, rhs, opts) when is_list(terms) do
    add_constraint(m, resolve_terms(m, terms), sense, rhs, opts)
  end

  def set_objective(%__MODULE__{} = m, %Optex.Aff{} = aff, sense) when sense in [:min, :max] do
    %{m | objective: aff, sense: sense}
  end

  def set_objective(%__MODULE__{} = m, terms, sense) when is_list(terms) do
    set_objective(m, resolve_terms(m, terms), sense)
  end

  # Build an Aff from {ref, coef} tuples; duplicate references sum, matching
  # Aff.add semantics.
  defp resolve_terms(%__MODULE__{} = m, terms) do
    Enum.reduce(terms, %Optex.Aff{}, fn
      {%Optex.Var{id: id}, coef}, acc when is_number(coef) ->
        Optex.Aff.add(acc, %Optex.Aff{terms: %{id => coef * 1.0}})

      {name, coef}, acc when is_number(coef) ->
        case Map.fetch(m.name_index, name) do
          {:ok, id} ->
            Optex.Aff.add(acc, %Optex.Aff{terms: %{id => coef * 1.0}})

          :error ->
            raise ArgumentError,
                  "unknown variable name #{inspect(name)}; " <>
                    "known names: #{inspect(Map.keys(m.name_index))}"
        end
    end)
  end

  # A binary variable is integer with bounds forced to [0, 1].
  defp normalize_var_opts(opts) do
    case Keyword.get(opts, :type, :cont) do
      :bin -> Keyword.merge(opts, lb: 0.0, ub: 1.0, type: :bin)
      _ -> opts
    end
  end
end
