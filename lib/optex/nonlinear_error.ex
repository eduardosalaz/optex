defmodule Optex.NonlinearError do
  defexception [:terms]

  def message(%{terms: ids}),
    do:
      "nonlinear term of degree > 2: product of expressions involving " <>
        "variable ids #{inspect(Enum.uniq(ids))} (at most quadratic terms " <>
        "are supported, in the objective and constraints)"
end
