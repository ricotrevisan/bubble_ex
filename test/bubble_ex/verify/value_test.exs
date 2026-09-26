defmodule BubbleEx.Verify.ValueTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error
  alias BubbleEx.Verify.Value

  defp cast!(json) do
    {:ok, value} = Value.cast(json)
    value
  end

  defp invalid(json), do: assert({:error, %Error{kind: :invalid_input}} = Value.cast(json))

  test "empty text is not empty; an empty list is Bubble's one empty state" do
    assert cast!(nil) == nil
    assert cast!(%{"text" => ""}) == {:text, ""}
    assert cast!(%{"list" => []}) == nil
  end

  test "protocol-relative file URLs become https" do
    assert cast!(%{"file" => "//files.example/a.pdf"}) == {:file, "https://files.example/a.pdf"}
    assert cast!(%{"image" => "//files.example/a.png"}) == {:image, "https://files.example/a.png"}
    assert {:error, _} = Value.cast(%{"file" => "//"})
  end

  test "text is kept verbatim" do
    assert cast!(%{"text" => "  padded \n"}) == {:text, "  padded \n"}
  end

  test "numbers are floats, with one zero" do
    assert cast!(%{"number" => 3}) == {:number, 3.0}
    assert cast!(%{"number" => 2.5}) == {:number, 2.5}
    assert Value.to_json(cast!(%{"number" => -0.0})) == %{"number" => 0.0}
    assert Jason.encode!(Value.to_json(cast!(%{"number" => 3}))) == ~s({"number":3.0})
    assert cast!(%{"date_interval" => 1000}) == {:date_interval, 1000.0}
  end

  test "dates are integer milliseconds" do
    assert cast!(%{"date" => 1_759_363_200_000}) == {:date, 1_759_363_200_000}
    invalid(%{"date" => "2026-10-02T00:00:00Z"})
    invalid(%{"date" => 1.5})
  end

  test "structured values have every component, in their component types" do
    assert cast!(%{
             "geographic_address" => %{"formatted_address" => "x", "lat" => 1, "lng" => nil}
           }) ==
             {:geographic_address, %{formatted_address: "x", lat: 1.0, lng: nil}}

    assert cast!(%{"date_range" => %{"start" => 1, "end" => nil}}) ==
             {:date_range, %{start: 1, end: nil}}

    assert cast!(%{"number_range" => %{"min" => 1, "max" => 2.5}}) ==
             {:number_range, %{min: 1.0, max: 2.5}}

    invalid(%{"date_range" => %{"start" => 1}})
    invalid(%{"date_range" => %{"start" => 1, "end" => 2, "extra" => 3}})
    invalid(%{"date_range" => %{"start" => "x", "end" => nil}})
    invalid(%{"geographic_address" => %{"formatted_address" => 1, "lat" => nil, "lng" => nil}})
  end

  test "json values are any JSON, kept verbatim" do
    assert cast!(%{"json" => %{"a" => [1, nil, "x"]}}) == {:json, %{"a" => [1, nil, "x"]}}
    assert cast!(%{"json" => nil}) == {:json, nil}
    assert cast!(%{"json" => 1}) == {:json, 1}
  end

  test "lists are ordered, homogeneous, flat and have no empty items" do
    assert cast!(%{"list" => [%{"text" => "b"}, %{"text" => "a"}]}) ==
             {:list, [{:text, "b"}, {:text, "a"}]}

    invalid(%{"list" => [%{"text" => "a"}, %{"number" => 1}]})
    invalid(%{"list" => [nil]})
    invalid(%{"list" => [%{"list" => []}]})
  end

  test "references, options and files are non-empty strings" do
    assert cast!(%{"ref" => "task_1"}) == {:ref, "task_1"}
    assert cast!(%{"option" => "open"}) == {:option, "open"}

    assert cast!(%{"image" => "https://files.example/a.png"}) ==
             {:image, "https://files.example/a.png"}

    invalid(%{"ref" => ""})
    invalid(%{"option" => 1})
  end

  test "unknown types, several members and bare JSON values are rejected" do
    invalid(%{"money" => 1})
    invalid(%{"text" => "a", "number" => 1})
    invalid("a")
    invalid(1)
    invalid(%{})
  end

  test "to_json inverts cast" do
    for json <- [
          nil,
          %{"text" => ""},
          %{"number" => 1.5},
          %{"boolean" => true},
          %{"date" => 0},
          %{"file" => "f"},
          %{"ref" => "r"},
          %{"option" => "o"},
          %{"date_interval" => 5.0},
          %{"json" => %{"k" => [1]}},
          %{"list" => [%{"ref" => "a"}, %{"ref" => "b"}]},
          %{"number_range" => %{"min" => nil, "max" => 1.0}}
        ] do
      assert json |> cast!() |> Value.to_json() == json
    end
  end

  test "canonical/1 normalizes Elixir-built values and refs/1 lists references" do
    assert Value.canonical({:number, 2}) == {:ok, {:number, 2.0}}
    assert {:error, _} = Value.canonical({:date, "today"})
    assert Value.refs({:list, [{:ref, "a"}, {:ref, "b"}]}) == ["a", "b"]
    assert Value.refs({:text, "a"}) == []
  end
end
