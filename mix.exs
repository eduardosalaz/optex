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
        "Modeling and solving mixed-integer linear programs, " <>
          "with an in-process HiGHS binding via Rustler",
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
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # the native crate sources ship in the package; consumers build the
      # NIF (and HiGHS) locally at compile time
      files: ~w(
        lib
        native/optex_highs/src
        native/optex_highs/Cargo.toml
        native/optex_highs/Cargo.lock
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
