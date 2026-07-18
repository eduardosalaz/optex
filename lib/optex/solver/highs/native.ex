defmodule Optex.Solver.HiGHS.Native do
  @moduledoc false
  # The default backend ships PRECOMPILED: consumers download a
  # checksummed binary for their platform from the GitHub release instead
  # of building Rust + HiGHS (CMake, minutes) locally. FORCE_OPTEX_BUILD=1
  # compiles from source exactly like plain Rustler (development, CI, and
  # platforms outside the release matrix); the commercial crates are
  # always source-built since they link the user's installed SDKs.

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :optex,
    crate: "optex_highs",
    base_url: "https://github.com/eduardosalaz/optex/releases/download/v#{version}",
    force_build: System.get_env("FORCE_OPTEX_BUILD") in ["1", "true"],
    version: version,
    targets: ~w(
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
      x86_64-apple-darwin
      aarch64-apple-darwin
      x86_64-pc-windows-msvc
    )

  # Dirty-CPU NIFs and cancellation helpers; all replaced at load time.
  # solve/2 takes a prepared %Optex.SolverInput{} and a
  # %Optex.Solver.HiGHS.Options{}; returns
  # {:ok, %Optex.SolveResult{}} | {:error, reason}.
  def solve(_input, _options), do: :erlang.nif_error(:nif_not_loaded)

  # iis/1 computes an irreducible infeasible subsystem for the (relaxed)
  # model; returns {:ok, %Optex.IisResult{}} | {:error, reason}.
  def iis(_input), do: :erlang.nif_error(:nif_not_loaded)

  def cancel_token, do: :erlang.nif_error(:nif_not_loaded)

  def cancel(_token), do: :erlang.nif_error(:nif_not_loaded)
end
