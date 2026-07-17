defmodule Optex.AffTest do
  use ExUnit.Case, async: true

  alias Optex.{Aff, Var}

  describe "add/2" do
    test "merges disjoint terms and sums constants" do
      a = %Aff{terms: %{0 => 2.0}, constant: 1.0}
      b = %Aff{terms: %{1 => 3.0}, constant: 4.0}

      assert Aff.add(a, b) == %Aff{terms: %{0 => 2.0, 1 => 3.0}, constant: 5.0}
    end

    test "sums coefficients for duplicate variable ids" do
      a = %Aff{terms: %{0 => 2.0, 1 => 1.0}, constant: 0.0}
      b = %Aff{terms: %{0 => 3.5}, constant: 0.0}

      assert Aff.add(a, b) == %Aff{terms: %{0 => 5.5, 1 => 1.0}, constant: 0.0}
    end

    test "coefficients that cancel remain as explicit zero entries" do
      a = %Aff{terms: %{0 => 2.0}, constant: 0.0}
      b = %Aff{terms: %{0 => -2.0}, constant: 0.0}

      assert Aff.add(a, b).terms == %{0 => 0.0}
    end
  end

  describe "scale/2" do
    test "scales every term and the constant" do
      a = %Aff{terms: %{0 => 2.0, 3 => -1.0}, constant: 5.0}

      assert Aff.scale(a, 2.0) == %Aff{terms: %{0 => 4.0, 3 => -2.0}, constant: 10.0}
    end

    test "scaling by 0 zeroes terms and constant" do
      a = %Aff{terms: %{0 => 2.0}, constant: 5.0}

      assert Aff.scale(a, 0) == %Aff{terms: %{0 => 0.0}, constant: 0.0}
    end

    test "scaling by a negative integer works" do
      a = %Aff{terms: %{0 => 2.0}, constant: 1.0}

      assert Aff.scale(a, -3) == %Aff{terms: %{0 => -6.0}, constant: -3.0}
    end
  end

  describe "to_aff/1" do
    test "a Var becomes a single unit term" do
      v = %Var{id: 7}

      assert Aff.to_aff(v) == %Aff{terms: %{7 => 1.0}, constant: 0.0}
    end

    test "a number becomes a constant-only Aff as a float" do
      assert Aff.to_aff(3) == %Aff{terms: %{}, constant: 3.0}
      assert Aff.to_aff(2.5) == %Aff{terms: %{}, constant: 2.5}
    end

    test "an Aff passes through unchanged" do
      a = %Aff{terms: %{1 => 4.0}, constant: -2.0}

      assert Aff.to_aff(a) == a
    end
  end

  describe "mul/2" do
    test "number x Aff and Aff x number both scale" do
      a = %Aff{terms: %{0 => 2.0}, constant: 1.0}

      assert Aff.mul(a, 3) == %Aff{terms: %{0 => 6.0}, constant: 3.0}
      assert Aff.mul(3, a) == %Aff{terms: %{0 => 6.0}, constant: 3.0}
    end

    test "constant-only Aff x variable-bearing Aff scales (both orders)" do
      k = %Aff{terms: %{}, constant: 4.0}
      a = %Aff{terms: %{0 => 2.0}, constant: 1.0}

      assert Aff.mul(k, a) == %Aff{terms: %{0 => 8.0}, constant: 4.0}
      assert Aff.mul(a, k) == %Aff{terms: %{0 => 8.0}, constant: 4.0}
    end

    # v1 rejected any variable product; quadratic terms are representable
    # since the quadratic-objective feature (degree > 2 still raises)
    test "variable-bearing Aff x variable-bearing Aff yields quadratic terms" do
      a = %Aff{terms: %{0 => 1.0}, constant: 0.0}
      b = %Aff{terms: %{1 => 1.0}, constant: 0.0}

      assert Aff.mul(a, b).qterms == %{{0, 1} => 1.0}
    end

    test "a variable times itself yields a diagonal quadratic term" do
      a = %Aff{terms: %{0 => 1.0}, constant: 0.0}

      assert Aff.mul(a, a).qterms == %{{0, 0} => 1.0}
    end

    test "a product of degree greater than two raises NonlinearError" do
      a = %Aff{terms: %{0 => 1.0}, constant: 0.0}
      sq = Aff.mul(a, a)

      assert_raise Optex.NonlinearError, ~r/variable ids/, fn -> Aff.mul(sq, a) end
    end
  end
end
