# Design notes and rationale

Optex is a modeling layer and a set of in-process solver bindings for the
BEAM (the Erlang virtual machine that Elixir runs on). This document
explains why it is shaped the way it is. It is written for people who know
optimization tooling (JuMP, gurobipy, Pyomo, OR-Tools) and want the design
argument, not the tutorial; the companion [Elixir primer](elixir_primer.md)
covers the language itself.

## Goals and non-goals

Optex wants to be the obvious way to embed LP/MILP/QP/QCP/SOCP solves in a
long-running concurrent system: a pricing service, a planning backend, a
LiveView dashboard. It optimizes for predictability, embeddability, and
honest failure over maximal expressiveness.

It deliberately does not try to be: a general nonlinear framework, an
automatic reformulation engine, a research workbench for solver
development, or a DSL that hides which solver features your model uses.

## Three layers, dependencies point downward only

1. **Modeling**: variables, affine/quadratic expressions, constraints,
   native constructs, the `model do ... end` DSL. This layer has no
   knowledge that solvers exist.
2. **Solver abstraction**: a neutral wire format (`Optex.SolverInput`,
   CSC arrays plus explicit construct structs), one model-to-wire
   transform, a `Optex.Solver` behaviour, LP/MPS export, pretty printing.
   This layer knows solvers exist but not which ones.
3. **Bindings**: one Elixir module and one Rust crate per backend (HiGHS,
   Gurobi, CPLEX, COPT). The only solver-aware code in the project.

Two invariants make the layering real rather than aspirational. No solver
constant appears above the binding layer: status integers, parameter ids,
and infinity encodings live only in the crate that owns them. And
`:infinity` stays symbolic in the model and on the wire; each NIF
substitutes its own solver's infinity at the last moment, because 1e20,
1e30, and IEEE infinity are all "infinity" to somebody and conflating them
is a classic source of silent bound bugs.

The single transform function is a deliberate chokepoint: there is exactly
one place where a model becomes solver input, so cross-backend agreement
tests exercise the same code path every backend consumes.

## The capability model: strict, never reformulate

Backends export `capabilities/0`. If an input needs something the chosen
backend lacks, the solve fails before any native code runs, with a value
that names the construct and the backend:

    {:error, {:unsupported, :indicator, Optex.Solver.HiGHS}}

|                       | HiGHS | Gurobi | CPLEX | COPT |
|-----------------------|-------|--------|-------|------|
| indicator             | no    | yes    | yes   | yes  |
| abs                   | no    | yes    | yes   | no   |
| piecewise-linear      | no    | yes    | yes   | no   |
| min/max               | no    | yes    | no    | no   |
| SOS1/SOS2             | no    | yes    | yes   | yes  |
| second-order cone     | no    | yes    | yes   | yes  |
| quadratic objective   | convex, continuous | full | convex incl. MIQP | convex incl. MIQP |
| quadratic constraint  | no    | full   | convex, no equality | convex, no equality |

This is the most opinionated choice in the project, and it runs against
the grain of much modern tooling. JuMP's bridge system will rewrite an
indicator into a big-M when the solver lacks native support; several
modeling layers linearize abs and min/max behind your back. We refuse,
for three reasons.

First, reformulations have costs the modeling layer cannot honestly price.
A big-M indicator needs bounds you may not have stated, changes the
relaxation, and can wreck solve times; a silent rewrite means the user
discovers this in production, as a performance mystery rather than a type
error. Second, refusal keeps semantics pinned: a native `abs` on Gurobi
and a native `abs` on CPLEX provably agree in our cross-solver tests
precisely because neither is a homemade linearization. Third, the manual
reformulation is not lost knowledge: the examples show big-M and epigraph
versions side by side with the native constructs, so the user chooses,
with both costs visible.

The same strictness applies at finer grain: HiGHS rejects quadratic
objectives with integer variables, CPLEX rejects quadratic equality
constraints, and asking for QCP duals anywhere but Gurobi is an error
rather than a nil that might mean anything.

## The DSL: macros, families, and refusing degree three

Elixir macros receive the abstract syntax tree of their arguments at
compile time. The DSL uses that to read expressions like

    constraint sum(w1[i] * take[i], i <- items) <= cap1

structurally, the way JuMP's `@constraint` does in Julia, rather than by
operator overloading on runtime objects, the way gurobipy does. The
practical differences:

- **Families are comprehensions.** Trailing generator clauses declare one
  row per binding, and every trailing option is evaluated per binding with
  the generators in scope, so names, bounds, and types can depend on the
  index (`variable x[{r, c, d}], ..., ub: if(given[{r, c}] in [0, d], ...)`).
- **Nonlinearity fails at the boundary it occurs.** Products are expanded
  symbolically; a product of degree three raises `Optex.NonlinearError`
  at model build, not at solve, and degree-two terms are first-class
  (objectives and plain constraints), never an encoding trick.
- **Dangerous lookalikes are compile errors.** `Kernel.max/2` applied to
  two expression structs would happily compare them structurally and
  build a silently wrong model. So `max`, `min`, `abs`, and `pwl` deep
  inside expressions raise at build time with a pointer to the defined
  variable forms (`variable t = max(x, y - 1, 3.5)`), which introduce
  named auxiliary variables and rows that show up transparently in
  solution values.

The DSL is sugar, not the substrate. Everything it produces is available
programmatically (`Optex.Model.add_variable/2`, `add_constraint/5` with
`{name, coefficient}` terms lists, and so on), the model is an ordinary
immutable value, and the programmatic API is what non-Elixir BEAM
languages (Erlang, Gleam) call directly.

## Immutability as a modeling feature

An Optex model is an immutable value. Building is folding functions over
it; there is no model object to mutate, no solver environment to guard, no
implicit global state. This buys three things that mutable model objects
cannot offer cheaply:

- **Scenario work is data work.** Build one model per scenario and solve
  them all concurrently with `Task.async_stream`; no locks, pools, or
  copies of solver state, because there is no shared mutable anything.
- **A model cannot be half-edited.** Every intermediate state is a
  complete, valid model; the failure mode "constraint added to the wrong
  copy of the model" does not exist.
- **APIs never mutate as a side effect.** `add_cone` raises if a cone
  head lacks a nonnegative lower bound rather than "helpfully" tightening
  the bound, because that silent mutation is load-bearing for the SOC
  encodings and the user deserves to know.

## Callbacks the BEAM way

Every mainstream solver exposes progress and control through C callbacks:
user code running on solver threads, with per-vendor reentrancy rules and
crash consequences. Optex refuses to run user code on solver threads,
full stop. Instead, solves expose three composable primitives:

- `progress:` streams throttled solver snapshots to any process as
  ordinary `{:optex_progress, map}` messages (best objective, bound, gap,
  nodes, time, with honest nils where a backend lacks a field).
- `incumbents:` streams every improving solution with name-keyed values.
- `cancel:` takes a token that any process can fire at any time;
  the solver stops cooperatively and returns the best incumbent with
  status `:interrupted`.

A user-defined stopping rule is therefore a receive loop in the user's own
process: watch the stream, decide, cancel. It is identical code on all
four backends, it cannot crash the solver, and it composes with everything
else in the runtime (a supervision tree, a LiveView, a test). Inside the
bindings, the same discipline holds: solver callbacks only push into a
channel drained by a dedicated thread that is joined before the NIF
returns, because a panic on a scheduler thread is not survivable.

Control callbacks (lazy constraints, user cuts, heuristic injection) are
deliberately absent until they can meet the same bar.

## The FFI discipline

Each binding is hand-verified against the installed vendor header, and
every version-sensitive constant (status integers, parameter ids, C
signatures) is recorded with its provenance in `DECISIONS.md`. The crates
follow four non-negotiable rules, each backed by tests:

1. A length firewall validates every array before any unsafe pointer use.
2. The solver instance and environment are freed on every exit path.
3. Output buffers are preallocated to exact (or exact-upper-bound) size.
4. Input vectors and callback contexts stay owned by locals for the whole
   call.

Two boundary rules were learned the hard way: non-finite floats never
cross the NIF boundary (Erlang floats cannot represent them; options are
used on the Rust side), and nothing that can panic runs on a scheduler
thread. Solves run on dirty schedulers, so a long branch-and-bound never
stalls the virtual machine's latency guarantees.

The HiGHS crate ships precompiled for the common platforms via checksummed
downloads, which is what makes `Mix.install` and Livebook onboarding work
with no toolchain. The commercial crates compile only when their SDK is
detected, and gracefully stub themselves out otherwise, so open-source CI
proves the gating without any licenses present.

## Numeric conventions worth pinning

- The neutral wire format carries literal coefficients. The 1/2 x'Qx
  convention some solvers expect (diagonal doubling) is applied inside the
  bindings that need it, for objectives only, never for constraints.
- Piecewise-linear functions extend their end segments and express jump
  discontinuities as one repeated x breakpoint (either y is feasible at
  the jump). These semantics are pinned by cross-backend tests, because
  vendors disagree by default.
- Solutions are rekeyed by user-facing names: values, duals, reduced
  costs, and quadratic-constraint duals all come back keyed by the names
  you gave things, not by internal indices.

## Testing philosophy

Analytic optima are hand-computed before asserts are written. Cross-solver
agreement (same objectives, same duals, across all installed backends) is
the oracle for constructs. An MPS emitter exists solely so the NIF can be
compared against the standalone HiGHS binary on identical input. Every
example in `examples/` is executed by the test suite. Performance is
guarded by scaling ratios between problem sizes rather than absolute
times, so CI variance does not produce flaky failures.

## Roadmap posture

The largest known gap is persistent solver handles and warm starts for
re-solve loops. It is not built yet on purpose: a good re-solve API should
be designed against a real workload's mutation patterns, not speculated.
If you have one, that conversation is the most useful contribution you
can make. Also parked, in rough order: basis information, control
callbacks, exponential cones and general nonlinearity, multi-objective.
