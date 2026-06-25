defmodule BubbleEx.Secrets.Native.DetectorsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Secrets.Native.Detectors

  test "detects a GitHub PAT embedded in surrounding text" do
    raw = "ghp_0123456789abcdefABCDEF0123456789abcdef"

    assert [%{detector: "github_pat", raw: ^raw}] =
             Detectors.scan_value("token=" <> raw <> ";")
  end

  test "detects a GitHub fine-grained PAT (github_pat_...)" do
    raw = "github_pat_" <> String.duplicate("a", 82)
    assert [%{detector: "github_pat", raw: ^raw}] = Detectors.scan_value(raw)
  end

  test "detects AWS temporary STS access key IDs (ASIA...)" do
    assert [%{detector: "aws_access_key_id", raw: "ASIAABCDEFGHIJKLMNOP"}] =
             Detectors.scan_value("ASIAABCDEFGHIJKLMNOP")
  end

  test "detects AWS, Stripe, Google, and JWT secrets" do
    assert [%{detector: "aws_access_key_id"}] = Detectors.scan_value("AKIAABCDEFGHIJKLMNOP")

    # Literal split so secret scanners / GitHub push protection don't flag this
    # synthetic Stripe fixture; the concatenated runtime value is unchanged.
    assert [%{detector: "stripe_secret_key"}] =
             Detectors.scan_value("sk_live_" <> "0123456789abcdefABCDEFgh")

    assert [%{detector: "google_api_key"}] =
             Detectors.scan_value("AIzaSyA0123456789_-abcdefghijklmnopqrstu")

    assert [%{detector: "jwt"}] =
             Detectors.scan_value("eyJhbGci.eyJzdWIiOiI1NTUiLCJuYW1lIjoiSm9lIn0.s3cr3t-sig")
  end

  test "captures a full PEM private-key block (header through footer)" do
    pem = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Q
    uKUpRKfFLfRYC9AIKjbJTWit+CqvjG1lwsLNDjkDvR9V8w8jJ8pZb1nWcb9k3Q==
    -----END RSA PRIVATE KEY-----
    """

    assert [%{raw: raw}] =
             Enum.filter(Detectors.scan_value(pem), &(&1.detector == "private_key"))

    assert raw =~ "-----BEGIN RSA PRIVATE KEY-----"
    assert raw =~ "-----END RSA PRIVATE KEY-----"
    assert String.contains?(raw, "MIIBOgIBAAJBAKj34")
  end

  test "returns [] for ordinary strings (no false positives)" do
    assert Detectors.scan_value("just a normal sentence") == []
    assert Detectors.scan_value("user@example.com") == []
  end
end
