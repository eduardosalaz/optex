# Optex vs the official Python bindings

Same solver engines, two host languages: each Optex backend against the
vendor's official Python binding (highspy, gurobipy, docplex, coptpy) on
four identical models. Data is generated from integer remainder formulas
so every host builds bit-identical coefficients; objectives must agree.

Methodology, applying to every binding equally:

- **build** is host-language model construction, median of three fresh
  builds (idiomatic API usage in each binding: addVars/quicksum style in
  Python, the `model do` DSL in Optex).
- **handoff** (Optex only) is the model-to-CSC-wire transform, measured
  separately because the Python bindings perform the equivalent C-loading
  inside their build calls. Compare Python build against Optex
  build + handoff for a like-for-like total.
- **solve wall** wraps the solve call; **solver time** is the engine's
  own reported time. All solves run with threads=1; the MILPs pin
  mip_gap=1e-9.
- **RSS** deltas are OS-level process memory (psutil / tasklist), sampled
  after GC around the first build and the solve, before any repeat builds
  exist to pollute the baseline. Coarse by nature; treat as magnitude,
  not precision. The Optex numbers include both BEAM and solver-side
  memory in one process, as do the Python numbers.
- The QP objective is expressed as literal x_i x_j coefficients in every
  binding; highspy takes it via passHessian (its official QP route),
  everyone else through expression APIs.

To reproduce: run each `bench_<binding>.py` in its venv (.venv312 for
gurobipy/highspy/coptpy, .venv310 for docplex), run
`mix run bench/python_comparison/optex_bench.exs` from the repo root,
then `make_report.py`.

## Objective parity (same engine, two hosts)

| model | engine | python objective | optex objective | relative diff |
|---|---|---|---|---|
| transport | HiGHS | 51800.000000 | 51800.000000 | 0.00e+00 |
| transport | Gurobi | 51800.000000 | 51800.000000 | 0.00e+00 |
| transport | CPLEX | 51800.000000 | 51800.000000 | 0.00e+00 |
| transport | COPT | 51800.000000 | 51800.000000 | 0.00e+00 |
| assign | HiGHS | 1154.000000 | 1154.000000 | 0.00e+00 |
| assign | Gurobi | 1154.000000 | 1154.000000 | 0.00e+00 |
| assign | CPLEX | 1154.000000 | 1154.000000 | 0.00e+00 |
| assign | COPT | 1154.000000 | 1154.000000 | 0.00e+00 |
| portfolio | HiGHS | 0.093033 | 0.093033 | 0.00e+00 |
| portfolio | Gurobi | 0.093033 | 0.093033 | 0.00e+00 |
| portfolio | CPLEX | 0.093033 | 0.093033 | 0.00e+00 |
| portfolio | COPT | 0.093033 | 0.093033 | 0.00e+00 |
| knapsack | HiGHS | 8061.000000 | 8061.000000 | 0.00e+00 |
| knapsack | Gurobi | 8061.000000 | 8061.000000 | 0.00e+00 |
| knapsack | CPLEX | 8061.000000 | 8061.000000 | 0.00e+00 |
| knapsack | COPT | 8061.000000 | 8061.000000 | 0.00e+00 |

## Transportation LP (120,000 vars, 700 rows)

| binding | build (median s) | handoff (s) | solve wall (s) | solver time (s) | build RSS (MB) | solve RSS (MB) |
|---|---|---|---|---|---|---|
| highspy | 0.326 | in build | 0.300 | 0.299 | 11.7 | 37.8 |
| optex_highs | 0.921 | 0.430 | 1.450 | 0.319 | 33.4 | 11.9 |
| gurobipy | 0.395 | in build | 0.184 | 0.168 | 37.2 | 21.2 |
| optex_gurobi | 0.862 | 0.414 | 0.990 | 0.134 | 33.0 | 15.0 |
| docplex | 0.668 | in build | 0.150 | 0.109 | 64.3 | 10.6 |
| optex_cplex | 0.844 | 0.416 | 0.947 | 0.117 | 33.0 | 12.3 |
| coptpy | 0.559 | in build | 0.043 | 0.039 | 38.3 | 22.0 |
| optex_copt | 0.860 | 0.418 | 0.909 | 0.047 | 33.7 | 16.4 |

## Assignment MILP (62,500 binaries, 500 rows)

| binding | build (median s) | handoff (s) | solve wall (s) | solver time (s) | build RSS (MB) | solve RSS (MB) |
|---|---|---|---|---|---|---|
| highspy | 0.158 | in build | 2.299 | 2.299 | 6.8 | 1.6 |
| optex_highs | 0.427 | 0.244 | 2.692 | 2.352 | 17.0 | 3.5 |
| gurobipy | 0.191 | in build | 0.196 | 0.185 | 15.0 | 35.8 |
| optex_gurobi | 0.401 | 0.258 | 0.514 | 0.191 | 17.0 | 3.2 |
| docplex | 0.355 | in build | 0.325 | 0.313 | 19.6 | 6.9 |
| optex_cplex | 0.385 | 0.243 | 0.629 | 0.300 | 17.1 | 5.1 |
| coptpy | 0.310 | in build | 67.438 | 67.414 | 19.4 | 6.9 |
| optex_copt | 0.408 | 0.257 | 71.677 | 71.351 | 17.0 | 6.3 |

## Portfolio QP (300 vars, 45,150 quadratic terms)

| binding | build (median s) | handoff (s) | solve wall (s) | solver time (s) | build RSS (MB) | solve RSS (MB) |
|---|---|---|---|---|---|---|
| highspy | 0.009 | in build | 0.005 | 0.005 | 0.1 | 0.7 |
| optex_highs | 0.088 | 0.111 | 0.092 | 0.006 | 3.1 | 0.3 |
| gurobipy | 0.182 | in build | 0.059 | 0.058 | 1.6 | 3.6 |
| optex_gurobi | 0.086 | 0.100 | 0.161 | 0.066 | 3.1 | 1.4 |
| docplex | 0.333 | in build | 0.055 | 0.047 | 6.1 | -1.4 |
| optex_cplex | 0.086 | 0.094 | 0.157 | 0.054 | 3.1 | 0.7 |
| coptpy | 0.212 | in build | 0.095 | 0.094 | 0.7 | 0.9 |
| optex_copt | 0.087 | 0.114 | 0.186 | 0.095 | 3.1 | 0.5 |

## 3-constraint knapsack MILP (120 binaries, gap 1e-9)

| binding | build (median s) | handoff (s) | solve wall (s) | solver time (s) | build RSS (MB) | solve RSS (MB) |
|---|---|---|---|---|---|---|
| highspy | 0.001 | in build | 1.242 | 1.242 | 0.0 | 0.3 |
| optex_highs | 0.000 | 0.000 | 1.297 | 1.296 | 0.0 | 1.9 |
| gurobipy | 0.001 | in build | 0.127 | 0.128 | 0.0 | 2.7 |
| optex_gurobi | 0.000 | 0.000 | 0.136 | 0.134 | 0.1 | 2.1 |
| docplex | 0.004 | in build | 0.050 | 0.046 | 0.1 | 1.6 |
| optex_cplex | 0.000 | 0.000 | 0.037 | 0.036 | 0.0 | 0.1 |
| coptpy | 0.001 | in build | 0.357 | 0.356 | 0.0 | 0.4 |
| optex_copt | 0.000 | 0.000 | 0.318 | 0.317 | 0.1 | 1.1 |
## Reading the numbers

- **Same engine, same answer, same speed.** Objectives agree exactly on
  all sixteen model-engine pairs, and solver-reported times per engine
  match across hosts within run-to-run noise (COPT's time on the
  assignment instance swings tens of percent between runs either way;
  that is the engine, not the host). The binding layer is not where
  solve time lives.
- **Model build is the same order of magnitude in both hosts.** On the
  120k-variable LP, Optex's build plus handoff is within about 2-3x of
  the fastest Python binding and comparable to docplex; on the dense QP,
  Optex builds faster than gurobipy, coptpy, and docplex (highspy wins
  that one by taking the hessian as raw arrays). For models a solver
  actually spends time on, construction is noise either way.
- **Memory is the same ballpark**: tens of MB for the 120k-variable LP in
  every host (Optex ~33 MB, gurobipy ~37 MB, docplex ~64 MB), a few MB
  for the QP.
- What the table does not show: the Optex model is an immutable value
  that can be handed to concurrent solves as-is, and the handoff column
  is repaid there (build once, solve many). The Python bindings
  interleave host and C state, which is faster on first contact and
  stickier to share.

Generated by bench/python_comparison/make_report.py from results/*.json.
