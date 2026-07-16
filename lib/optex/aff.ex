defmodule Optex.Aff do
  @moduledoc "Affine expression a^T x + b, sparse over variable ids."

  # terms: %{var_id => coefficient}, constant: number
  defstruct terms: %{}, constant: 0.0

  @type t :: %__MODULE__{terms: %{non_neg_integer() => float()}, constant: float()}

  def add(%__MODULE__{terms: t1, constant: c1}, %__MODULE__{terms: t2, constant: c2}) do
    %__MODULE__{terms: Map.merge(t1, t2, fn _id, a, b -> a + b end), constant: c1 + c2}
  end

  def scale(%__MODULE__{terms: t, constant: c}, k) when is_number(k) do
    %__MODULE__{terms: Map.new(t, fn {id, coef} -> {id, coef * k} end), constant: c * k}
  end

  def from_var(%Optex.Var{id: id}), do: %__MODULE__{terms: %{id => 1.0}, constant: 0.0}

  @doc "Normalize a leaf (variable, number, or Aff) to an Aff."
  def to_aff(%__MODULE__{} = a), do: a
  def to_aff(%Optex.Var{} = v), do: from_var(v)
  def to_aff(n) when is_number(n), do: %__MODULE__{terms: %{}, constant: n * 1.0}

  @doc """
  Multiply two normalized leaves. Handles a runtime-numeric coefficient on
  either side by scaling; raises on a genuine product of two expressions that
  both contain variables (that is a nonlinear term, out of scope for v1).
  """
  def mul(%__MODULE__{} = aff, k) when is_number(k), do: scale(aff, k)
  def mul(k, %__MODULE__{} = aff) when is_number(k), do: scale(aff, k)

  def mul(%__MODULE__{terms: t1} = a, %__MODULE__{terms: t2} = b) do
    cond do
      map_size(t1) == 0 -> scale(b, a.constant)
      map_size(t2) == 0 -> scale(a, b.constant)
      true -> raise Optex.NonlinearError, terms: Map.keys(t1) ++ Map.keys(t2)
    end
  end
end
