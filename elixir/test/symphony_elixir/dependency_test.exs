defmodule SymphonyElixir.DependencyTest do
  use ExUnit.Case, async: true

  test "untrusted decimal exponents are bounded at the parser and Ecto boundary" do
    assert Decimal.parse("1e1000000000") == :error
    assert Ecto.Type.cast(:decimal, "1e1000000000") == :error
    assert Ecto.Type.cast(:decimal, "12.50") == {:ok, Decimal.new("12.50")}
  end
end
