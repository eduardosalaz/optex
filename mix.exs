defmodule Optex.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/eduardosalaz/optex"

  def project do
    [
      app: :optex,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Model and solve LP/MILP/QP/QCP/SOCP with in-process solver " <>
          "bindings: HiGHS built in (precompiled), Gurobi, CPLEX, and COPT " <>
          "optional. Native indicators, abs, piecewise-linear, min/max, " <>
          "SOS, duals, IIS, and live solve streaming.",
      package: package(),
      name: "Optex",
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # rustler stays a hard dependency (not optional): the HiGHS crate
      # falls back to a source build under FORCE_OPTEX_BUILD, and the
      # commercial crates ALWAYS source-build when their env vars are set,
      # so `use Rustler` must be resolvable in every consumer project
      {:rustler, "~> 0.38.0"},
      {:rustler_precompiled, "~> 0.8"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:benchee, "~> 1.5", only: :dev}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # all native crate sources ship in the one package: consumers build
      # the HiGHS NIF locally at compile time, and the Gurobi/CPLEX/COPT
      # crates are compile-gated on their installations (stub modules
      # otherwise), so the package builds cleanly everywhere
      files: ~w(
        lib
        native/optex_highs/src
        native/optex_highs/Cargo.toml
        native/optex_highs/Cargo.lock
        native/optex_gurobi/src
        native/optex_gurobi/build.rs
        native/optex_gurobi/Cargo.toml
        native/optex_gurobi/Cargo.lock
        native/optex_cplex/src
        native/optex_cplex/build.rs
        native/optex_cplex/Cargo.toml
        native/optex_cplex/Cargo.lock
        native/optex_copt/src
        native/optex_copt/build.rs
        native/optex_copt/Cargo.toml
        native/optex_copt/Cargo.lock
        checksum-*.exs
        .formatter.exs
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "optex-logo.svg",
      extras: [
        "README.md",
        "docs/design_notes.md",
        "docs/elixir_primer.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Modeling: [
          Optex.DSL,
          Optex.Model,
          Optex.Var,
          Optex.Aff,
          Optex.Constraint,
          Optex.QConstraint,
          Optex.Indicator,
          Optex.Cone,
          Optex.Sos,
          Optex.Expr,
          Optex.NonlinearError
        ],
        "Solver abstraction": [
          Optex.Solver,
          Optex.SolverInput,
          Optex.Transform,
          Optex.Solution,
          Optex.Format,
          Optex.LP,
          Optex.MPS
        ],
        Backends: [
          Optex.Solver.HiGHS,
          Optex.Solver.Gurobi,
          Optex.Solver.CPLEX,
          Optex.Solver.COPT
        ]
      ]
    ]
  end
end
