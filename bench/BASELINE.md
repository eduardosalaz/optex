# Benchmark baseline

Machine: Windows 10, 16 hardware threads, Elixir 1.20.2/OTP 29, HiGHS 1.15.0
via NIF. Run `mix run bench/benchmarks.exs` (BENCH_TIME=2 unless noted).
Workload: transportation LP, p x mk grid (p*mk vars, p+mk rows, 2*p*mk nnz).

Update this file when numbers change materially, with the commit that did it.

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
