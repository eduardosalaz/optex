defmodule Optex.Solver.HiGHS.Native do
  @moduledoc false
  use Rustler, otp_app: :optex, crate: "optex_highs"

  # Dirty-CPU NIF: takes a prepared %Optex.SolverInput{} and a
  # %Optex.Solver.HiGHS.Options{}; returns
  # {:ok, %Optex.SolveResult{}} | {:error, reason}. Replaced at load time.
  def solve(_input, _options), do: :erlang.nif_error(:nif_not_loaded)
end
