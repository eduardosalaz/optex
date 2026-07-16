defmodule Optex.MPS do
  @moduledoc """
  Minimal free-format MPS emitter for a `Optex.SolverInput`.

  This is a validation/debugging path, not a user feature: a model emitted to
  MPS and solved by a standalone HiGHS binary must give the same objective as
  the NIF path. Rows are named R0..R(m-1), columns X0..X(n-1), objective OBJ.
  """

  @doc "Emit a free-format MPS document for the given SolverInput."
  @spec emit(Optex.SolverInput.t()) :: iodata()
  def emit(%Optex.SolverInput{} = input) do
    rows = Enum.zip(input.row_lb, input.row_ub) |> Enum.with_index()

    [
      "NAME optex\n",
      objsense(input.sense),
      "ROWS\n N OBJ\n",
      Enum.map(rows, &row_decl/1),
      "COLUMNS\n",
      columns(input),
      "RHS\n",
      Enum.map(rows, &rhs_entry/1),
      ranges(rows),
      "BOUNDS\n",
      bounds(input),
      "ENDATA\n"
    ]
  end

  defp objsense(:min), do: []
  defp objsense(:max), do: "OBJSENSE\n MAXIMIZE\n"

  # Row type from its range. Two-sided rows are L rows with a RANGES entry.
  defp row_type({:neg_infinity, :infinity}), do: :n
  defp row_type({:neg_infinity, _ub}), do: :l
  defp row_type({lb, :infinity}) when is_number(lb), do: :g
  defp row_type({lb, ub}) when lb == ub, do: :e
  defp row_type({lb, ub}) when is_number(lb) and is_number(ub), do: :ranged

  defp row_decl({range, i}) do
    letter =
      case row_type(range) do
        :n -> "N"
        :l -> "L"
        :g -> "G"
        :e -> "E"
        :ranged -> "L"
      end

    [" ", letter, " R", Integer.to_string(i), "\n"]
  end

  defp rhs_entry({range, i}) do
    case row_type(range) do
      :n -> []
      :l -> rhs_line(i, elem(range, 1))
      :ranged -> rhs_line(i, elem(range, 1))
      :g -> rhs_line(i, elem(range, 0))
      :e -> rhs_line(i, elem(range, 0))
    end
  end

  defp rhs_line(i, v), do: [" RHS R", Integer.to_string(i), " ", num(v), "\n"]

  defp ranges(rows) do
    entries =
      for {{lb, ub} = range, i} <- rows, row_type(range) == :ranged do
        [" RNG R", Integer.to_string(i), " ", num(ub - lb), "\n"]
      end

    case entries do
      [] -> []
      _ -> ["RANGES\n", entries]
    end
  end

  # One block per column, wrapped in INTORG/INTEND markers when integral.
  # The objective entry is always emitted so every column is declared even
  # when it appears in no constraint.
  defp columns(%Optex.SolverInput{} = input) do
    col_entries =
      Enum.zip([input.obj, input.col_type, 0..max(input.num_vars - 1, 0)//1])
      |> Enum.map(fn {obj_coef, type, j} ->
        name = col_name(j)
        lo = input.col_start |> Enum.at(j)
        hi = input.col_start |> Enum.at(j + 1)

        matrix_lines =
          for k <- lo..(hi - 1)//1 do
            row = Enum.at(input.row_index, k)
            val = Enum.at(input.values, k)
            [" ", name, " R", Integer.to_string(row), " ", num(val), "\n"]
          end

        block = [[" ", name, " OBJ ", num(obj_coef), "\n"], matrix_lines]

        if type in [:int, :bin] do
          [
            " MARKER 'MARKER' 'INTORG'\n",
            block,
            " MARKER 'MARKER' 'INTEND'\n"
          ]
        else
          block
        end
      end)

    if input.num_vars == 0, do: [], else: col_entries
  end

  defp bounds(%Optex.SolverInput{} = input) do
    Enum.zip([input.col_lb, input.col_ub, input.col_type, 0..max(input.num_vars - 1, 0)//1])
    |> Enum.map(fn
      {_lb, _ub, :bin, j} ->
        # binary bounds were forced to [0, 1] at creation; BV says exactly that
        [" BV BND ", col_name(j), "\n"]

      {:neg_infinity, :infinity, _type, j} ->
        [" FR BND ", col_name(j), "\n"]

      {:neg_infinity, ub, _type, j} ->
        [[" MI BND ", col_name(j), "\n"], [" UP BND ", col_name(j), " ", num(ub), "\n"]]

      {lb, :infinity, _type, j} ->
        [" LO BND ", col_name(j), " ", num(lb), "\n"]

      {lb, ub, _type, j} ->
        [
          [" LO BND ", col_name(j), " ", num(lb), "\n"],
          [" UP BND ", col_name(j), " ", num(ub), "\n"]
        ]
    end)
  end

  defp col_name(j), do: ["X", Integer.to_string(j)]

  defp num(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, [:short])
end
