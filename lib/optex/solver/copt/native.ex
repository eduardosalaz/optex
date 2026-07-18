defmodule Optex.Solver.COPT.Native do
  @moduledoc false
  # The COPT crate can only build against an installed Cardinal Optimizer,
  # so it is compile-gated on the COPT_HOME env var the installer sets:
  # without it this module compiles to stubs that report unavailability, and
  # plain checkouts build cleanly. (Set the variable and
  # `mix compile --force` to enable after installing.)

  # Serialize Rustler crate builds: concurrent `use Rustler` compilations
  # race on copying priv/native while another module is mid-replacing a DLL.
  {:module, _} = Code.ensure_compiled(Optex.Solver.CPLEX.Native)

  if System.get_env("COPT_HOME") do
    use Rustler, otp_app: :optex, crate: "optex_copt"

    def available?, do: true

    def solve(_input, _options), do: :erlang.nif_error(:nif_not_loaded)
    def iis(_input), do: :erlang.nif_error(:nif_not_loaded)
    def cancel_token, do: :erlang.nif_error(:nif_not_loaded)
    def cancel(_token), do: :erlang.nif_error(:nif_not_loaded)
  else
    def available?, do: false

    def solve(_input, _options), do: {:error, :copt_not_available}
    def iis(_input), do: {:error, :copt_not_available}

    def cancel_token,
      do: raise("COPT backend not available (no COPT_HOME var at compile)")

    def cancel(_token),
      do: raise("COPT backend not available (no COPT_HOME var at compile)")
  end
end
