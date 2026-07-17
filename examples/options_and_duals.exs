# Solver options and dual information.
#
# Options go straight through Optex.optimize/2 (anything except :solver is
# forwarded to the backend). For LPs the solution carries dual information:
#
#   sol.duals          - one shadow price per constraint, keyed by constraint
#                        id in declaration order: the objective improvement
#                        per unit of extra right-hand side
#   sol.reduced_costs  - keyed like sol.values: how much a variable's
#                        objective coefficient falls short of what it would
#                        need to enter the optimal plan
#
# Both are nil for models with integer variables (MIPs have no duals).
#
# Run with: mix run examples/options_and_duals.exs

import Optex.DSL

# A workshop makes tables (profit 30), chairs (18), and stools (12) from
# 40 carpentry hours and 50 finishing hours.
lp =
  model sense: :max do
    variable tables, lb: 0.0
    variable chairs, lb: 0.0
    variable stools, lb: 0.0

    # constraint id 0: carpentry, id 1: finishing
    constraint 2 * tables + chairs + stools <= 40
    constraint tables + 2 * chairs + stools <= 50

    objective 30 * tables + 18 * chairs + 12 * stools
  end

# Solver options ride along with optimize/2. log: true would stream the HiGHS
# log to stdout; unknown keys come back as {:error, {:unknown_option, key}}.
{:ok, sol} = Optex.optimize(lp, time_limit: 10.0, threads: 1, log: false)

IO.puts("== LP ==")
IO.puts("status:  #{sol.status}")
IO.puts("profit:  #{sol.objective}")

IO.puts(
  "plan:    #{Float.round(sol.values[:tables], 4)} tables, " <>
    "#{Float.round(sol.values[:chairs], 4)} chairs, " <>
    "#{Float.round(sol.values[:stools], 4)} stools"
)

IO.puts("")
IO.puts("shadow prices (duals):")
IO.puts("  carpentry hour: #{Float.round(sol.duals[0], 4)}")
IO.puts("  finishing hour: #{Float.round(sol.duals[1], 4)}")

IO.puts("")
IO.puts("reduced costs:")

for p <- [:tables, :chairs, :stools] do
  IO.puts("  #{p}: #{Float.round(sol.reduced_costs[p], 4)}")
end

IO.puts("""

Reading: one extra carpentry hour is worth #{Float.round(sol.duals[0], 2)} in
profit, one extra finishing hour #{Float.round(sol.duals[1], 2)}. Stools are
not produced; their reduced cost says their profit would have to rise by
#{Float.round(-sol.reduced_costs[:stools], 2)} before making one pays off.
""")

# The same shop with whole-unit production: now it is a MIP, mip_gap applies,
# and there is no dual information at all.
mip =
  model sense: :max do
    variable tables, type: :int, lb: 0.0
    variable chairs, type: :int, lb: 0.0

    constraint 2 * tables + chairs <= 41
    constraint tables + 2 * chairs <= 50

    objective 30 * tables + 18 * chairs
  end

{:ok, mip_sol} = Optex.optimize(mip, mip_gap: 1.0e-6, threads: 1)

IO.puts("== MIP ==")
IO.puts("status:  #{mip_sol.status}")
IO.puts("profit:  #{mip_sol.objective}")

IO.puts(
  "plan:    #{round(mip_sol.values[:tables])} tables, " <>
    "#{round(mip_sol.values[:chairs])} chairs"
)

IO.puts("duals:   #{inspect(mip_sol.duals)} (MIPs have none)")

# A typo in an option name fails fast, before the solver runs.
{:error, reason} = Optex.optimize(lp, tim_limit: 10.0)
IO.puts("\nbad option: #{inspect(reason)}")

# Expected: LP profit 660.0 at 10 tables, 20 chairs, 0 stools; shadow prices
# 14.0 (carpentry) and 2.0 (finishing); stools reduced cost -4.0. MIP profit
# 672.0 at 11 tables, 19 chairs with nil duals.
