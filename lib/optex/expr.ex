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
