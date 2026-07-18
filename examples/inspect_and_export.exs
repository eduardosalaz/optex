# Reading a model back: the pretty printer and the LP exporter.
#
# Optex.Format.pretty/1 renders any model as readable text with the names
# as written, including native constructs (indicators, abs/pwl/min-max
# definitions) and quadratic terms. Optex.LP.emit/1 writes an LP-format
# document with sanitized names for hand inspection or feeding another
# solver, and it REFUSES models it cannot represent faithfully (native
# constructs have no plain-LP encoding) instead of silently dropping rows.
#
# Run with: mix run examples/inspect_and_export.exs

import Optex.DSL

# a model touching most of the surface: binary, indicator, abs, max,
# a quadratic constraint, named rows
rich =
  model sense: :max do
    variable build, type: :bin
    variable x, lb: 0.0
    variable y, lb: 0.0

    variable spread = abs(x - y)
    variable best = max(x, y, 1.5)

    constraint(x + y <= 8, name: :budget)
    constraint(x <= 2, if: {build, 0}, name: :gated)
    constraint(x * x + y * y <= 25, name: :envelope)

    objective x + y + best - spread - 3 * build
  end

IO.puts("---- Optex.Format.pretty/1 ----")
IO.puts(Optex.Format.pretty(rich))

# LP export refuses constructs rather than lying about them
try do
  Optex.LP.emit(rich)
rescue
  e in ArgumentError -> IO.puts("LP.emit on the rich model: #{Exception.message(e)}\n")
end

# a plain MILP exports fine; names are sanitized to the LP character set
plain =
  model sense: :max do
    variable tables, type: :int, lb: 0.0
    variable chairs, type: :int, lb: 0.0

    constraint(2 * tables + chairs <= 40, name: :carpentry)
    constraint(tables + 3 * chairs <= 45, name: {:finishing, :shop_a})

    objective 30 * tables + 10 * chairs
  end

IO.puts("---- Optex.LP.emit/1 ----")
IO.puts(IO.iodata_to_binary(Optex.LP.emit(plain)))

{:ok, sol} = Optex.optimize(plain)

IO.puts(
  "solved: #{sol.status}, profit #{sol.objective} " <>
    "(#{sol.values[:tables]} tables, #{sol.values[:chairs]} chairs)"
)

# Expected: the pretty print shows the named rows, the indicator arrow, the
# definitions section (spread = |...|, best = max(...)), and the quadratic
# envelope; LP.emit raises on it, then exports the plain MILP with
# sanitized names, and the MILP solves to profit 600.0 at 20 tables and 0
# chairs (the corner t = 15, c = 10 only reaches 550).
