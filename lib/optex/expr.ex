defmodule Optex.Expr do
  @moduledoc "Compile-time translation of arithmetic-looking AST into Aff-building code."

  def build(ast), do: walk(ast)

  # sum(for i <- enum, filter, do: expr) - a literal comprehension argument.
  defp walk({:sum, _, [{:for, _, clauses}]}) do
    {[do: body], gens} = List.pop_at(clauses, -1)
    sum_code(gens, body)
  end

  # sum(expr, gen_or_filter, ...) - comma-separated comprehension clauses.
  # The spec's `sum(expr for gen)` juxtaposition is a parse error in Elixir,
  # so generators and filters follow the body as ordinary arguments.
  defp walk({:sum, _, [body | clauses]}) when clauses != [] do
    sum_code(clauses, body)
  end

  defp walk({:+, _, [a, b]}),
    do: quote(do: Optex.Aff.add(unquote(walk(a)), unquote(walk(b))))

  defp walk({:-, _, [a, b]}),
    do: quote(do: Optex.Aff.add(unquote(walk(a)), Optex.Aff.scale(unquote(walk(b)), -1.0)))

  defp walk({:-, _, [a]}),
    do: quote(do: Optex.Aff.scale(unquote(walk(a)), -1.0))

  # literal coefficient on the LEFT: 2 * expr
  defp walk({:*, _, [coef, e]}) when is_number(coef),
    do: quote(do: Optex.Aff.scale(unquote(walk(e)), unquote(coef)))

  # literal coefficient on the RIGHT: expr * 2
  defp walk({:*, _, [e, coef]}) when is_number(coef),
    do: quote(do: Optex.Aff.scale(unquote(walk(e)), unquote(coef)))

  # neither side a literal: resolve at runtime (runtime coefficient, or nonlinear -> raise)
  defp walk({:*, _, [a, b]}),
    do: quote(do: Optex.Aff.mul(unquote(walk(a)), unquote(walk(b))))

  # abs/min/max cannot appear inside a linear expression: abs is handled by
  # the defined-variable statement (variable t = abs(e)), and Kernel.max/min
  # of two %Var{} structs would silently compare structs and build a wrong
  # model. Reject loudly; numeric data max/min belongs outside the model.
  defp walk({special, _, [_, _ | _] = _args}) when special in [:max, :min] do
    raise ArgumentError,
          "#{special} is not supported inside model expressions (Kernel.#{special} " <>
            "would silently compare variable structs); define it as a " <>
            "variable first: variable m = #{special}(...), then use m, or " <>
            "compute numeric data outside the model block"
  end

  defp walk({:abs, _, [_]}) do
    raise ArgumentError,
          "abs is not supported inside a larger expression; define it as a " <>
            "variable first: variable t = abs(...), then use t"
  end

  defp walk({:pwl, _, [_, _]}) do
    raise ArgumentError,
          "pwl is not supported inside a larger expression; define it as a " <>
            "variable first: variable y = pwl(x, points), then use y"
  end

  defp walk({special, _, [_]}) when special in [:sos1, :sos2] do
    raise ArgumentError,
          "#{special} is not a term; declare it as its own constraint: " <>
            "constraint #{special}([{x, 1.0}, {y, 2.0}])"
  end

  defp walk({:norm, _, args}) when is_list(args) do
    raise ArgumentError,
          "norm only appears as its own constraint: constraint norm(exprs...) <= bound " <>
            "(a second-order cone); it cannot be used inside a larger expression " <>
            "or with any other comparison"
  end

  # a leaf: variable, number, or already an Aff - normalized at runtime
  defp walk(leaf),
    do: quote(do: Optex.Aff.to_aff(unquote(leaf)))

  defp sum_code(clauses, body) do
    body_code = walk(body)

    quote do
      Enum.reduce(
        for(unquote_splicing(clauses), do: unquote(body_code)),
        %Optex.Aff{},
        &Optex.Aff.add/2
      )
    end
  end
end
