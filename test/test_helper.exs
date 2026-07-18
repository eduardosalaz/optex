# Oracle tests need a standalone HiGHS binary; point OPTEX_HIGHS_EXE at one or
# rely on the default local build path. Missing binary -> oracle tests excluded.
highs_exe =
  System.get_env("OPTEX_HIGHS_EXE", "C:/Users/eduardosalaz/HiGHS/build/bin/highs.exe")

Application.put_env(:optex, :highs_exe, highs_exe)

exclude = if File.exists?(highs_exe), do: [], else: [oracle: true]

# Gurobi-backend tests need the compile-gated native crate (GUROBI_HOME set
# at build time) and a valid license.
exclude = if Optex.Solver.Gurobi.available?(), do: exclude, else: [{:gurobi, true} | exclude]

# Same for CPLEX (gated on the versioned CPLEX_STUDIO_DIR* var).
exclude = if Optex.Solver.CPLEX.available?(), do: exclude, else: [{:cplex, true} | exclude]

# Same for COPT (gated on COPT_HOME), plus a license probe: COPT checks its
# license per env creation, so a compiled crate with an expired license
# would turn the whole suite red. Probe with a trivial solve and exclude
# (loudly) when the license is not usable.
copt_ok =
  Optex.Solver.COPT.available?() and
    match?(
      {:ok, _},
      Optex.Solver.COPT.solve(%Optex.SolverInput{
        num_vars: 1,
        num_cons: 0,
        obj: [0.0],
        col_lb: [0.0],
        col_ub: [1.0],
        col_type: [:cont],
        col_start: [0, 0]
      })
    )

if Optex.Solver.COPT.available?() and not copt_ok do
  IO.puts("COPT is installed but its license is not usable; :copt tests excluded")
end

exclude = if copt_ok, do: exclude, else: [{:copt, true} | exclude]

# Cross-backend loops in the tests consult this instead of available?/0,
# which cannot see an expired license.
Application.put_env(:optex, :copt_usable, copt_ok)

# General-constraint solves need at least one capable backend.
exclude =
  if Optex.Solver.Gurobi.available?() or Optex.Solver.CPLEX.available?() or copt_ok,
    do: exclude,
    else: [{:gen_solve, true} | exclude]

ExUnit.start(exclude: exclude)
