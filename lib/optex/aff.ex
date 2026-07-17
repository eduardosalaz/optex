defmodule Optex.Aff do
  @moduledoc """
  Affine-plus-quadratic expression a^T x + x^T C x + b, sparse over variable
  ids. `terms` holds the linear part; `qterms` holds quadratic coefficients
  keyed by normalized `{lo_id, hi_id}` pairs (so `x*y` and `y*x` sum into one
  cell, and `x*x` lives at `{i, i}`). Coefficients are literal: the qterm
  coefficient of `{i, j}` is exactly the coefficient of `x_i * x_j` as
  written. Products of degree greater than two raise `Optex.NonlinearError`.
  """

  # terms: %{var_id => coefficient}, qterms: %{{lo, hi} => coefficient}
  defstruct terms: %{}, qterms: %{}, constant: 0.0

  @type t :: %__MODULE__{
          terms: %{non_neg_integer() => float()},
          qterms: %{{non_neg_integer(), non_neg_integer()} => float()},
          constant: float()
        }

  @doc "Add two expressions; coefficients of shared cells sum."
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      terms: Map.merge(a.terms, b.terms, fn _id, x, y -> x + y end),
      qterms: Map.merge(a.qterms, b.qterms, fn _key, x, y -> x + y end),
      constant: a.constant + b.constant
    }
  end

  @doc "Multiply every coefficient and the constant by a number."
  def scale(%__MODULE__{} = a, k) when is_number(k) do
    %__MODULE__{
      terms: Map.new(a.terms, fn {id, coef} -> {id, coef * k} end),
      qterms: Map.new(a.qterms, fn {key, coef} -> {key, coef * k} end),
      constant: a.constant * k
    }
  end

  @doc "The affine expression `1.0 * var`."
  def from_var(%Optex.Var{id: id}), do: %__MODULE__{terms: %{id => 1.0}, constant: 0.0}

  @doc "Normalize a leaf (variable, number, or Aff) to an Aff."
  def to_aff(%__MODULE__{} = a), do: a
  def to_aff(%Optex.Var{} = v), do: from_var(v)
  def to_aff(n) when is_number(n), do: %__MODULE__{terms: %{}, constant: n * 1.0}

  @doc """
  Multiply two normalized leaves. Numbers and constant-only expressions
  scale; the product of two linear expressions yields quadratic terms; any
  product whose degree would exceed two raises `Optex.NonlinearError`.
  """
  def mul(%__MODULE__{} = aff, k) when is_number(k), do: scale(aff, k)
  def mul(k, %__MODULE__{} = aff) when is_number(k), do: scale(aff, k)

  def mul(%__MODULE__{} = a, %__MODULE__{} = b) do
    cond do
      constant?(a) ->
        scale(b, a.constant)

      constant?(b) ->
        scale(a, b.constant)

      a.qterms != %{} or b.qterms != %{} ->
        raise Optex.NonlinearError,
          terms: involved_ids(a) ++ involved_ids(b)

      true ->
        # (L1 + c1)(L2 + c2) = L1*L2 + c2*L1 + c1*L2 + c1*c2
        qterms =
          for {i, ci} <- a.terms, {j, cj} <- b.terms, reduce: %{} do
            acc ->
              key = if i <= j, do: {i, j}, else: {j, i}
              Map.update(acc, key, ci * cj, &(&1 + ci * cj))
          end

        # zero constants contribute no linear cross terms (avoids spurious
        # 0.0 entries in the pure product case)
        terms =
          %{}
          |> merge_scaled(a.terms, b.constant)
          |> merge_scaled(b.terms, a.constant)

        %__MODULE__{
          terms: terms,
          qterms: qterms,
          constant: a.constant * b.constant
        }
    end
  end

  @doc "Whether the expression carries any quadratic terms."
  def quadratic?(%__MODULE__{qterms: q}), do: q != %{}

  defp constant?(%__MODULE__{terms: t, qterms: q}), do: t == %{} and q == %{}

  defp merge_scaled(acc, _terms, k) when k == 0.0, do: acc

  defp merge_scaled(acc, terms, k) do
    Enum.reduce(terms, acc, fn {id, coef}, acc ->
      Map.update(acc, id, coef * k, &(&1 + coef * k))
    end)
  end

  defp involved_ids(%__MODULE__{terms: t, qterms: q}) do
    Map.keys(t) ++ Enum.flat_map(Map.keys(q), fn {i, j} -> [i, j] end)
  end
end
