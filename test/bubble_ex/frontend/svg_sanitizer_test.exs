defmodule BubbleEx.Frontend.SvgSanitizerTest do
  # Static SVGs from a Bubble app are served from the generated app's own
  # origin only after this rebuild (WTF-447).
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.SvgSanitizer

  defp sanitize!(svg) do
    assert {:ok, clean} = SvgSanitizer.sanitize(svg)
    # Idempotent: a stored copy is checked again when it is read.
    assert SvgSanitizer.sanitize(clean) == {:ok, clean}
    clean
  end

  test "keeps what a logo needs, with the SVG's own name case" do
    clean =
      sanitize!(~S"""
      <?xml version="1.0" encoding="UTF-8"?>
      <!-- Generator: Illustrator -->
      <svg version="1.1" id="Layer_1" xmlns="http://www.w3.org/2000/svg"
           xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 40">
        <defs>
          <linearGradient id="grad" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="100" y2="0">
            <stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/>
          </linearGradient>
          <clipPath id="clip"><rect width="100" height="40"/></clipPath>
        </defs>
        <style>.cls-1{fill:url(#grad);}</style>
        <g clip-path="url(#clip)" transform="translate(1 2)">
          <path class="cls-1" d="M0 0L100 40Z"/>
          <use xlink:href="#grad"/>
          <text x="1" y="30" font-family="Inter">Acme &amp; Co</text>
        </g>
      </svg>
      """)

    assert clean =~ ~s(<svg xmlns="http://www.w3.org/2000/svg" version="1.1" id="Layer_1")
    assert clean =~ ~s(viewBox="0 0 100 40")
    assert clean =~ ~s(<linearGradient id="grad" gradientUnits="userSpaceOnUse")
    assert clean =~ ~s(<clipPath id="clip">)
    assert clean =~ "<style>.cls-1{fill:url(#grad);}</style>"
    assert clean =~ ~S|<g clip-path="url(#clip)" transform="translate(1 2)">|
    assert clean =~ ~s(<use href="#grad"></use>)
    assert clean =~ "Acme &amp; Co"
    refute clean =~ "xmlns:xlink"
    refute clean =~ "<?xml"
    refute clean =~ "Generator"
  end

  test "drops script, handlers, foreign content and outside references" do
    clean =
      sanitize!(~S"""
      <svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)">
        <script>alert(1)</script>
        <script xlink:href="https://evil.example/x.js"/>
        <foreignObject><iframe src="https://evil.example/"></iframe></foreignObject>
        <image href="https://evil.example/track.png"/>
        <a href="javascript:alert(1)"><path d="M0 0"/></a>
        <animate attributeName="href" to="javascript:alert(1)"/>
        <set attributeName="onclick" to="alert(1)"/>
        <filter id="f"><feImage href="https://evil.example/x.png"/></filter>
        <use href="https://evil.example/sprite.svg#icon"/>
        <use href="data:image/svg+xml;base64,PHN2Zz4="/>
        <rect width="1" height="1" onclick="alert(1)" fill="url(https://evil.example/x)"/>
        <circle r="1" style="fill:url(https://evil.example/x)"/>
        <ellipse rx="1" ry="1" style="behavior:url(x.htc)"/>
        <style>@import url(https://evil.example/x.css);</style>
        <style>path{fill:red}</style>
        <path d="M0 0" fill="javascript:alert(1)" stroke="#000"/>
      </svg>
      """)

    for needle <-
          ~w(script onload onclick foreignObject iframe image <a animate <set filter feImage
             evil.example javascript data: @import behavior) do
      refute clean =~ needle, "#{needle} survived: #{clean}"
    end

    assert clean =~ "<style>path{fill:red}</style>"
    assert clean =~ ~s(<path d="M0 0" stroke="#000"></path>)
    assert clean =~ ~s(<rect width="1" height="1"></rect>)
    assert clean =~ ~s(<use></use>)
  end

  test "never expands entities or keeps a DOCTYPE" do
    clean =
      sanitize!(~S"""
      <!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd"><!ENTITY lol "lol">]>
      <svg xmlns="http://www.w3.org/2000/svg"><text>&xxe;&lol;</text></svg>
      """)

    refute clean =~ "DOCTYPE"
    refute clean =~ "ENTITY"
    refute clean =~ "root:"
    assert clean =~ "<text>&amp;xxe;&amp;lol;</text>"
  end

  test "escapes attribute values and text it keeps" do
    clean =
      sanitize!(
        ~S|<svg xmlns="http://www.w3.org/2000/svg"><text>a "b" &lt;c&gt;</text><title>t</title><path d="M0 0" class="x&quot; onload=&quot;alert(1)"/></svg>|
      )

    assert clean =~ "<text>a &quot;b&quot; &lt;c&gt;</text>"
    refute clean =~ "title"
    assert clean =~ ~S|class="x&quot; onload=&quot;alert(1)"|
    refute clean =~ ~s(" onload=")
  end

  test "refuses what is not one SVG document" do
    for input <- [
          "",
          "<html><body><svg></svg></body></html>",
          "<svg></svg><svg></svg>",
          "not svg at all",
          <<0x89, "PNG", 0xFF, 0xFE>>,
          ~s(<div><svg xmlns="http://www.w3.org/2000/svg"></svg></div>),
          String.duplicate("<g>", 100) |> then(&"<svg>#{&1}</svg>"),
          nil
        ] do
      assert SvgSanitizer.sanitize(input) == :error, inspect(input)
    end
  end
end
