defmodule Optex.Solver.HiGHS.Native do
  @moduledoc false
  use Rustler, otp_app: :optex, crate: "optex_highs"

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
