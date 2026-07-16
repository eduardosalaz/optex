defmodule Optex.NonlinearError do
  defexception [:terms]

  def message(%{terms: ids}),
    do: "nonlinear term: product of expressions involving variable ids #{inspect(ids)}"
end
