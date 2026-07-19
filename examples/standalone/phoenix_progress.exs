# A live solver dashboard in one file: Phoenix LiveView + Optex streaming.
#
# The solve runs in a Task; `progress:` and `incumbents:` point at the
# LiveView process, so solver telemetry arrives as ordinary handle_info
# messages and re-renders the page. The cancel button fires the token from
# the browser. No solver callbacks, no user code on solver threads: the
# LiveView IS the callback.
#
# Run OUTSIDE the repo's Mix project (Mix.install refuses to run inside
# one), with plain elixir, not mix run:
#
#     elixir examples/standalone/phoenix_progress.exs
#
# then open http://localhost:4001. First run downloads deps, including
# Optex's precompiled HiGHS NIF: no Rust toolchain needed.

Mix.install([
  {:phoenix_playground, "~> 0.1.8"},
  {:optex, "~> 0.1.1"}
])

defmodule SolveLive do
  use Phoenix.LiveView

  import Optex.DSL

  def mount(_params, _session, socket) do
    {:ok, reset(socket)}
  end

  def handle_event("solve", _params, %{assigns: %{solving: false}} = socket) do
    lv = self()
    token = Optex.Solver.HiGHS.cancel_token()
    m = build_model()

    Task.async(fn ->
      Optex.optimize(m,
        progress: lv,
        progress_every: 100,
        incumbents: lv,
        cancel: token,
        threads: 1,
        mip_gap: 1.0e-9
      )
    end)

    {:noreply, assign(reset(socket), solving: true, token: token)}
  end

  def handle_event("solve", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    if socket.assigns.token, do: Optex.Solver.HiGHS.cancel(socket.assigns.token)
    {:noreply, socket}
  end

  # solver telemetry lands here as plain messages
  def handle_info({:optex_progress, p}, socket) do
    {:noreply,
     assign(socket, best_obj: p.best_obj, best_bound: p.best_bound, gap: p.gap, nodes: p.nodes)}
  end

  def handle_info({:optex_incumbent, %{objective: obj, values: values}}, socket) do
    picked = Enum.count(values, fn {_name, v} -> v > 0.5 end)
    {:noreply, update(socket, :incumbents, &[{obj, picked} | &1])}
  end

  # the Task finishing
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, sol} ->
        {:noreply,
         assign(socket, solving: false, token: nil, status: sol.status, objective: sol.objective)}

      {:error, reason} ->
        {:noreply, assign(socket, solving: false, token: nil, status: inspect(reason))}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div style="max-width: 640px; margin: 2rem auto; font-family: sans-serif;">
      <h1>Optex live solve</h1>
      <p>
        A 120-item, 3-knapsack MIP solved to a 1e-9 gap so the branch-and-bound
        tree has something to stream.
      </p>

      <button phx-click="solve" disabled={@solving}>Solve</button>
      <button phx-click="cancel" disabled={!@solving}>Cancel</button>

      <h2>Search state</h2>
      <table style="border-collapse: collapse;">
        <tr :for={
          {label, v} <- [
            {"status", @status || (@solving && "solving...") || "idle"},
            {"best objective", fmt(@best_obj)},
            {"best bound", fmt(@best_bound)},
            {"gap", fmt_gap(@gap)},
            {"nodes", fmt(@nodes)},
            {"final objective", fmt(@objective)}
          ]
        }>
          <td style="padding: 2px 16px 2px 0; color: #666;">{label}</td>
          <td style="padding: 2px 0;"><strong>{v}</strong></td>
        </tr>
      </table>

      <h2>Incumbent trail</h2>
      <p :if={@incumbents == []} style="color: #666;">no incumbents yet</p>
      <ol reversed>
        <li :for={{obj, picked} <- @incumbents}>
          objective {fmt(obj)} ({picked} items)
        </li>
      </ol>
    </div>
    """
  end

  defp reset(socket) do
    assign(socket,
      solving: false,
      token: nil,
      status: nil,
      objective: nil,
      best_obj: nil,
      best_bound: nil,
      gap: nil,
      nodes: nil,
      incumbents: []
    )
  end

  defp fmt(nil), do: "-"
  defp fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 1)
  defp fmt(v), do: to_string(v)

  defp fmt_gap(nil), do: "-"
  defp fmt_gap(gap), do: "#{:erlang.float_to_binary(gap * 100, decimals: 3)}%"

  defp build_model do
    items = 1..120
    w1 = Map.new(items, fn i -> {i, rem(i * 7919, 199) + 11} end)
    w2 = Map.new(items, fn i -> {i, rem(i * 6733, 211) + 7} end)
    w3 = Map.new(items, fn i -> {i, rem(i * 104_729, 223) + 13} end)
    value = Map.new(items, fn i -> {i, rem(i * 31_337, 197) + 19} end)
    cap1 = w1 |> Map.values() |> Enum.sum() |> div(3)
    cap2 = w2 |> Map.values() |> Enum.sum() |> div(3)
    cap3 = w3 |> Map.values() |> Enum.sum() |> div(3)

    model sense: :max do
      variable take[i], i <- items, type: :bin
      constraint sum(w1[i] * take[i], i <- items) <= cap1
      constraint sum(w2[i] * take[i], i <- items) <= cap2
      constraint sum(w3[i] * take[i], i <- items) <= cap3
      objective sum(value[i] * take[i], i <- items)
    end
  end
end

PhoenixPlayground.start(live: SolveLive, port: 4001, open_browser: false)
