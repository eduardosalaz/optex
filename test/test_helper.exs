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

# General-constraint solves need at least one capable backend.
exclude =
  if Optex.Solver.Gurobi.available?() or Optex.Solver.CPLEX.available?(),
    do: exclude,
    else: [{:gen_solve, true} | exclude]

ExUnit.start(exclude: exclude)
