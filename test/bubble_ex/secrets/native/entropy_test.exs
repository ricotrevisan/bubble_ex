defmodule BubbleEx.Secrets.Native.EntropyTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Secrets.Native.Entropy

  test "shannon entropy is 0 for a single repeated char and high for random" do
    assert Entropy.shannon("aaaaaaaa") == 0.0
    assert Entropy.shannon("A7f9Qm2Zx4Lp8Wd1Rk6Yb3Nc5Vh0Tg") > 4.0
  end

  test "candidate? requires a sensitive key, length, and entropy" do
    high = "A7f9Qm2Zx4Lp8Wd1Rk6Yb3Nc5Vh0Tg"

    assert Entropy.candidate?("api_key", high)
    refute Entropy.candidate?("description", high), "non-sensitive key is rejected"
    refute Entropy.candidate?("api_key", "short"), "too short is rejected"
    refute Entropy.candidate?(nil, high), "list-element (nil key) is rejected"
    refute Entropy.candidate?("api_key", "aaaaaaaaaaaaaaaaaaaaaaaa"), "low entropy is rejected"
  end
end
