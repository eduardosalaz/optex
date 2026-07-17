defmodule Optex.NonlinearError do
  defexception [:terms]

  def message(%{terms: ids}),
    do:
      "nonlinear term of degree > 2: product of expressions involving " <>
        "variable ids #{inspect(Enum.uniq(ids))} (quadratic terms are only " <>
        "supported in the objective)"
end
