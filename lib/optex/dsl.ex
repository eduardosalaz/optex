defmodule Optex.DSL do
  @moduledoc """
  The modeling DSL: `model do ... end` with variable/constraint/objective.

      import Optex.DSL

      m =
        model sense: :min do
          variable x, lb: 0.0
          variable y[i], i <- [1, 2, 3], lb: 0.0
          variable z, type: :bin

          constraint 2 * x + sum(y[i], i <- [1, 2, 3]) <= 10
          constraint x - y[1] >= 0
          constraint sum(y[i], i <- [1, 2, 3], i > 1) == 4

          objective x + 2 * y[1] + z
        end

  Indexed families use one generator clause per index. A single index keys the
  family map by the bare index (`y[i]`); multiple indices use an explicit tuple
  key (`w[{i, j}]`, declared as `variable w[{i, j}], i <- 1..2, j <- 1..2`),
  because Elixir's parser rejects `w[i, j]` outright. Trailing options are
  evaluated once per binding with the generator variables in scope, so
  `lb:`/`ub:`/`type:` may depend on the index:

      variable x[{r, c}], r <- 1..9, c <- 1..9,
        type: :int,
        ub: (if given[{r, c}] == 0, do: 1.0, else: 0.0)

  Constraints accept the same trailing generator/filter clauses to declare a
  whole family at once, one constraint per binding:

      constraint sum(ship[{p, mk}], mk <- markets) <= supply[p], p <- plants
      constraint y[i] <= y[i + 1], i <- [1, 2]

  Two conventions worth knowing:

  - In `if: {b, 0}` (indicator active when the binary is off), a 2-tuple
    whose second element is the literal 0 or 1 is always read as the
    negation form. To reference an indexed binary in `if:`, use the access
    form (`if: open[s]`), never a raw name tuple.
  - Defined variables (`variable t = abs(e)` / `pwl(e, points)` /
    `max(args...)` / `min(args...)`) with non-bare arguments introduce
    machinery: a free auxiliary variable named `{t, :arg}` pinned by an
    equality row named `{t, :def}` (position-indexed `{t, {:arg, i}}` /
    `{t, {:def, i}}` for the multi-argument min/max forms). These are real
    model variables and appear in solution values (their value is the
    argument expression's value, often useful when debugging). min/max
    accept numbers among their arguments (folded into one constant operand)
    and are a Gurobi-only capability.
  """

  @doc """
  Build an `Optex.Model` declaratively. See the module docs for the full
  surface. Options: `sense:` (`:min` default, `:max`). The block may contain
  only `variable`, `constraint`, and `objective` statements and returns the
  finished model.
  """
  defmacro model(opts \\ [], do: block) do
    stmts = block_to_list(block)
    # hygienic threaded model var
    m = Macro.unique_var(:model, __MODULE__)
    sense = Keyword.get(opts, :sense, :min)

    body =
      Enum.map(stmts, fn
        {:variable, _, _} = s ->
          rewrite_variable(s, m)

        {:constraint, _, _} = s ->
          rewrite_constraint(s, m)

        {:objective, _, _} = s ->
          rewrite_objective(s, m, sense)

        other ->
          raise ArgumentError,
                "only variable/constraint/objective statements are allowed in a model block, " <>
                  "got: #{Macro.to_string(other)}"
      end)

    quote do
      unquote(m) = Optex.Model.new()
      unquote_splicing(body)
      unquote(m)
    end
  end

  # ---- defined variable: variable t = abs(expr), opts ----
  # native absolute value: t equals |expr| exactly, via the backend's own
  # general constraint (capable backends only, never reformulated)
  defp rewrite_variable(
         {:variable, _, [{:=, _, [{name, _, ctx}, {:abs, _, [e]}]} | rest]},
         m
       )
       when is_atom(name) and is_atom(ctx) do
    {clauses, opts} = split_clauses_opts(rest)

    if clauses != [] do
      raise ArgumentError,
            "a scalar defined variable takes no generators; index it: " <>
              "variable #{name}[i] = abs(...), i <- ..."
    end

    user_var = Macro.var(name, nil)
    e_aff = Optex.Expr.build(e)

    quote do
      {unquote(user_var), unquote(m)} =
        Optex.Model.add_abs(unquote(m), unquote(e_aff), [name: unquote(name)] ++ unquote(opts))
    end
  end

  # ---- defined variable, indexed: variable t[key] = abs(expr), gens, opts ----
  defp rewrite_variable(
         {:variable, _,
          [
            {:=, _, [{{:., _, [Access, :get]}, _, [{name, _, ctx}, key_ast]}, {:abs, _, [e]}]}
            | rest
          ]},
         m
       )
       when is_atom(name) and is_atom(ctx) do
    {clauses, opts} = split_clauses_opts(rest)

    if clauses == [] do
      raise ArgumentError,
            "indexed defined variable #{name} needs at least one generator"
    end

    user_var = Macro.var(name, nil)
    e_aff = Optex.Expr.build(e)

    quote do
      {unquote(user_var), unquote(m)} =
        Enum.reduce(
          for(unquote_splicing(clauses), do: {unquote(key_ast), unquote(e_aff), unquote(opts)}),
          {%{}, unquote(m)},
          fn {key, e_aff, opts}, {acc, model} ->
            {v, model} =
              Optex.Model.add_abs(model, e_aff, [name: {unquote(name), key}] ++ opts)

            {Map.put(acc, key, v), model}
          end
        )
    end
  end

  # ---- defined variable: variable y = pwl(expr, points), opts ----
  # native piecewise-linear function of an affine expression; points is any
  # runtime expression yielding [{x, y}] pairs with non-decreasing x
  # (an interior repeated x with different ys is a jump discontinuity)
  defp rewrite_variable(
         {:variable, _, [{:=, _, [{name, _, ctx}, {:pwl, _, [e, points]}]} | rest]},
         m
       )
       when is_atom(name) and is_atom(ctx) do
    {clauses, opts} = split_clauses_opts(rest)

    if clauses != [] do
      raise ArgumentError,
            "a scalar defined variable takes no generators; index it: " <>
              "variable #{name}[i] = pwl(...), i <- ..."
    end

    user_var = Macro.var(name, nil)
    e_aff = Optex.Expr.build(e)

    quote do
      {unquote(user_var), unquote(m)} =
        Optex.Model.add_pwl(
          unquote(m),
          unquote(e_aff),
          unquote(points),
          [name: unquote(name)] ++ unquote(opts)
        )
    end
  end

  # ---- defined variable, indexed: variable y[key] = pwl(expr, points) ----
  defp rewrite_variable(
         {:variable, _,
          [
            {:=, _,
             [{{:., _, [Access, :get]}, _, [{name, _, ctx}, key_ast]}, {:pwl, _, [e, points]}]}
            | rest
          ]},
         m
       )
       when is_atom(name) and is_atom(ctx) do
    {clauses, opts} = split_clauses_opts(rest)

    if clauses == [] do
      raise ArgumentError,
            "indexed defined variable #{name} needs at least one generator"
    end

    user_var = Macro.var(name, nil)
    e_aff = Optex.Expr.build(e)

    quote do
      {unquote(user_var), unquote(m)} =
        Enum.reduce(
          for(
            unquote_splicing(clauses),
            do: {unquote(key_ast), unquote(e_aff), unquote(points), unquote(opts)}
          ),
          {%{}, unquote(m)},
          fn {key, e_aff, points, opts}, {acc, model} ->
            {v, model} =
              Optex.Model.add_pwl(
                model,
                e_aff,
                points,
                [name: {unquote(name), key}] ++ opts
              )

            {Map.put(acc, key, v), model}
          end
        )
    end
  end

  # ---- defined variable: variable m = max(args...) / min(args...) ----
  # native min/max of affine expressions and constants (Gurobi-only
  # capability; other backends reject at solve time, never reformulated)
  defp rewrite_variable(
         {:variable, _, [{:=, _, [{name, _, ctx}, {special, _, args}]} | rest]},
         m
       )
       when special in [:max, :min] and is_atom(name) and is_atom(ctx) and is_list(args) and
              args != [] do
    {clauses, opts} = split_clauses_opts(rest)

    if clauses != [] do
      raise ArgumentError,
            "a scalar defined variable takes no generators; index it: " <>
              "variable #{name}[i] = #{special}(...), i <- ..."
    end

    user_var = Macro.var(name, nil)
    arg_affs = Enum.map(args, &Optex.Expr.build/1)

    quote do
      {unquote(user_var), unquote(m)} =
        Optex.Model.add_minmax(
          unquote(m),
          unquote(special),
          [unquote_splicing(arg_affs)],
          [name: unquote(name)] ++ unquote(opts)
        )
    end
  end

  # ---- defined variable, indexed: variable m[key] = max(args...), gens ----
  defp rewrite_variable(
         {:variable, _,
          [
            {:=, _, [{{:., _, [Access, :get]}, _, [{name, _, ctx}, key_ast]}, {special, _, args}]}
            | rest
          ]},
         m
       )
       when special in [:max, :min] and is_atom(name) and is_atom(ctx) and is_list(args) and
              args != [] do
    {clauses, opts} = split_clauses_opts(rest)

    if clauses == [] do
      raise ArgumentError,
            "indexed defined variable #{name} needs at least one generator"
    end

    user_var = Macro.var(name, nil)
    arg_affs = Enum.map(args, &Optex.Expr.build/1)

    quote do
      {unquote(user_var), unquote(m)} =
        Enum.reduce(
          for(
            unquote_splicing(clauses),
            do: {unquote(key_ast), [unquote_splicing(arg_affs)], unquote(opts)}
          ),
          {%{}, unquote(m)},
          fn {key, args, opts}, {acc, model} ->
            {v, model} =
              Optex.Model.add_minmax(
                model,
                unquote(special),
                args,
                [name: {unquote(name), key}] ++ opts
              )

            {Map.put(acc, key, v), model}
          end
        )
    end
  end

  # norm defines a cone CONSTRAINT, not a variable; point at the spelling
  defp rewrite_variable({:variable, _, [{:=, _, [_, {:norm, _, args}]} | _]}, _m)
       when is_list(args) do
    raise ArgumentError,
          "norm is a constraint, not a defined variable: declare the bound " <>
            "variable yourself and write constraint norm(...) <= t"
  end

  # common misspellings of the defined min/max forms get a pointer, not a
  # confusing FunctionClauseError
  defp rewrite_variable({:variable, _, [{:=, _, [_, {special, _, args}]} | _]}, _m)
       when special in [:maxi, :mini] and is_list(args) do
    correct = if special == :maxi, do: "max", else: "min"

    raise ArgumentError,
          "variable t = #{special}(...) is not supported; native min/max are " <>
            "spelled variable t = #{correct}(...)"
  end

  # ---- variable, indexed: variable name[key], gen_or_filter..., opts ----
  defp rewrite_variable(
         {:variable, _, [{{:., _, [Access, :get]}, _, [{name, _, ctx}, key_ast]} | rest]},
         m
       )
       when is_atom(name) and is_atom(ctx) do
    {clauses, opts} = split_clauses_opts(rest)

    if clauses == [] do
      raise ArgumentError,
            "indexed variable #{name} needs at least one generator, " <>
              "e.g. `variable #{name}[i], i <- 1..3`"
    end

    # deliberately UNhygienic: leaks to user scope
    user_var = Macro.var(name, nil)

    # opts is spliced into the comprehension body (same shape as constraint
    # families) so lb:/ub:/type: may reference the generator variables and
    # vary per binding
    quote do
      {unquote(user_var), unquote(m)} =
        Enum.reduce(
          for(unquote_splicing(clauses), do: {unquote(key_ast), unquote(opts)}),
          {%{}, unquote(m)},
          fn {key, opts}, {acc, model} ->
            {v, model} = Optex.Model.add_variable(model, [name: {unquote(name), key}] ++ opts)

            {Map.put(acc, key, v), model}
          end
        )
    end
  end

  # ---- variable, scalar: variable name, opts ----
  defp rewrite_variable({:variable, _, [name_ast | rest]}, m) do
    name = var_name(name_ast)
    opts = List.first(rest) || []
    user_var = Macro.var(name, nil)

    quote do
      {unquote(user_var), unquote(m)} =
        Optex.Model.add_variable(unquote(m), [name: unquote(name)] ++ unquote(opts))
    end
  end

  # ---- constraint: constraint lhs OP rhs, gen_or_filter..., opts ----
  # Trailing generator/filter clauses declare a family, one constraint per
  # binding. A trailing name: option names the row; in a family the name
  # expression is evaluated per binding and may reference the generator
  # variables. An if: option turns the row into a native indicator
  # constraint (if: b for "when b = 1", if: {b, 0} for "when b = 0"),
  # solved only by capable backends:
  #   constraint 2 * t + c <= 40, name: :carpentry
  #   constraint sum(ship[{p, mk}], mk <- markets) <= supply[p],
  #     p <- plants, name: {:supply, p}
  #   constraint ship[s] <= cap[s], s <- sites, if: open[s]
  # ---- SOS constraint: constraint sos1([{x, 1}, {y, 2}]), gens?, opts ----
  # members is any runtime expression yielding {variable, weight} pairs;
  # trailing generators declare a family, name: evaluated per binding
  defp rewrite_constraint({:constraint, _, [{sos, _, [members]} | rest]}, m)
       when sos in [:sos1, :sos2] do
    {clauses, opts} = split_clauses_opts(rest)

    case clauses do
      [] ->
        quote do
          unquote(m) =
            Optex.Model.add_sos(unquote(m), unquote(sos), unquote(members), unquote(opts))
        end

      _ ->
        quote do
          unquote(m) =
            Enum.reduce(
              for(unquote_splicing(clauses), do: {unquote(members), unquote(opts)}),
              unquote(m),
              fn {members, opts}, model ->
                Optex.Model.add_sos(model, unquote(sos), members, opts)
              end
            )
        end
    end
  end

  # ---- cone constraint: constraint norm(e...) <= rhs (or rhs >= norm) ----
  # a second-order cone: rhs >= sqrt(sum e^2); member expressions get aux
  # variables via the defined-argument machinery, a non-variable rhs gets a
  # lb-0.0 head aux (exact: the cone forces its head nonnegative anyway)
  defp rewrite_constraint(
         {:constraint, _, [{:<=, _, [{:norm, _, args}, rhs]} | rest]},
         m
       )
       when is_list(args) and args != [] do
    rewrite_norm_constraint(m, args, rhs, rest)
  end

  defp rewrite_constraint(
         {:constraint, _, [{:>=, _, [rhs, {:norm, _, args}]} | rest]},
         m
       )
       when is_list(args) and args != [] do
    rewrite_norm_constraint(m, args, rhs, rest)
  end

  defp rewrite_constraint({:constraint, _, [{op, _, [lhs, rhs]} | rest]}, m)
       when op in [:<=, :>=, :==] do
    sense = op_to_sense(op)
    {clauses, opts} = split_clauses_opts(rest)
    {if_ast, opts} = Keyword.pop(opts, :if)

    if Keyword.has_key?(opts, :bound) do
      raise ArgumentError,
            "constraint does not take bound:; indicator constraints are native " <>
              "and need no big-M"
    end

    aff = Optex.Expr.build(quote(do: unquote(lhs) - unquote(rhs)))

    case if_ast do
      nil -> rewrite_plain_constraint(m, aff, sense, opts, clauses)
      _ -> rewrite_indicator_constraint(m, aff, sense, opts, clauses, if_ast)
    end
  end

  defp rewrite_norm_constraint(m, member_asts, rhs_ast, rest) do
    {clauses, opts} = split_clauses_opts(rest)
    member_affs = Enum.map(member_asts, &Optex.Expr.build/1)
    rhs_aff = Optex.Expr.build(rhs_ast)

    case clauses do
      [] ->
        quote do
          unquote(m) =
            Optex.Model.add_norm_constraint(
              unquote(m),
              [unquote_splicing(member_affs)],
              unquote(rhs_aff),
              unquote(opts)
            )
        end

      _ ->
        quote do
          unquote(m) =
            Enum.reduce(
              for(
                unquote_splicing(clauses),
                do: {[unquote_splicing(member_affs)], unquote(rhs_aff), unquote(opts)}
              ),
              unquote(m),
              fn {members, rhs, opts}, model ->
                Optex.Model.add_norm_constraint(model, members, rhs, opts)
              end
            )
        end
    end
  end

  defp rewrite_plain_constraint(m, aff, sense, opts, []) do
    quote do
      unquote(m) =
        Optex.Model.add_constraint(unquote(m), unquote(aff), unquote(sense), 0.0, unquote(opts))
    end
  end

  defp rewrite_plain_constraint(m, aff, sense, opts, clauses) do
    quote do
      unquote(m) =
        Enum.reduce(
          for(unquote_splicing(clauses), do: {unquote(aff), unquote(opts)}),
          unquote(m),
          fn {aff, opts}, model ->
            Optex.Model.add_constraint(model, aff, unquote(sense), 0.0, opts)
          end
        )
    end
  end

  defp rewrite_indicator_constraint(m, aff, sense, opts, clauses, if_ast) do
    {bin_ast, active} =
      case if_ast do
        {bin_ast, active} when active in [0, 1] -> {bin_ast, active}
        bin_ast -> {bin_ast, 1}
      end

    ind_opts = [active_when: active] ++ opts

    if clauses == [] do
      quote do
        unquote(m) =
          Optex.Model.add_indicator_constraint(
            unquote(m),
            unquote(bin_ast),
            unquote(aff),
            unquote(sense),
            0.0,
            unquote(ind_opts)
          )
      end
    else
      quote do
        unquote(m) =
          Enum.reduce(
            for(
              unquote_splicing(clauses),
              do: {unquote(aff), unquote(bin_ast), unquote(ind_opts)}
            ),
            unquote(m),
            fn {aff, bin, opts}, model ->
              Optex.Model.add_indicator_constraint(model, bin, aff, unquote(sense), 0.0, opts)
            end
          )
      end
    end
  end

  # ---- objective: objective expr ----
  defp rewrite_objective({:objective, _, [expr]}, m, sense) do
    aff = Optex.Expr.build(expr)

    quote do
      unquote(m) = Optex.Model.set_objective(unquote(m), unquote(aff), unquote(sense))
    end
  end

  # ---- helpers ----
  defp op_to_sense(:<=), do: :le
  defp op_to_sense(:>=), do: :ge
  defp op_to_sense(:==), do: :eq

  defp block_to_list({:__block__, _, stmts}), do: stmts
  defp block_to_list(single), do: [single]

  # `variable x` parses as a bare var AST node {:x, meta, ctx}
  defp var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name

  # A trailing literal keyword list is the opts; everything before it is
  # generator/filter clauses for the index comprehension.
  defp split_clauses_opts(rest) do
    case List.last(rest) do
      kw when is_list(kw) ->
        if Keyword.keyword?(kw) do
          {List.delete_at(rest, -1), kw}
        else
          {rest, []}
        end

      _ ->
        {rest, []}
    end
  end
end
