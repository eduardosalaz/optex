defmodule Optex.StreamRelay do
  @moduledoc false
  # Per-solve relay for the progress/incumbent streams. The NIF-side drain
  # threads send raw messages here; the relay rekeys incumbent values by
  # variable name (position == variable id, the standard wire contract) and
  # forwards everything to the user pids in arrival order. Spawned by
  # Optex.optimize/2 when `incumbents:` is requested (progress is routed
  # through it too so a user watching both streams sees them in order) and
  # stopped after the solve returns; the NIF joins its drain threads before
  # returning, so every event is already enqueued when the stop arrives.

  def start(progress_target, incumbent_target, id_names) do
    spawn_link(fn -> loop(progress_target, incumbent_target, id_names) end)
  end

  defp loop(progress_target, incumbent_target, id_names) do
    receive do
      {:optex_progress, _} = msg ->
        if progress_target, do: send(progress_target, msg)
        loop(progress_target, incumbent_target, id_names)

      {:optex_incumbent_raw, objective, values} ->
        named =
          values
          |> Enum.with_index()
          |> Map.new(fn {v, id} -> {Map.get(id_names, id, id), v} end)

        send(incumbent_target, {:optex_incumbent, %{objective: objective, values: named}})
        loop(progress_target, incumbent_target, id_names)

      :optex_relay_stop ->
        :ok
    end
  end
end
