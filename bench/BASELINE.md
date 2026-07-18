# Benchmark baseline

## 2026-07-17 cross-backend sweep (COPT added; every capable backend timed)

`bench/scale.exs` now times the solve on EVERY capable available backend
per case (previously only the first capable one), so the sweep doubles as
a four-way comparison: HiGHS, Gurobi, CPLEX, COPT. A minmax family was
added alongside abs/pwl (Gurobi-only, per the capability matrix, which the
output makes visible: abs/pwl rows show two backends, minmax one).

Default sweep (small + medium sizes), wall times, all statuses optimal
unless noted:

| case          | HiGHS      | Gurobi | CPLEX  | COPT    |
|---------------|------------|--------|--------|---------|
| lp 100x100    | 22 ms      | 18 ms  | 15 ms  | 10 ms   |
| milp 25x400   | 1487 ms    | 21 ms  | 33 ms  | 60 ms   |
| qp 10k        | time limit | 130 ms | 57 ms  | 98 ms   |
| miqp 5k       | -          | 9 ms   | 27 ms  | 377 ms  |
| qcp 10k       | -          | 48 ms  | 56 ms  | 62 ms   |
| indicator 5k  | -          | 150 ms | 99 ms  | 1233 ms |
| abs 5k        | -          | 21 ms  | 38 ms  | -       |
| pwl 5k        | -          | 14 ms  | 34 ms  | -       |
| minmax 5k     | -          | 13 ms  | -      | -       |

Solver-side findings for routing (not our code):

- **COPT is competitive-to-fastest on LP** (fastest of the four at 10k
  vars) and holds its own on MILP and QCP.
- **COPT lags on MIQP (~40x Gurobi at 5k) and indicators (~8-12x the
  others at 5k)**; prefer Gurobi/CPLEX for indicator-heavy or MIQP models
  when available.
- Marshalling overhead is in the same 0.7-2 us/var band on all four
  backends; the NIF boundary is not a differentiator.

Build/transform numbers and the large-size (BENCH_LARGE=1) linearity
findings below are unchanged by this pass; only the solve column layout
changed.

## 2026-07-17 scale sweep across all problem types

`mix run bench/scale.exs` (BENCH_LARGE=1) covers LP, MILP, QP, MIQP, QCP,
indicator, abs, and pwl at up to ~100k variables, with capable-backend
routing per type. Headline: **every phase we own is linear at 100k
variables across every problem type.** At the large sizes:

| case            | vars    | build   | transform | marshal ovh |
|-----------------|---------|---------|-----------|-------------|
| lp 316x316      | 99,856  | 525 ms  | 263 ms    | 65 ms       |
| milp 80x1250    | 100,080 | 401 ms  | 330 ms    | 46 ms       |
| qp 100k         | 100,000 | 595 ms  | 665 ms    | 58 ms       |
| indicator 50k   | 100,000 | 377 ms  | 128 ms    | 136 ms      |

Rates hold at roughly 4-6 us/var build, 1-7 us/var transform, and
0.6-1.4 us/var marshalling (constructs cost more per unit because each
indicator/abs/pwl is its own FFI call). Model-to-solver latency at 100k
variables is about one second plus solver time.

Emitters at ~200k nnz: MPS 281 ms (the linear rewrite verified at scale;
the pre-fix quadratic version would have taken minutes), LP 1.49 s,
pretty 1.57 s - linear, string-formatting heavy as known.

Solver-side findings (not our code, worth knowing for routing):

- **HiGHS's QP solver cliffs**: a simple tridiagonal QP solves in 2.1 s at
  1k variables and hits the time limit at 10k, while Gurobi dispatches
  comparable MIQPs in milliseconds. Route serious QPs to a commercial
  backend; HiGHS QP is for small problems.
- HiGHS overshoots time_limit on QP (79 s wall against a 60 s limit);
  limit checks are coarse inside its QP solver. Status still decodes as
  :time_limit correctly.
- The abs generator's variable counts (1462 for n = 500) show the
  bare-variable optimization working: targets of 0 skip the aux variable.

Machine: Windows 10, 16 hardware threads, Elixir 1.20.2/OTP 29, HiGHS 1.15.0
via NIF. Run `mix run bench/benchmarks.exs` (BENCH_TIME=2 unless noted).
Workload: transportation LP, p x mk grid (p*mk vars, p+mk rows, 2*p*mk nnz).

Update this file when numbers change materially, with the commit that did
it. The scaling properties recorded here are guarded continuously by
`test/optex/perf_regression_test.exs` (ratio-between-sizes assertions, so
they hold on any machine); this file carries the absolute numbers.

## 2026-07-17 initial baseline and first optimization pass

Median times at the 100x100 size (10,000 vars, 20,000 nnz):

| phase                | baseline  | after pass 1 | change        |
|----------------------|-----------|--------------|---------------|
| transform            | 25.6 ms   | 26.6 ms      | unchanged     |
| build (programmatic) | 31.3 ms   | 32.3 ms      | unchanged     |
| build (DSL)          | 36.9 ms   | 38.2 ms      | unchanged     |
| emit LP              | 165.2 ms  | 166.8 ms     | unchanged     |
| pretty print         | 348.3 ms  | 139.3 ms     | 2.5x faster   |
| emit MPS             | 1831.2 ms | 25.3 ms      | 72x faster    |

What the baseline scaling revealed, and what was done:

- **emit MPS was quadratic in nnz** (219 us -> 26 ms -> 1.83 s for
  200 -> 3.2k -> 20k nnz): `Enum.at` on plain lists inside the per-column
  and per-nonzero loops. Fixed by carving the column slices out of
  row_index/values in one linear pass; now 185 us -> 3.5 ms -> 25 ms,
  tracking nnz linearly. Correctness held by the oracle tests (the emitted
  file still solves to the same objectives in the standalone binary).
- **pretty print recomputed each variable's display string per term
  occurrence** (about 30k string builds with `inspect` at 10k vars, 90 MB
  allocated). Fixed by precomputing an id -> display-name map once:
  348 -> 139 ms, 90 -> 54 MB. The remaining cost is inherent string
  formatting.
- Everything else scales roughly linearly with sane constants: build and
  transform are ~3-4 us per variable with ~2-4 KB/var allocated; LP emit is
  linear but string-formatting heavy (167 ms / 87 MB at 10k vars) and is
  the next candidate if debug-path speed ever matters.
- **NIF marshalling overhead** (prepare + list-to-Vec encode/decode,
  measured as solve wall minus solver-reported time on a pre-transformed
  input): 0.1 ms at 100 vars, 1.2 ms at 1.6k, 7.3 ms at 10k. Roughly
  0.7 us/var, small relative to any nontrivial solve. The initial harness
  mistakenly included the transform in this number (42.9 ms); fixed in the
  same pass.

Headline at 10k vars after pass 1: build 32-38 ms, transform 27 ms,
marshalling 7 ms; end-to-end model-to-solver latency is ~70 ms plus solver
time, and no phase is superlinear.
