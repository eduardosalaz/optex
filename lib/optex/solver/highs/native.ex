defmodule Optex.Solver.HiGHS.Native do
  @moduledoc false
  use Rustler, otp_app: :optex, crate: "optex_highs"

  # Milestone 0 bridge check; replaced by the real solve NIF in Milestone 4.
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
