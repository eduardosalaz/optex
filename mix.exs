defmodule Optex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/eduardosalaz/optex"

  def project do
    [
      app: :optex,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Modeling and solving linear, mixed-integer, and quadratic programs " <>
          "with in-process solver bindings via Rustler: HiGHS built in, " <>
          "Gurobi and CPLEX optional",
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
      {:rustler, "~> 0.38.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:benchee, "~> 1.5", only: :dev}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # all three native crate sources ship in the one package: consumers
      # build the HiGHS NIF locally at compile time, and the Gurobi/CPLEX
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
        .formatter.exs
        mix.exs
        README.md
        LICENSE
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "main",
      groups_for_modules: [
        Modeling: [Optex.DSL, Optex.Model, Optex.Var, Optex.Aff, Optex.Constraint, Optex.Expr],
        "Solver abstraction": [
          Optex.Solver,
          Optex.SolverInput,
          Optex.Transform,
          Optex.Solution,
          Optex.MPS
        ],
        Binding: [Optex.Solver.HiGHS]
      ]
    ]
  end
end
