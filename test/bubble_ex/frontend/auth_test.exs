defmodule BubbleEx.Frontend.AuthTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error
  alias BubbleEx.Frontend.{Auth, SafeUrl}

  test "builds a redacted exact-origin combined envelope" do
    username = "agency-user-unique"
    password = "agency-pass-unique"
    cookie = "session=session-value-unique; other=other-value-unique"

    assert {:ok, "https://App.Example.test/path", auth} =
             Auth.prepare("https://App.Example.test/path",
               username: username,
               password: password,
               session_cookie: cookie
             )

    expected = "Basic " <> Base.encode64(username <> ":" <> password)

    assert Auth.headers(auth, "https://app.example.test/other") == [
             {"authorization", expected},
             {"cookie", cookie}
           ]

    assert Auth.headers(auth, "https://app.example.test:444/other") == []
    assert inspect(auth) == "#BubbleEx.Frontend.Auth<redacted>"
    refute inspect(auth) =~ username
    refute inspect(auth) =~ password
    refute inspect(auth) =~ cookie
  end

  test "extracts and sanitizes URL userinfo before returning the URL" do
    raw = "https://agency%2Duser:agency%2Dpass@app.example.test/version-test#private"

    assert {:ok, sanitized, auth} = Auth.prepare(raw, [])
    assert sanitized == "https://app.example.test/version-test"
    assert Auth.enabled?(auth)

    inspected = inspect(auth)
    refute inspected =~ "agency-user"
    refute inspected =~ "agency-pass"
    refute inspected =~ raw
  end

  test "rejects invalid credentials without echoing them" do
    cases = [
      {"app", [username: "only-user"]},
      {"app", [password: "only-pass"]},
      {"app", [username: "", password: "secret-pass"]},
      {"app", [username: "bad:user", password: "secret-pass"]},
      {"app", [username: "bad\ruser", password: "secret-pass"]},
      {"app", [session_cookie: ""]},
      {"app", [session_cookie: "session=x\ny"]},
      {"https://url-user:url-pass@app.example.test",
       [username: "option-user", password: "option-pass"]},
      {"http://app.example.test", [username: "http-user", password: "http-pass"]}
    ]

    for {input, opts} <- cases do
      assert {:error, %Error{kind: :invalid_input} = error} = Auth.prepare(input, opts)
      rendered = inspect(error)

      for {_key, value} <- opts, is_binary(value), value != "" do
        refute rendered =~ value
      end
    end
  end

  test "safe URL rendering redacts credential echoes anywhere in a URL" do
    secret = "credential-echo-33-unique"
    rendered = SafeUrl.safe("https://example.test/#{secret}?ordinary=#{secret}", [secret])
    refute rendered =~ secret
    assert rendered =~ "[REDACTED]"
  end

  test "safe URL rendering removes userinfo and fragments and redacts sensitive query values" do
    rendered = SafeUrl.safe("https://u:p@Example.test/x?token=raw-secret&view=ok#fragment")
    refute rendered =~ "u:p"
    refute rendered =~ "raw-secret"
    refute rendered =~ "fragment"
    assert rendered =~ "view=ok"
    assert rendered =~ "token=%5BREDACTED%5D"
  end
end
