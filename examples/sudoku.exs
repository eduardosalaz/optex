# Sudoku as a pure feasibility MILP: 729 binaries, 324 equality rows.
#
# x[{r, c, d}] = 1 when cell (r, c) holds digit d. Givens are fixed through
# variable bounds (lb = ub = 1 for the given digit, ub = 0 for the rest of
# that cell), every cell/row/column/box gets a sum-to-one row, and there is
# no objective at all: an unset objective is all zeros, which makes this a
# pure feasibility problem. Also a small stress test of the CSC transform
# and the NIF on a few thousand nonzeros.
#
# Run with: mix run examples/sudoku.exs

alias Optex.Model

puzzle = """
530070000
600195000
098000060
800060003
400803001
700020006
060000280
000419005
000080079
"""

given =
  for {line, r} <- Enum.with_index(String.split(puzzle, "\n", trim: true), 1),
      {ch, c} <- Enum.with_index(String.graphemes(line), 1),
      into: %{} do
    {{r, c}, String.to_integer(ch)}
  end

range = 1..9

m =
  Enum.reduce(
    for(r <- range, c <- range, d <- range, do: {r, c, d}),
    Model.new(),
    fn {r, c, d}, m ->
      {lb, ub} =
        cond do
          given[{r, c}] == d -> {1.0, 1.0}
          given[{r, c}] != 0 -> {0.0, 0.0}
          true -> {0.0, 1.0}
        end

      {_v, m} = Model.add_variable(m, name: {:x, {r, c, d}}, type: :int, lb: lb, ub: ub)
      m
    end
  )

one = fn m, terms -> Model.add_constraint(m, terms, :eq, 1.0) end

# each cell holds exactly one digit
m =
  Enum.reduce(for(r <- range, c <- range, do: {r, c}), m, fn {r, c}, m ->
    one.(m, for(d <- range, do: {{:x, {r, c, d}}, 1.0}))
  end)

# each digit appears once per row and once per column
m =
  Enum.reduce(for(r <- range, d <- range, do: {r, d}), m, fn {r, d}, m ->
    one.(m, for(c <- range, do: {{:x, {r, c, d}}, 1.0}))
  end)

m =
  Enum.reduce(for(c <- range, d <- range, do: {c, d}), m, fn {c, d}, m ->
    one.(m, for(r <- range, do: {{:x, {r, c, d}}, 1.0}))
  end)

# each digit appears once per 3x3 box
m =
  Enum.reduce(for(br <- 0..2, bc <- 0..2, d <- range, do: {br, bc, d}), m, fn {br, bc, d}, m ->
    terms =
      for r <- (br * 3 + 1)..(br * 3 + 3),
          c <- (bc * 3 + 1)..(bc * 3 + 3),
          do: {{:x, {r, c, d}}, 1.0}

    one.(m, terms)
  end)

{:ok, sol} = Optex.optimize(m)

IO.puts("status: #{sol.status}\n")

for r <- range do
  row =
    Enum.map_join(range, "", fn c ->
      d = Enum.find(range, fn d -> sol.values[{:x, {r, c, d}}] > 0.5 end)
      sep = if c in [3, 6], do: " ", else: ""
      "#{d}#{sep}"
    end)

  IO.puts(row)
  if r in [3, 6], do: IO.puts("")
end

# Expected first row: 534 678 912 (the classic puzzle's unique solution).
