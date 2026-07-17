defmodule Optex.Solver.CPLEX.Native do
  @moduledoc false
  # The CPLEX crate can only build against an installed CPLEX Studio, so it
  # is compile-gated on the versioned CPLEX_STUDIO_DIR* env var the installer
  # sets: without one this module compiles to stubs that report
  # unavailability, and plain checkouts build cleanly. (Set the variable and
  # `mix compile --force` to enable after installing.)

  if Enum.any?(System.get_env(), fn {k, _} -> String.starts_with?(k, "CPLEX_STUDIO_DIR") end) do
    use Rustler, otp_app: :optex, crate: "optex_cplex"

    def available?, do: true

    def solve(_input, _options), do: :erlang.nif_error(:nif_not_loaded)
    def iis(_input), do: :erlang.nif_error(:nif_not_loaded)
    def cancel_token, do: :erlang.nif_error(:nif_not_loaded)
    def cancel(_token), do: :erlang.nif_error(:nif_not_loaded)
  else
    def available?, do: false

    def solve(_input, _options), do: {:error, :cplex_not_available}
    def iis(_input), do: {:error, :cplex_not_available}

    def cancel_token,
      do: raise("CPLEX backend not available (no CPLEX_STUDIO_DIR* var at compile)")

    def cancel(_token),
      do: raise("CPLEX backend not available (no CPLEX_STUDIO_DIR* var at compile)")
  end
end
