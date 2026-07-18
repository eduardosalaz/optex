# Changelog

## v0.1.0 (unreleased)

First public release.

### Modeling

- Declarative `model do ... end` DSL: scalar and indexed variable families
  (tuple keys for multiple indices), constraint families via trailing
  generators, `sum/2+`, per-binding `name:` options, and a programmatic
  terms-list API on `Optex.Model` for pipeline-style building.
- LP, MILP, QP (quadratic objectives with literal coefficients), QCP
  (quadratic constraints in their own id space), and SOCP (quad and
  rotated second-order cones).
- Native constructs, never reformulated: indicator constraints
  (`if:`/`if: {b, 0}`), `variable t = abs(e)`, `variable y = pwl(x,
  points)` with end-segment extension and interior jump discontinuities,
  `variable m = max/min(...)`, `constraint norm(exprs...) <= bound`, and
  `sos1`/`sos2` sets.

### Solving

- Four backends behind one `Optex.Solver` behaviour: HiGHS 1.15 (bundled,
  precompiled binaries on common platforms), Gurobi 13, CPLEX 22.1.1, and
  COPT 8 (each compile-gated on its installed SDK), with a strict
  capability model: unsupported inputs fail fast with
  `{:error, {:unsupported, construct, backend}}`.
- Solutions rekeyed by user-facing names: values, duals, reduced costs,
  opt-in quadratic constraint duals (`qcp_duals: true`, Gurobi), solve
  stats.
- Options: `time_limit`, `mip_gap`, `threads`, `log` (console or message
  stream), cooperative cancellation tokens, and MIP progress/incumbent
  streaming (`progress:`, `progress_every:`, `incumbents:`) on every
  backend.
- `Optex.explain_infeasibility/2`: named IIS over the linear relaxation
  everywhere, and full-model construct-aware IIS on Gurobi.
- Model inspection: pretty printer (`Optex.Format`), LP-format export
  (`Optex.LP`), MPS emitter used as a test oracle.

### Engineering

- Hand-verified FFI against each installed solver header; every
  version-sensitive constant recorded in `DECISIONS.md`.
- Length-firewalled NIFs, exact-size buffers, leak-free error paths;
  cross-solver agreement tests pin objectives and duals across all
  available backends; ~250 tests.
