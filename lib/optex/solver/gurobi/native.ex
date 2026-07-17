defmodule Optex.Solver.Gurobi.Native do
  @moduledoc false
  # The Gurobi crate can only build against an installed Gurobi SDK, so it is
  # compile-gated on GUROBI_HOME: without it this module compiles to stubs
  # that report unavailability, and plain checkouts build cleanly.
  # (Set GUROBI_HOME and `mix compile --force` to enable after installing.)

  # Serialize Rustler crate builds: concurrent `use Rustler` compilations
  # race on copying priv/native while another module is mid-replacing a DLL.
  {:module, _} = Code.ensure_compiled(Optex.Solver.HiGHS.Native)

  if System.get_env("GUROBI_HOME") do
    use Rustler, otp_app: :optex, crate: "optex_gurobi"

    def available?, do: true

    def solve(_input, _options), do: :erlang.nif_error(:nif_not_loaded)
    def iis(_input), do: :erlang.nif_error(:nif_not_loaded)
    def cancel_token, do: :erlang.nif_error(:nif_not_loaded)
    def cancel(_token), do: :erlang.nif_error(:nif_not_loaded)
  else
    def available?, do: false

    def solve(_input, _options), do: {:error, :gurobi_not_available}
    def iis(_input), do: {:error, :gurobi_not_available}
    def cancel_token, do: raise("Gurobi backend not available (GUROBI_HOME unset at compile)")
    def cancel(_token), do: raise("Gurobi backend not available (GUROBI_HOME unset at compile)")
  end
end
