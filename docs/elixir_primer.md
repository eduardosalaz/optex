# An Elixir primer for optimization people

This is Elixir for someone who knows JuMP, gurobipy, Pyomo, or AMPL and
has never touched the BEAM. It covers exactly enough of the language and
runtime to read Optex code, understand why the library is shaped the way
it is (see the [design notes](design_notes.md)), and decide whether the
platform fits your problem. It is not a language tutorial; the official
guides at elixir-lang.org are excellent when you want one.

## The sixty-second mental model

Elixir runs on the BEAM, the Erlang virtual machine that has run telecom
switches and messaging backbones for three decades. Three properties do
most of the work:

- **Everything is immutable.** There is no assignment that changes a
  value in place, only binding names to new values. Data structures are
  persistent; "modifying" a map returns a new map sharing structure with
  the old one.
- **Concurrency is processes and messages.** A BEAM process is a
  featherweight actor (thousands are unremarkable, millions are possible)
  with a private heap and a mailbox. Processes share nothing and
  communicate by sending immutable messages. There are no threads to
  synchronize and no locks in application code.
- **The scheduler protects latency.** The virtual machine preemptively
  schedules processes and isolates long-running native code on separate
  "dirty" scheduler threads, so one heavy computation (say, ten minutes
  of branch-and-bound) cannot freeze everything else.

If you have used Julia, Elixir will feel syntactically familiar
(`do ... end` blocks, modules, macros) but semantically stricter about
mutation. If you come from Python, think "everything is a pure function
over values, and concurrency is actors, not the GIL".

## Reading an Optex model, line by line

```elixir
import Optex.DSL

items = 1..50
value = Map.new(items, fn i -> {i, rem(i * 31, 17) + 3} end)
weight = Map.new(items, fn i -> {i, rem(i * 7, 11) + 1} end)

m =
  model sense: :max do
    variable take[i], i <- items, type: :bin
    constraint sum(weight[i] * take[i], i <- items) <= 40
    objective sum(value[i] * take[i], i <- items)
  end

{:ok, sol} = Optex.optimize(m)
sol.values[{:take, 7}]
```

- `import Optex.DSL` brings the `model`/`variable`/`constraint` words into
  scope. Imports are lexical and explicit; there is no global namespace
  pollution.
- `1..50` is a range. `Map.new(items, fn i -> {i, ...} end)` builds a map
  (hash table) from a function; `fn ... end` is a lambda.
- `%{}` maps and `{a, b}` tuples are the workhorse data structures. Data
  is plain and inspectable: a model, a solution, a progress snapshot are
  all values you can print.
- `variable take[i], i <- items, type: :bin` declares a whole indexed
  family; `i <- items` is a generator, exactly like the comprehension it
  compiles into. Trailing options (`type:`, `lb:`, `name:`) are evaluated
  once per binding, with `i` in scope.
- `:bin`, `:max`, `:optimal` are **atoms**: interned constant names, the
  same idea as Lisp symbols or Julia's `Symbol`. Enumerations, option
  keys, and statuses are atoms by convention.
- `{:ok, sol} = Optex.optimize(m)` is **pattern matching**, the idiom you
  will see everywhere. Functions that can fail return `{:ok, result}` or
  `{:error, reason}`; matching on `{:ok, sol}` asserts success and binds
  `sol` in one step. If the solve failed, this line raises with the
  mismatched value in the error, which is usually exactly what a script
  wants. Code that handles both arms uses `case`.
- `sol.values` is a map keyed by the names you declared: `{:take, 7}` for
  an indexed variable, `:x` for a scalar one.

## Immutability in practice

`Optex.Model` functions never modify a model; they return a new one:

```elixir
m = Optex.Model.new()
{x, m} = Optex.Model.add_variable(m, name: :x, lb: 0.0)
m = Optex.Model.add_constraint(m, [{:x, 1.0}], :le, 3.0)
```

Rebinding `m` shadows the old value; the old model still exists if
something holds a reference to it. Pipelines make the folding read
top-to-bottom, and `Enum.reduce` folds a collection into a model the same
way a loop would elsewhere:

```elixir
m = Enum.reduce(sites, m, fn s, m -> add_site_rows(m, s) end)
```

The payoff for optimization work: models are trivially shareable. Handing
a model to eight concurrent solver processes requires no locks, no copies,
and no discipline, because nothing can mutate it.

## Processes, messages, and why solver callbacks disappear

Any process can send any process a message; receiving is pattern matching
on the mailbox:

```elixir
watcher = self()

Task.async(fn ->
  Optex.optimize(m, progress: watcher, cancel: token)
end)

receive do
  {:optex_progress, %{gap: gap}} when is_float(gap) and gap < 0.02 ->
    Optex.Solver.HiGHS.cancel(token)
end
```

`Task.async` runs the solve in its own process. The `progress:` option is
just a process id; the solver's telemetry arrives as ordinary messages in
the watcher's mailbox. This is why Optex has no callback API: a stopping
rule, a live dashboard, and a log collector are all the same three lines,
and none of your code ever runs on a solver thread.

Long-lived services use `GenServer`, the standard actor-with-state
abstraction, and **supervision trees** restart crashed processes
automatically. The "let it crash" philosophy is not carelessness; it is
the observation that a clean restart from known state beats defensive
programming against unknown corruption. A solver service that dies
mid-solve comes back empty and ready rather than wedged.

## Macros, briefly

`model do ... end` is a macro: a function that receives the syntax tree
of its block at compile time and rewrites it into ordinary function calls
(`add_variable`, `add_constraint`) threaded over an immutable model. This
is the same design space as JuMP's `@variable`/`@constraint`, and unlike
operator overloading it can see structure: Optex reads
`sum(c[i] * x[i], i <- items)` as a symbolic sum, rejects degree-three
products at compile time, and turns a misplaced `max` into a build error
instead of a silently wrong model. You do not need to write macros to use
Elixir any more than you need to write `@generated_function`s to use
Julia.

## Native code without leaving the process

Optex talks to solvers through NIFs (native implemented functions), Rust
libraries loaded into the virtual machine and called like ordinary
functions. There is no subprocess, no file handoff, no serialization tax:
the model's arrays go straight into HiGHS/Gurobi/CPLEX/COPT memory, and
solutions come straight back as Elixir terms.

The runtime cost of that intimacy is discipline (a misbehaving NIF can
take down the whole virtual machine), which is why the bindings follow
strict safety rules and run on dirty schedulers, keeping the rest of the
system responsive during long solves. As a user you notice only the
consequences: solves are function calls, cancellation works mid-solve,
and a web request being served two cores over never notices your MIP.

## Tooling in five lines

- `mix` is the build tool (think cargo): `mix test`, `mix format`,
  `mix docs`.
- Hex is the package registry; dependencies are declared in `mix.exs`.
- `iex` is the REPL; `iex -S mix` starts it with your project loaded.
- Livebook is the notebook environment (think Jupyter with first-class
  concurrency); `Mix.install` at the top of a notebook or script pulls
  dependencies without a project, and Optex's precompiled solver binary
  means that works with no toolchain:

```elixir
Mix.install([{:optex, "~> 0.1.1"}])
```

## Things that surprise newcomers

- **Rebinding is not mutation.** `x = x + 1` binds a new value to the
  name `x`; nothing observed the change. Inside a lambda you cannot
  rebind an outer variable at all.
- **No early return.** Functions are expressions; the last value is the
  result. Control flow is pattern matching (`case`, multi-clause
  functions with guards), not `return` statements.
- **Atoms versus strings.** `:optimal` and `"optimal"` are different
  things; APIs use atoms for closed sets of names.
- **Keyword lists.** Trailing options like `lb: 0.0, ub: 1.0` are
  syntactic sugar for a list of `{atom, value}` tuples, the conventional
  options-passing structure.
- **Indexing is explicit.** There is no operator overloading on user
  types for `[]` outside `Access`; Optex's `x[i]` inside the DSL is
  resolved by the macro, and `sol.values[{:x, i}]` outside it is a plain
  map lookup. Nothing is one-based.
- **Numbers are honest.** Integers are arbitrary precision; floats are
  IEEE doubles; there is no silent NaN propagation through the solver
  boundary (Optex forbids non-finite floats crossing it).

## Where to go next

- `examples/` in the Optex repository: twenty-plus runnable scripts from
  a two-variable LP to cone programming, plus OTP service patterns.
- `examples/standalone/livebook_tour.livemd`: the notebook version, from
  install to a live-updating MIP chart.
- The official Elixir guides (elixir-lang.org) and the free chapters of
  "Elixir in Action" for the language proper.
