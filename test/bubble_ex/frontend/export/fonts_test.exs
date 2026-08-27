defmodule BubbleEx.Frontend.Export.FontsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.Export.Fonts

  test "discovers static Google WebFontConfig families and allowlisted stylesheet links" do
    html = """
    <html>
      <script>
        const WebFontConfig = {'google': { families: ["Inter:regular", "Inter:800"] },
          'custom': {families: ["Private Font"], urls: ["https://evil.example/font.css"]}};
      </script>
      <link rel="stylesheet" href="//fonts.googleapis.com/css2?family=Roboto:wght@400;700">
      <link rel="stylesheet" href="https://evil.example/site.css">
    </html>
    """

    sources = Fonts.discover(html, "https://app.example.test/page")

    assert "https://fonts.googleapis.com/css?family=Inter%3Aregular%7CInter%3A800" in sources
    assert "https://fonts.googleapis.com/css2?family=Roboto:wght@400;700" in sources
    refute Enum.any?(sources, &String.contains?(&1, "evil.example"))
  end

  test "rejects non-HTTPS and userinfo Google stylesheet URLs" do
    html = """
    <link rel="stylesheet" href="http://fonts.googleapis.com/css?family=Inter">
    <link rel="stylesheet" href="https://user:pass@fonts.googleapis.com/css?family=Inter">
    """

    assert Fonts.discover(html, "https://app.example.test") == []
  end
end
