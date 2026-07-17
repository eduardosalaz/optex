defmodule Optex.Transform do
  @moduledoc "The one-time transform from a neutral Model to column-sparse SolverInput."

  @doc "Build a SolverInput from a neutral Model. Pure; no solver knowledge."
  def to_solver_input(%Optex.Model{} = m) do
    # variable ids are already contiguous 0..n-1, so index == id. Sort to be safe.
    var_ids = m.vars |> Map.keys() |> Enum.sort()
    n = length(var_ids)
    vars = Enum.map(var_ids, &Map.fetch!(m.vars, &1))

    obj = Enum.map(var_ids, fn id -> Map.get(m.objective.terms, id, 0.0) end)
    col_lb = Enum.map(vars, & &1.lb)
    col_ub = Enum.map(vars, & &1.ub)
    col_type = Enum.map(vars, & &1.type)

    cons = Enum.reverse(m.constraints)
    mrows = length(cons)

    {row_lb, row_ub} =
      cons
      |> Enum.map(fn c -> sense_to_range(c.sense, c.rhs) end)
      |> Enum.unzip()

    # (col, row, value) triplets; duplicates in the same cell are SUMMED (canonical form)
    triplets =
      cons
      |> Enum.with_index()
      |> Enum.flat_map(fn {c, row} ->
        Enum.map(c.aff.terms, fn {var_id, coef} -> {var_id, row, coef} end)
      end)

    by_col =
      triplets
      |> Enum.group_by(fn {col, _r, _v} -> col end)
      |> Map.new(fn {col, ts} ->
        summed =
          ts
          |> Enum.group_by(fn {_c, r, _v} -> r end)
          |> Enum.map(fn {r, group} ->
            {r, Enum.reduce(group, 0.0, fn {_c, _r, v}, acc -> acc + v end)}
          end)
          |> Enum.sort_by(fn {r, _v} -> r end)

        {col, summed}
      end)

    {col_start, row_index, values} = build_csc(by_col, n)

    %Optex.SolverInput{
      num_vars: n,
      num_cons: mrows,
      sense: m.sense,
      obj: obj,
      obj_offset: m.objective.constant * 1.0,
      col_lb: col_lb,
      col_ub: col_ub,
      col_type: col_type,
      col_start: col_start,
      row_index: row_index,
      values: values,
      row_lb: row_lb,
      row_ub: row_ub,
      indicators: m.indicators |> Enum.reverse() |> Enum.map(&indicator_row/1),
      abs_defs: Enum.reverse(m.abs_defs)
    }
  end

  defp indicator_row(%Optex.Indicator{} = ind) do
    {cols, coefs} = ind.aff.terms |> Enum.sort() |> Enum.unzip()

    %Optex.SolverInput.Indicator{
      bin_col: ind.bin_id,
      active_value: ind.active_value,
      cols: cols,
      coefs: Enum.map(coefs, &(&1 * 1.0)),
      sense: ind.sense,
      rhs: ind.rhs * 1.0
    }
  end

  defp sense_to_range(:le, rhs), do: {:neg_infinity, rhs}
  defp sense_to_range(:ge, rhs), do: {rhs, :infinity}
  defp sense_to_range(:eq, rhs), do: {rhs, rhs}

  # col_start is a prefix-sum of per-column entry counts; length n+1, last = nnz.
  defp build_csc(by_col, n) do
    {starts_rev, rows_rev, vals_rev} =
      Enum.reduce(0..(n - 1)//1, {[0], [], []}, fn col, {[top | _] = starts, rows, vals} ->
        entries = Map.get(by_col, col, [])

        {rows2, vals2} =
          Enum.reduce(entries, {rows, vals}, fn {r, v}, {rs, vs} -> {[r | rs], [v | vs]} end)

        {[top + length(entries) | starts], rows2, vals2}
      end)

    {Enum.reverse(starts_rev), Enum.reverse(rows_rev), Enum.reverse(vals_rev)}
  end
end
