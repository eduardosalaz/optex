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
  because Elixir's parser rejects `w[i, j]` outright.

  Constraints accept the same trailing generator/filter clauses to declare a
  whole family at once, one constraint per binding:

      constraint sum(ship[{p, mk}], mk <- markets) <= supply[p], p <- plants
      constraint y[i] <= y[i + 1], i <- [1, 2]
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

    quote do
      {unquote(user_var), unquote(m)} =
        Enum.reduce(
          for(unquote_splicing(clauses), do: unquote(key_ast)),
          {%{}, unquote(m)},
          fn key, {acc, model} ->
            {v, model} =
              Optex.Model.add_variable(model, [name: {unquote(name), key}] ++ unquote(opts))

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
  # variables:
  #   constraint 2 * t + c <= 40, name: :carpentry
  #   constraint sum(ship[{p, mk}], mk <- markets) <= supply[p],
  #     p <- plants, name: {:supply, p}
  defp rewrite_constraint({:constraint, _, [{op, _, [lhs, rhs]} | rest]}, m)
       when op in [:<=, :>=, :==] do
    sense = op_to_sense(op)
    {clauses, opts} = split_clauses_opts(rest)
    aff = Optex.Expr.build(quote(do: unquote(lhs) - unquote(rhs)))

    if clauses == [] do
      quote do
        unquote(m) =
          Optex.Model.add_constraint(unquote(m), unquote(aff), unquote(sense), 0.0, unquote(opts))
      end
    else
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
