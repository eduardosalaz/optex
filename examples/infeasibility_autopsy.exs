# Explaining infeasibility: the IIS as a debugging tool.
#
# A staffing plan that cannot work: 30 hours of coverage demanded from two
# workers capped at 12 hours each. Instead of a bare :infeasible,
# explain_infeasibility/2 computes an irreducible infeasible subsystem: a
# MINIMAL set of constraints and variable bounds that clash, by name, with
# innocent rows left out. The IIS examines the model's linear relaxation;
# constructs outside its scope (here an indicator) are stripped first and
# reported under not_examined, since the real conflict may live there.
#
# Run with: mix run examples/infeasibility_autopsy.exs

import Optex.DSL

broken =
  model do
    variable hours[w], w <- [:ana, :bo], lb: 0.0, ub: 12.0
    variable overtime, type: :bin

    constraint(hours[:ana] + hours[:bo] >= 30, name: :coverage)
    # an innocent row: not part of any minimal conflict
    constraint(hours[:ana] <= 40, name: :weekly_cap)
    # an indicator, to show what the IIS scope excludes
    constraint(hours[:bo] <= 8, if: {overtime, 0}, name: :no_overtime)

    objective hours[:ana] + hours[:bo]
  end

# HiGHS cannot SOLVE this model (the indicator is beyond its capabilities,
# and the rejection is strict), yet it can still run the autopsy below:
# the IIS examines the linear relaxation, constructs stripped
{:error, reason} = Optex.optimize(broken)
IO.puts("solving on HiGHS:  #{inspect(reason)}")

{:ok, %{constraints: cons, variables: vars, not_examined: skipped}} =
  Optex.explain_infeasibility(broken)

IO.puts("conflicting constraints: #{inspect(cons)}")
IO.puts("conflicting bounds:      #{inspect(vars)}")
IO.puts("outside IIS scope:       #{inspect(skipped)}\n")

# On Gurobi the IIS is construct-aware: the full model is examined
# (not_examined comes back empty) and a construct that IS part of the
# conflict gets named under constructs. Here the culprit is the gate
# indicator: the build flag is forced on, the gate then caps x at 1, and
# the demand row needs 3.
if Optex.Solver.Gurobi.available?() do
  guilty =
    model do
      variable build, type: :bin
      variable x, lb: 0.0
      constraint(build >= 1, name: :committed)
      constraint(x <= 1, if: build, name: :gate)
      constraint(x >= 3, name: :demand)
      objective x
    end

  {:ok, %{constraints: cons, constructs: constructs, not_examined: skipped}} =
    Optex.explain_infeasibility(guilty, solver: Optex.Solver.Gurobi)

  IO.puts("construct-aware autopsy (Gurobi):")
  IO.puts("  conflicting constraints: #{inspect(cons)}")
  IO.puts("  conflicting constructs:  #{inspect(constructs)}")
  IO.puts("  outside IIS scope:       #{inspect(skipped)}\n")
end

# the autopsy says the 12-hour caps and the coverage row cannot coexist;
# hire a third worker and the same plan solves
fixed =
  model do
    variable hours[w], w <- [:ana, :bo, :cy], lb: 0.0, ub: 12.0

    constraint(sum(hours[w], w <- [:ana, :bo, :cy]) >= 30, name: :coverage)
    objective sum(hours[w], w <- [:ana, :bo, :cy])
  end

{:ok, sol} = Optex.optimize(fixed)
IO.puts("with a third worker: #{sol.status}, total hours #{sol.objective}")

# Expected: the IIS names :coverage plus the upper bounds of both hours
# variables (:weekly_cap stays out; the indicator appears only under
# not_examined), and the fixed model solves to 30.0 total hours.
