defmodule BubbleEx.Secrets.NativeTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error
  alias BubbleEx.Secrets.Native

  @pat "ghp_0123456789abcdefABCDEF0123456789abcdef"

  test "finds a regex secret and reports its path with confidence :high" do
    payload = %{"_id" => "synthapp", "plugins" => %{"gh" => %{"token" => @pat}}}

    assert {:ok, [finding]} = Native.scan(payload)
    assert finding.detector == "github_pat"
    assert finding.raw == @pat
    assert finding.path == ["plugins", "gh", "token"]
    assert finding.decoder == :plain
    assert finding.verified == false
    assert finding.confidence == :high
    assert finding.redacted != @pat and String.contains?(finding.redacted, "ghp_")
  end

  test "returns [] when there are no secrets" do
    assert {:ok, []} = Native.scan(%{"_id" => "synthapp", "title" => "My App", "count" => 7})
  end

  test "accepts a JSON string payload" do
    assert {:ok, [finding]} =
             Native.scan(~s({"plugins":{"gh":{"token":"#{@pat}"}}}))

    assert finding.detector == "github_pat"
  end

  test "rejects non-object input with :invalid_input" do
    assert {:error, %Error{kind: :invalid_input}} = Native.scan("not json")
    assert {:error, %Error{kind: :invalid_input}} = Native.scan(123)
  end

  test "is a drop-in via the Secrets dispatcher" do
    payload = %{"plugins" => %{"gh" => %{"token" => @pat}}}
    assert {:ok, [%{detector: "github_pat"}]} = BubbleEx.Secrets.scan(payload, adapter: Native)
  end

  describe "base64-encoded secrets" do
    @pat "ghp_0123456789abcdefABCDEF0123456789abcdef"

    test "decodes a base64 leaf and finds the secret inside it" do
      encoded = Base.encode64("authorization: token " <> @pat)
      payload = %{"settings" => %{"blob" => encoded}}

      assert {:ok, findings} = Native.scan(payload)
      assert [finding] = Enum.filter(findings, &(&1.decoder == :base64))
      assert finding.detector == "github_pat"
      assert finding.raw == @pat
      assert finding.path == ["settings", "blob"]
    end

    test "does not crash on non-base64 strings" do
      assert {:ok, []} = Native.scan(%{"x" => "not base64 !!!"})
    end
  end

  describe "entropy tier (opt-in)" do
    @high "A7f9Qm2Zx4Lp8Wd1Rk6Yb3Nc5Vh0Tg"

    test "off by default — high-entropy non-secret under a sensitive key is ignored" do
      assert {:ok, []} = Native.scan(%{"api_key" => @high})
    end

    test "on with entropy: true — flags it as low confidence" do
      assert {:ok, [finding]} = Native.scan(%{"api_key" => @high}, entropy: true)
      assert finding.detector == "high_entropy_string"
      assert finding.confidence == :low
      assert finding.path == ["api_key"]
    end

    test "even with entropy: true, ignores high-entropy ids under non-sensitive keys" do
      assert {:ok, []} = Native.scan(%{"_id" => @high, "element_id" => @high}, entropy: true)
    end

    test "regex hit suppresses entropy tier — only one :high finding, no :low duplicate" do
      payload = %{"api_key" => @pat}
      {:ok, findings} = Native.scan(payload, entropy: true)

      assert Enum.count(findings, &(&1.detector == "github_pat")) == 1
      assert Enum.all?(findings, &(&1.confidence == :high))
      refute Enum.any?(findings, &(&1.detector == "high_entropy_string"))
    end
  end

  describe "redact/1" do
    test "short secret (≤12 chars) is fully masked with *s, length preserved" do
      raw = "short_secret"
      redacted = Native.redact(raw)
      assert String.length(redacted) == String.length(raw)
      assert redacted == String.duplicate("*", String.length(raw))
    end

    test "long secret (>12 chars) shows first 4 and last 4 chars with ellipsis" do
      raw = @pat
      redacted = Native.redact(raw)
      assert redacted != raw
      assert String.starts_with?(redacted, String.slice(raw, 0, 4))
      assert String.ends_with?(redacted, String.slice(raw, -4, 4))
    end

    test "multibyte short secret is fully masked with correct character count" do
      # "café" is 4 grapheme clusters but 5 bytes — must use char length
      raw = "café_key"
      redacted = Native.redact(raw)
      assert String.length(redacted) == String.length(raw)
      assert redacted == String.duplicate("*", String.length(raw))
    end
  end

  describe "dedup semantics" do
    test "same secret at two different paths yields two separate findings" do
      payload = %{"a" => %{"token" => @pat}, "b" => %{"token" => @pat}}
      {:ok, findings} = Native.scan(payload)
      paths = Enum.map(findings, & &1.path)
      assert length(findings) == 2
      assert ["a", "token"] in paths
      assert ["b", "token"] in paths
    end

    test "leaf containing the same secret substring twice collapses to one finding" do
      # Two occurrences of the exact same match string in one leaf
      value = @pat <> " " <> @pat
      {:ok, findings} = Native.scan(%{"token" => value})
      # Both scans produce identical {detector, raw, path, decoder} maps → deduped to 1
      assert length(findings) == 1
      assert hd(findings).detector == "github_pat"
    end
  end

  describe "JSON array input" do
    test "valid JSON array is rejected with :invalid_input" do
      assert {:error, %Error{kind: :invalid_input}} = Native.scan("[1,2,3]")
    end
  end

  describe "atom-keyed maps (Elixir map input)" do
    test "a regex finding on an atom key reports a string path (no atoms in path)" do
      assert {:ok, [finding]} = Native.scan(%{token: @pat})
      assert finding.path == ["token"]
      assert finding.detector == "github_pat"
    end

    test "entropy on an atom-keyed sensitive map does not crash and yields a string path" do
      high = "A7f9Qm2Zx4Lp8Wd1Rk6Yb3Nc5Vh0Tg"
      assert {:ok, [finding]} = Native.scan(%{api_key: high}, entropy: true)
      assert finding.detector == "high_entropy_string"
      assert finding.path == ["api_key"]
    end
  end
end
