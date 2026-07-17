defmodule Optex.Format do
  @moduledoc """
  Human-readable rendering of an `Optex.Model` using the user-facing names as
  written (`y[1]`, `w[{1, :a}]`). Answers "what did my model block actually
  build?"; for a solver-parseable file see `Optex.LP`.
  """

  @doc "Render the model as a readable multi-line string."
  @spec pretty(Optex.Model.t()) :: String.t()
  def pretty(%Optex.Model{} = m) do
    vars = m.vars |> Map.keys() |> Enum.sort() |> Enum.map(&Map.fetch!(m.vars, &1))
    cons = Enum.reverse(m.constraints)

    IO.iodata_to_binary([
      Atom.to_string(m.sense),
      " ",
      expr(m.objective, m),
      "\nsubject to\n",
      Enum.map(cons, fn c ->
        [
          "  ",
          con_label(c),
          expr(c.aff, m),
          " ",
          sense_op(c.sense),
          " ",
          num(c.rhs),
          "\n"
        ]
      end),
      indicator_section(m),
      abs_section(m),
      "bounds\n",
      Enum.map(vars, &var_line/1)
    ])
  end

  defp indicator_section(%Optex.Model{indicators: []}), do: []

  defp indicator_section(%Optex.Model{indicators: inds} = m) do
    [
      "indicators\n",
      inds
      |> Enum.reverse()
      |> Enum.map(fn ind ->
        [
          "  ",
          ind_label(ind),
          var_display(m, ind.bin_id),
          " = ",
          Integer.to_string(ind.active_value),
          " -> ",
          expr(ind.aff, m),
          " ",
          sense_op(ind.sense),
          " ",
          num(ind.rhs),
          "\n"
        ]
      end)
    ]
  end

  defp ind_label(%Optex.Indicator{name: nil}), do: []
  defp ind_label(%Optex.Indicator{name: name}), do: [display_name(name), ": "]

  defp abs_section(%Optex.Model{abs_defs: []}), do: []

  defp abs_section(%Optex.Model{abs_defs: defs} = m) do
    [
      "definitions\n",
      defs
      |> Enum.reverse()
      |> Enum.map(fn {res, arg} ->
        ["  ", var_display(m, res), " = |", var_display(m, arg), "|\n"]
      end)
    ]
  end

  defp con_label(%Optex.Constraint{name: nil, id: id}), do: ["c", Integer.to_string(id), ": "]
  defp con_label(%Optex.Constraint{name: name}), do: [display_name(name), ": "]

  defp expr(%Optex.Aff{terms: terms, constant: c}, m) do
    rendered =
      terms
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.map(fn {{id, coef}, i} -> term(coef, var_display(m, id), i) end)

    case {rendered, c} do
      {[], k} when k == 0.0 -> "0"
      {[], k} -> num(k)
      {parts, k} when k == 0.0 -> parts
      {parts, k} when k < 0 -> [parts, " - ", num(abs(k * 1.0))]
      {parts, k} -> [parts, " + ", num(k * 1.0)]
    end
  end

  defp term(coef, name, 0) when coef < 0, do: ["-", coef_prefix(abs(coef * 1.0)), name]
  defp term(coef, name, 0), do: [coef_prefix(coef * 1.0), name]
  defp term(coef, name, _i) when coef < 0, do: [" - ", coef_prefix(abs(coef * 1.0)), name]
  defp term(coef, name, _i), do: [" + ", coef_prefix(coef * 1.0), name]

  defp coef_prefix(c) when c == 1.0, do: []
  defp coef_prefix(c), do: [num(c), " "]

  defp var_display(%Optex.Model{vars: vars}, id) do
    case Map.fetch!(vars, id) do
      %Optex.Var{name: nil} -> "x#{id}"
      %Optex.Var{name: name} -> display_name(name)
    end
  end

  # {:y, 1} renders as y[1], {:w, {1, :a}} as w[{1, :a}]; anything else is
  # inspected as-is
  defp display_name(name) when is_atom(name), do: Atom.to_string(name)

  defp display_name({family, index}) when is_atom(family),
    do: "#{family}[#{inspect(index)}]"

  defp display_name(name), do: inspect(name)

  defp var_line(%Optex.Var{type: :bin} = v), do: ["  ", var_name(v), " binary\n"]

  defp var_line(%Optex.Var{type: type, lb: lb, ub: ub} = v) do
    int = if type == :int, do: " integer", else: ""

    range =
      case {lb, ub} do
        {:neg_infinity, :infinity} -> " free"
        {l, :infinity} -> [" >= ", num(l)]
        {:neg_infinity, u} -> [" <= ", num(u)]
        {l, u} -> [" in [", num(l), ", ", num(u), "]"]
      end

    ["  ", var_name(v), int, range, "\n"]
  end

  defp var_name(%Optex.Var{name: nil, id: id}), do: "x#{id}"
  defp var_name(%Optex.Var{name: name}), do: display_name(name)

  defp sense_op(:le), do: "<="
  defp sense_op(:ge), do: ">="
  defp sense_op(:eq), do: "="

  # integral values render without the trailing .0; this output is for humans
  defp num(v) when is_number(v) do
    f = v * 1.0
    t = trunc(f)

    if t * 1.0 == f do
      Integer.to_string(t)
    else
      :erlang.float_to_binary(f, [:short])
    end
  end
end
