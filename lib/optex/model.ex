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
            name_index: %{},
            # native general constraints; solved only by capable backends
            indicators: [],
            ind_counter: 0,
            abs_defs: [],
            pwl_defs: [],
            minmax_defs: [],
            qconstraints: [],
            qcon_counter: 0

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

  @doc "An empty model."
  def new, do: %__MODULE__{}

  @doc """
  Register a variable and return `{var, model}`.

  Options: `:name` (any term; keys the solution values and enables name-based
  term references), `:type` (`:cont` default, `:int`, `:bin`), `:lb`/`:ub`
  (number or `:infinity`/`:neg_infinity`). A `:bin` variable gets `[0, 1]`
  bounds regardless of the given ones.
  """
  def add_variable(%__MODULE__{var_counter: id, vars: vars} = m, opts \\ []) do
    var = struct(%Optex.Var{id: id}, normalize_var_opts(opts))

    name_index =
      case var.name do
        nil ->
          m.name_index

        name ->
          # silent shadowing is almost always a modeling bug: name-based
          # references and solution keys resolve to the newest variable
          if Map.has_key?(m.name_index, name) do
            IO.warn(
              "variable name #{inspect(name)} registered more than once; " <>
                "name-based references and solution keys resolve to the newest variable"
            )
          end

          Map.put(m.name_index, name, id)
      end

    {var, %{m | vars: Map.put(vars, id, var), var_counter: id + 1, name_index: name_index}}
  end

  @doc """
  Append the constraint `aff SENSE rhs` (sense `:le`, `:ge`, or `:eq`) and
  return the model.

  The left side is an `Optex.Aff` or a `{reference, coefficient}` terms list
  (see the module docs). Any affine constant folds into the right-hand side.
  Options: `:name` (any term; keys the constraint's dual value in solutions).
  """
  def add_constraint(m, aff_or_terms, sense, rhs, opts \\ [])

  # a quadratic left side becomes a quadratic constraint, in its own id
  # space (solved natively by capable backends; never part of the CSC matrix)
  def add_constraint(
        %__MODULE__{qconstraints: qcs, qcon_counter: id} = m,
        %Optex.Aff{qterms: q} = aff,
        sense,
        rhs,
        opts
      )
      when q != %{} and sense in [:le, :ge, :eq] do
    qc = %Optex.QConstraint{
      id: id,
      name: Keyword.get(opts, :name),
      aff: %{aff | constant: 0.0},
      sense: sense,
      rhs: rhs - aff.constant
    }

    %{m | qconstraints: [qc | qcs], qcon_counter: id + 1}
  end

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

  @doc """
  Append the indicator constraint `bin = active -> aff SENSE rhs` and return
  the model. Solved natively by capable backends (Gurobi, CPLEX); backends
  without indicator support reject the model at solve time.

  `bin_ref` is a `%Optex.Var{}` or variable name and must refer to a `:bin`
  variable. Options: `:active_when` (1 default, or 0 for "when the binary is
  off"), `:name`.
  """
  def add_indicator_constraint(m, bin_ref, aff_or_terms, sense, rhs, opts \\ [])

  def add_indicator_constraint(%__MODULE__{} = m, bin_ref, %Optex.Aff{} = aff, sense, rhs, opts)
      when sense in [:le, :ge, :eq] do
    linear!(aff, "indicator constraints")
    bin = resolve_bin!(m, bin_ref)
    active = Keyword.get(opts, :active_when, 1)

    unless active in [0, 1] do
      raise ArgumentError, "active_when must be 0 or 1, got: #{inspect(active)}"
    end

    ind = %Optex.Indicator{
      id: m.ind_counter,
      name: Keyword.get(opts, :name),
      bin_id: bin.id,
      active_value: active,
      aff: %{aff | constant: 0.0},
      sense: sense,
      rhs: rhs - aff.constant
    }

    %{m | indicators: [ind | m.indicators], ind_counter: m.ind_counter + 1}
  end

  def add_indicator_constraint(%__MODULE__{} = m, bin_ref, terms, sense, rhs, opts)
      when is_list(terms) do
    add_indicator_constraint(m, bin_ref, resolve_terms(m, terms), sense, rhs, opts)
  end

  @doc """
  Define a variable equal to the absolute value of an affine expression and
  return `{var, model}`. Solved natively by capable backends (Gurobi, CPLEX);
  backends without abs support reject the model at solve time.

  The argument is a `%Optex.Var{}`, an `Optex.Aff`, or a terms list. When it
  is not already a bare variable, a free auxiliary variable pinned to the
  expression by an equality row is introduced (named `{name, :arg}`).
  Options: `:name`, plus variable options for the result (`:ub`; `:lb`
  defaults to 0.0 since the result is nonnegative).
  """
  def add_abs(%__MODULE__{} = m, arg, opts \\ []) do
    name = Keyword.get(opts, :name)
    var_opts = opts |> Keyword.delete(:name) |> Keyword.put_new(:lb, 0.0)

    {arg_id, m} =
      defined_arg!(
        m,
        arg,
        if(name, do: {name, :arg}),
        if(name, do: {name, :def}),
        "abs/pwl arguments"
      )

    {res, m} = add_variable(m, [name: name] ++ var_opts)

    {res, %{m | abs_defs: [{res.id, arg_id} | m.abs_defs]}}
  end

  @doc """
  Define a variable as a piecewise-linear function of an affine expression
  and return `{var, model}`. Solved natively by capable backends (Gurobi,
  CPLEX); backends without pwl support reject the model at solve time.

  `points` is a list of at least two `{x, y}` number pairs with
  non-decreasing x; consecutive points are joined by segments and the first
  and last segments extend beyond the breakpoint range. Exactly two
  consecutive points may share an x with different y values, defining a
  jump discontinuity; at the jump the function may take either y (the
  solver chooses, so an optimizer picks the favorable one). Jumps must be
  interior: the first and last point pairs need distinct x, since those
  segments define the extension slopes. The argument follows the
  same rules as `add_abs/3` (aux variable for non-bare expressions).
  Options: `:name`, plus variable options for the result (`:lb`/`:ub`
  default unbounded).
  """
  def add_pwl(%__MODULE__{} = m, arg, points, opts \\ []) do
    validate_points!(points)

    name = Keyword.get(opts, :name)

    var_opts =
      opts
      |> Keyword.delete(:name)
      |> Keyword.put_new(:lb, :neg_infinity)
      |> Keyword.put_new(:ub, :infinity)

    {arg_id, m} =
      defined_arg!(
        m,
        arg,
        if(name, do: {name, :arg}),
        if(name, do: {name, :def}),
        "abs/pwl arguments"
      )

    {res, m} = add_variable(m, [name: name] ++ var_opts)

    {xs, ys} = Enum.unzip(points)
    xs = Enum.map(xs, &(&1 * 1.0))
    ys = Enum.map(ys, &(&1 * 1.0))

    {res, %{m | pwl_defs: [{res.id, arg_id, xs, ys} | m.pwl_defs]}}
  end

  @doc """
  Define a variable equal to the minimum or maximum (`op`) of the given
  arguments and return `{var, model}`. Solved natively by capable backends
  (Gurobi only); backends without min/max support reject the model at solve
  time.

  Each argument is a `%Optex.Var{}`, an `Optex.Aff`, a terms list, or a
  number. Numeric arguments (and constant expressions) fold into a single
  constant operand; at least one variable argument is required. Non-bare
  expression arguments get free auxiliary variables pinned by equality rows,
  named `{name, {:arg, i}}` / `{name, {:def, i}}` by 0-based position among
  the expression arguments. Options: `:name`, plus variable options for the
  result (`:lb`/`:ub` default unbounded).
  """
  def add_minmax(%__MODULE__{} = m, op, args, opts \\ [])
      when op in [:min, :max] and is_list(args) do
    name = Keyword.get(opts, :name)

    var_opts =
      opts
      |> Keyword.delete(:name)
      |> Keyword.put_new(:lb, :neg_infinity)
      |> Keyword.put_new(:ub, :infinity)

    {constants, exprs} = Enum.split_with(args, &minmax_constant?/1)

    if exprs == [] do
      raise ArgumentError,
            "#{op} needs at least one variable argument; " <>
              "a #{op} of constants is a number, not a constraint"
    end

    constant =
      case Enum.map(constants, &minmax_constant_value/1) do
        [] -> nil
        values when op == :max -> Enum.max(values) * 1.0
        values when op == :min -> Enum.min(values) * 1.0
      end

    {rev_arg_ids, m} =
      exprs
      |> Enum.with_index()
      |> Enum.reduce({[], m}, fn {arg, i}, {ids, m} ->
        {id, m} =
          defined_arg!(
            m,
            arg,
            if(name, do: {name, {:arg, i}}),
            if(name, do: {name, {:def, i}}),
            "min/max arguments"
          )

        {[id | ids], m}
      end)

    arg_ids = Enum.reverse(rev_arg_ids)
    {res, m} = add_variable(m, [name: name] ++ var_opts)

    {res, %{m | minmax_defs: [{res.id, op, arg_ids, constant} | m.minmax_defs]}}
  end

  defp minmax_constant?(n) when is_number(n), do: true
  defp minmax_constant?(%Optex.Aff{terms: t, qterms: q}), do: t == %{} and q == %{}
  defp minmax_constant?(_), do: false

  defp minmax_constant_value(n) when is_number(n), do: n
  defp minmax_constant_value(%Optex.Aff{constant: c}), do: c

  defp validate_points!(points) do
    unless is_list(points) and length(points) >= 2 and
             Enum.all?(points, fn
               {x, y} -> is_number(x) and is_number(y)
               _ -> false
             end) do
      raise ArgumentError,
            "pwl points must be a list of at least two {x, y} number pairs, " <>
              "got: #{inspect(points)}"
    end

    xs = Enum.map(points, fn {x, _} -> x end)

    unless xs == Enum.sort(xs) do
      raise ArgumentError,
            "pwl breakpoints must have non-decreasing x values, got: #{inspect(xs)}"
    end

    # a jump is EXACTLY two consecutive breakpoints sharing an x with
    # different y values; three or more never mean anything
    if xs
       |> Enum.chunk_every(3, 1, :discard)
       |> Enum.any?(fn [a, b, c] -> a == b and b == c end) do
      raise ArgumentError,
            "pwl breakpoints allow at most two equal x values (a jump), got: #{inspect(xs)}"
    end

    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{x1, y1}, {x2, y2}] ->
      if x1 == x2 and y1 == y2 do
        raise ArgumentError,
              "a pwl jump must change y; drop the duplicate point {#{x1}, #{y1}}"
      end
    end)

    # jumps only interior: the first and last segments define the
    # out-of-range extension slopes, so they must be real segments
    [xa, xb | _] = xs
    [xy, xz] = Enum.take(xs, -2)

    if xa == xb or xy == xz do
      raise ArgumentError,
            "pwl jumps must be interior; the first and last segments define " <>
              "the extension slopes, got: #{inspect(xs)}"
    end
  end

  # a bare variable is used directly; anything else gets a free aux variable
  # pinned by an equality row, since native constructs relate variables.
  # Callers choose the aux/def names: {name, :arg} / {name, :def} for the
  # single-argument constructs (abs, pwl), {name, {:arg, i}} indexed for
  # min/max.
  defp defined_arg!(m, %Optex.Var{id: id}, _aux_name, _def_name, _where), do: {id, m}

  defp defined_arg!(m, arg, aux_name, def_name, where) do
    aff =
      case arg do
        %Optex.Aff{} = aff -> aff
        terms when is_list(terms) -> resolve_terms(m, terms)
      end

    linear!(aff, where)

    case {Map.to_list(aff.terms), aff.constant} do
      {[{id, coef}], c} when coef == 1.0 and c == 0.0 ->
        {id, m}

      _ ->
        {aux, m} = add_variable(m, name: aux_name, lb: :neg_infinity, ub: :infinity)

        m =
          add_constraint(
            m,
            Optex.Aff.add(Optex.Aff.from_var(aux), Optex.Aff.scale(aff, -1.0)),
            :eq,
            0.0,
            name: def_name
          )

        {aux.id, m}
    end
  end

  defp resolve_bin!(m, %Optex.Var{} = v) do
    case Map.fetch(m.vars, v.id) do
      {:ok, %Optex.Var{type: :bin} = bin} -> bin
      _ -> raise ArgumentError, "indicator variable must be a :bin variable, got: #{inspect(v)}"
    end
  end

  defp resolve_bin!(m, name) do
    case Map.fetch(m.name_index, name) do
      {:ok, id} -> resolve_bin!(m, Map.fetch!(m.vars, id))
      :error -> raise ArgumentError, "unknown variable name #{inspect(name)}"
    end
  end

  @doc """
  Set the objective (an `Optex.Aff` or a terms list) and the optimization
  sense (`:min` or `:max`), returning the model.
  """
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

  # Quadratic terms are only representable in the objective and in plain
  # constraints (which become quadratic constraints).
  defp linear!(%Optex.Aff{qterms: q}, where) when q != %{} do
    raise ArgumentError,
          "quadratic terms are not supported in #{where}; only the objective " <>
            "and plain constraints may be quadratic"
  end

  defp linear!(%Optex.Aff{}, _where), do: :ok

  # A binary variable is integer with bounds forced to [0, 1].
  defp normalize_var_opts(opts) do
    case Keyword.get(opts, :type, :cont) do
      :bin -> Keyword.merge(opts, lb: 0.0, ub: 1.0, type: :bin)
      _ -> opts
    end
  end
end
