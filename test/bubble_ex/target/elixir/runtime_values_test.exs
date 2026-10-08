defmodule BubbleEx.Target.Elixir.RuntimeValuesTest do
  # The generated runtime (templates/lib/app/bubble/runtime.ex.eex,
  # compiled here as a stand-alone module) on empty texts (WTF-514) and
  # case-insensitive texts (WTF-515; `Ash.CiString` is a stand-in,
  # test/support/ash_ci_string.ex). Synthetic values only.
  use ExUnit.Case, async: true

  alias BubbleEx.Target.Phoenix.Templates

  @module "RuntimeValuesCheck"
  @runtime Module.concat([@module, Bubble, Runtime])

  setup_all do
    unless Code.ensure_loaded?(@runtime) do
      source =
        Templates.render("lib/app/bubble/runtime.ex", %{
          module: @module,
          app: :runtime_values_check,
          enforced?: false
        })

      Code.compile_string(source)
    end

    %{rt: @runtime}
  end

  defp ci(string), do: %Ash.CiString{string: string}

  describe "an empty text is empty (WTF-514)" do
    test "unhidden/1 reads \"\" as nil, so is / is not see them equal", %{rt: rt} do
      assert rt.unhidden("") == nil
      assert rt.unhidden(nil) == nil
      assert rt.unhidden("") == rt.unhidden(nil)
      assert rt.unhidden("a") == "a"
      assert rt.unhidden(" ") == " "
    end

    test "numbers, yes/no, dates and lists keep their values", %{rt: rt} do
      for value <- [0, 0.0, false, true, [], ~U[2026-10-07 00:00:00Z], Decimal.new(0)] do
        assert rt.unhidden(value) == value
      end
    end

    test "an empty text is no ID", %{rt: rt} do
      assert rt.id("") == nil
      assert rt.id(nil) == nil
      assert rt.id("1700000000000x1") == "1700000000000x1"
      assert rt.id(%{id: "1700000000000x1"}) == "1700000000000x1"
    end

    test "is empty agrees", %{rt: rt} do
      assert rt.empty?("")
      assert rt.empty?(nil)
      refute rt.empty?(0)
      refute rt.empty?(false)
    end
  end

  describe "a case-insensitive text is its text (WTF-515)" do
    test "shown and converted", %{rt: rt} do
      assert rt.text(ci("Ada@Example.com")) == "Ada@Example.com"
      assert rt.display(ci("ada@example.com")) == "ada@example.com"
      assert rt.utc_text(ci("ada@example.com")) == "ada@example.com"
      assert rt.to_text(ci("ada@example.com")) == "ada@example.com"
      assert rt.text([ci("a@x.io"), ci("b@x.io")]) == "a@x.io, b@x.io"
      refute rt.text(ci("a@x.io")) =~ "CiString"
    end

    test "compared, sorted and given to the text operators", %{rt: rt} do
      assert rt.unhidden(ci("a@x.io")) == "a@x.io"
      assert rt.unhidden(ci("")) == nil
      assert rt.compare(:lt, ci("a@x.io"), "b@x.io")
      assert rt.sort_values([ci("b@x.io"), "a@x.io"], false) == ["a@x.io", ci("b@x.io")]

      assert rt.uppercase(ci("a@x.io")) == "A@X.IO"
      assert rt.lowercase(ci("A@x.io")) == "a@x.io"
      assert rt.trim(ci(" a@x.io ")) == "a@x.io"
      assert rt.text_length(ci("a@x.io")) == 6
      assert rt.text_contains?(ci("a@x.io"), "@x")
      assert rt.text_contains?("a@x.io", ci("@x"))
      assert rt.truncate(ci("a@x.io"), 1) == "a"
      assert rt.replace(ci("a@x.io"), "x", "y", false) == "a@y.io"
      assert rt.split(ci("a@x.io"), "@") == ["a", "x.io"]
      assert rt.json_encode(ci(~s(a"b@x.io))) == ~s(a\\"b@x.io)
      assert rt.url_encode(ci("a b@x.io")) == "a+b%40x.io"
      assert rt.is_email(ci("a@x.io"))
      assert rt.to_number(ci("12")) == 12
    end
  end
end
