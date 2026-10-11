defmodule BubbleEx.Frontend.Export.BbcodeTest do
  # BBCode around dynamic values (WTF-450): tags come from the text's own
  # literal parts only; values are opaque.
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.Export.Bbcode

  test "centered heading line boundaries match captured Bubble block markup" do
    source = "[center][b][size=4]Privacy Policy\n[/size][/b][/center]\n\nBody\n\nNext"

    expected =
      ~s(<div align="center"><strong><font size="4">Privacy Policy<div></div>\n</font></strong><br></div><div></div>\nBody<br><br>Next)

    assert Bbcode.to_html(source) == expected
    assert {nodes, []} = Bbcode.split([source], extended: true)
    assert Bbcode.render_nodes(nodes) == expected
    assert Bbcode.to_html("Plain\n\ntext") == "Plain<br><br>text"
    assert Bbcode.to_html("[unknown]Plain\ntext[/unknown]") == "[unknown]Plain<br>text[/unknown]"

    assert {nodes, []} =
             Bbcode.split(["[center][b]", {:value, "opaque\n<script>"}, "[/b][/center]\n\nBody"],
               extended: true
             )

    assert Bbcode.render_nodes(nodes) ==
             ~s(<div style="text-align: center"><strong>opaque\n&lt;script&gt;</strong></div><br><br>Body)
  end

  test "captured privacy heading uses native HTML font sizing safely" do
    assert Bbcode.to_html("[b][size=4]Privacy Policy\n[/size][/b]") ==
             ~s(<strong><font size="4">Privacy Policy<br></font></strong>)

    assert {nodes, []} =
             Bbcode.split(["[size=4]", {:value, "<script>[size=7]"}, "[/size]"], extended: true)

    assert Bbcode.render_nodes(nodes) == ~s(<font size="4">&lt;script&gt;[size=7]</font>)
    assert Bbcode.to_html("[size=4;position:fixed]x[/size]") == "x"
  end

  test "source legal text line breaks render without interpreting dynamic values" do
    assert Bbcode.to_html("[b]Heading\n[/b]\n\nA < B") ==
             "<strong>Heading<br></strong><br><br>A &lt; B"

    assert {nodes, []} = Bbcode.split(["[b]Literal\n", {:value, "<br>\n[b]opaque"}, "[/b]"])
    assert Bbcode.render_nodes(nodes) == "<strong>Literal<br>&lt;br&gt;\n[b]opaque</strong>"
  end

  test "captured alignment, superscript and safe colors render as inert formatting" do
    assert Bbcode.to_html("[center]More [i]choices[/i][/center]") ==
             ~s(<div style="text-align: center">More <em>choices</em></div>)

    assert Bbcode.to_html("[sup][color=#808080]@2026[/color][/sup]") ==
             ~s(<sup><span style="color: #808080">@2026</span></sup>)

    assert Bbcode.to_html("[color=red;position:fixed]x[/color]") == "x"

    assert {nodes, []} =
             Bbcode.split(["[center][sup]", {:value, "<script>[i]x[/i]"}, "[/sup][/center]"],
               extended: true
             )

    assert Bbcode.render_nodes(nodes) ==
             ~s(<div style="text-align: center"><sup>&lt;script&gt;[i]x[/i]</sup></div>)
  end

  test "dynamic safe colors wrap values without interpreting their brackets" do
    assert {nodes, []} =
             Bbcode.split(["[sup][color=#808080]@", {:value, "[b]<script>"}, "[/color][/sup]"],
               extended: true
             )

    assert Bbcode.render_nodes(nodes) ==
             ~s(<sup><span style="color: #808080">@[b]&lt;script&gt;</span></sup>)
  end

  test "literal tags wrap the values between them" do
    assert {[{:b, ["Title: ", {:value, :x}]}, " and ", {:i, [{:value, :y}]}], []} =
             Bbcode.split(["[b]Title: ", {:value, :x}, "[/b] and [I]", {:value, :y}, "[/i]"])
  end

  test "nested tags of the same name pair as the static renderer pairs them" do
    assert {[{:b, ["a", {:b, ["b"]}, "c"]}], []} = Bbcode.split(["[b]a[b]b[/b]c[/b]"])
    assert {[{:u, [{:s, [{:value, 1}]}]}], []} = Bbcode.split(["[u][s]", {:value, 1}, "[/s][/u]"])
  end

  test "unpaired and crossing tags stay text" do
    assert {["[b]open ", {:value, :x}], []} = Bbcode.split(["[b]open ", {:value, :x}])
    assert {[{:b, ["[i]x"]}, "[/i]"], []} = Bbcode.split(["[b][i]x[/b][/i]"])
    assert {["x[/b]", {:i, ["y"]}], []} = Bbcode.split(["x[/b][i]y[/i]"])
  end

  test "other known tags stay text and are reported" do
    assert {[{:b, [{:value, :v}]}, " [url=https://example.com]u[/url] [color=red]c[/color]"],
            ["color", "url"]} =
             Bbcode.split([
               "[b]",
               {:value, :v},
               "[/b] [url=https://example.com]u[/url] [color=red]c[/color]"
             ])

    # Brackets that are no BBCode are not reported.
    assert {[{:b, ["[note]"]}], []} = Bbcode.split(["[b][note][/b]"])
  end

  test "values are never read for tags: hostile values stay whole" do
    hostile = {:value, "[/b]<script>alert(1)</script>[i]x[/i]"}
    assert {[{:b, [^hostile]}], []} = Bbcode.split(["[b]", hostile, "[/b]"])

    # A value alone, or tags only in values: nothing to render.
    assert :none = Bbcode.split(["plain ", {:value, "[b]no[/b]"}])
    assert :none = Bbcode.split([{:value, "[b]"}, {:value, "[/b]"}])
  end
end
