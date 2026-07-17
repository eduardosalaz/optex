defmodule Optex.LP do
  @moduledoc """
  CPLEX-LP-format emitter for an `Optex.Model`, using sanitized versions of
  the user-facing variable and constraint names, so the file stays readable.

  This is a debugging/interop feature: the output can be inspected by hand or
  fed to any LP-reading solver. Names are sanitized to LP-safe identifiers
  (`y[1]` becomes `y_1`); collisions get an id suffix; unnamed variables and
  constraints fall back to `x<id>` / `c<id>`.
  """

  @doc """
  Emit an LP-format document for the given model. Models carrying native
  general constraints (indicators, abs) are not representable in this
  emitter's plain LP dialect and raise.
  """
  @spec emit(Optex.Model.t()) :: iodata()
  def emit(%Optex.Model{indicators: inds, abs_defs: defs, pwl_defs: pwls})
      when inds != [] or defs != [] or pwls != [] do
    raise ArgumentError, "cannot emit LP format for a model using native general constraints"
  end

  def emit(%Optex.Model{objective: %Optex.Aff{qterms: q}}) when q != %{} do
    raise ArgumentError, "cannot emit LP format for a model with a quadratic objective"
  end

  def emit(%Optex.Model{} = m) do
    var_names = build_names(vars_in_order(m), "x", & &1.name)
    cons = Enum.reverse(m.constraints)
    con_names = build_names(cons, "c", & &1.name)

    [
      sense_keyword(m.sense),
      " obj:",
      terms(m.objective.terms, var_names),
      obj_constant(m.objective.constant),
      "\nSubject To\n",
      Enum.map(cons, fn c ->
        [
          " ",
          Map.fetch!(con_names, c.id),
          ":",
          terms(c.aff.terms, var_names),
          " ",
          sense_op(c.sense),
          " ",
          num(c.rhs),
          "\n"
        ]
      end),
      "Bounds\n",
      Enum.flat_map(vars_in_order(m), &bound_line(&1, var_names)),
      type_section("General", m, :int, var_names),
      type_section("Binary", m, :bin, var_names),
      "End\n"
    ]
  end

  defp vars_in_order(%Optex.Model{vars: vars}) do
    vars |> Map.keys() |> Enum.sort() |> Enum.map(&Map.fetch!(vars, &1))
  end

  defp sense_keyword(:min), do: "Minimize\n"
  defp sense_keyword(:max), do: "Maximize\n"

  defp sense_op(:le), do: "<="
  defp sense_op(:ge), do: ">="
  defp sense_op(:eq), do: "="

  defp terms(terms_map, var_names) when map_size(terms_map) == 0, do: " 0 #{zero_var(var_names)}"

  defp terms(terms_map, var_names) do
    terms_map
    |> Enum.sort()
    |> Enum.map(fn {id, coef} ->
      [if(coef < 0, do: " - ", else: " + "), num(abs(coef * 1.0)), " ", Map.fetch!(var_names, id)]
    end)
  end

  # LP format cannot express an empty expression; anchor it on some variable
  # with coefficient zero (only used for empty objectives of nonempty models).
  defp zero_var(var_names) do
    case Map.fetch(var_names, 0) do
      {:ok, name} -> name
      :error -> "x0"
    end
  end

  defp obj_constant(c) when c == 0.0, do: []
  defp obj_constant(c) when c < 0, do: [" - ", num(abs(c * 1.0))]
  defp obj_constant(c), do: [" + ", num(c * 1.0)]

  defp bound_line(%Optex.Var{type: :bin}, _names), do: []

  defp bound_line(%Optex.Var{id: id, lb: lb, ub: ub}, names) do
    name = Map.fetch!(names, id)

    case {lb, ub} do
      {:neg_infinity, :infinity} -> [[" ", name, " free\n"]]
      {:neg_infinity, u} -> [[" -infinity <= ", name, " <= ", num(u), "\n"]]
      {l, :infinity} when l == 0.0 -> []
      {l, :infinity} -> [[" ", name, " >= ", num(l), "\n"]]
      {l, u} -> [[" ", num(l), " <= ", name, " <= ", num(u), "\n"]]
    end
  end

  defp type_section(keyword, m, type, var_names) do
    members =
      for v <- vars_in_order(m), v.type == type, do: [" ", Map.fetch!(var_names, v.id), "\n"]

    case members do
      [] -> []
      _ -> [keyword, "\n", members]
    end
  end

  # id => unique LP-safe identifier, derived from the user-facing name.
  defp build_names(items, fallback_prefix, name_fun) do
    {names, _taken} =
      Enum.reduce(items, {%{}, MapSet.new()}, fn item, {acc, taken} ->
        base =
          case name_fun.(item) do
            nil -> "#{fallback_prefix}#{item.id}"
            name -> sanitize(name)
          end

        unique = if MapSet.member?(taken, base), do: "#{base}_#{item.id}", else: base
        {Map.put(acc, item.id, unique), MapSet.put(taken, unique)}
      end)

    names
  end

  defp sanitize(name) do
    base =
      name
      |> name_to_string()
      |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
      |> String.trim("_")

    cond do
      base == "" ->
        "v"

      # LP names must not start with a digit or look like scientific notation
      not String.match?(base, ~r/^[A-Za-z]/) or String.match?(base, ~r/^[eE][0-9_]/) ->
        "v_" <> base

      true ->
        base
    end
  end

  defp name_to_string(name) when is_atom(name), do: Atom.to_string(name)
  defp name_to_string(name) when is_binary(name), do: name
  defp name_to_string(name), do: inspect(name)

  defp num(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, [:short])
end
