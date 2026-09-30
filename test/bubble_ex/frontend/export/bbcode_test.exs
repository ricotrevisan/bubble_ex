defmodule BubbleEx.Frontend.Export.BbcodeTest do
  # BBCode around dynamic values (WTF-450): tags come from the text's own
  # literal parts only; values are opaque.
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.Export.Bbcode

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
