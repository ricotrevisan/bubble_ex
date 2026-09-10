defmodule BubbleEx.Frontend.InitialStateTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.{Auth, Fetch, InitialState}
  alias BubbleEx.FrontendFixtures

  @tag :tmp_dir
  test "anonymous fetched exports evaluate only direct logged-out visibility conditions", %{
    tmp_dir: tmp
  } do
    payload = payload()
    url = "https://example.bubbleapps.io/"
    {:ok, _, anonymous} = Auth.prepare(url, [])
    context = %Fetch.Context{page_url: url, auth: anonymous}
    opts = [force: true, secret_scan_adapter: FrontendFixtures.clean_scanner()]
    assert {:ok, exported} = Frontend.export_fetched(payload, tmp, opts, context)
    [page] = exported.model.pages
    [button] = page.children
    refute button.box[:hidden?]
    assert exported.model.source.payload == payload
    assert exported.manifest["options"]["initial_user"] == "anonymous"

    {:ok, _, session} = Auth.prepare(url, session_cookie: "bubble-session=example")
    context = %{context | auth: session}

    assert {:ok, exported} =
             Frontend.export_fetched(payload, Path.join(tmp, "session"), opts, context)

    assert hd(hd(exported.model.pages).children).box[:hidden?]
  end

  test "payload-only normalization retains authored initial visibility" do
    assert {:ok, model} = Frontend.normalize(payload())
    assert hd(hd(model.pages).children).box[:hidden?]
  end

  test "unknown and chained conditions cannot reveal an initially hidden element" do
    direct = get_in(payload(), ["pages", "index", "elements", "button", "%s", "0", "%c"])

    for condition <- [
          put_in(direct, ["%n", "%nm"], "logged_in"),
          put_in(direct, ["%n", "%n"], %{"%nm" => "and", "%a" => false}),
          Map.put(direct, "%x", "ThisElement")
        ] do
      payload =
        put_in(payload(), ["pages", "index", "elements", "button", "%s", "0", "%c"], condition)

      assert {:ok, model} = Frontend.normalize(payload)

      context = %Fetch.Context{
        page_url: "https://example.bubbleapps.io/",
        auth: %Auth{origin: "https://example.bubbleapps.io"}
      }

      projected = InitialState.project(model, context)
      assert hd(hd(projected.pages).children).box[:hidden?]
      assert projected.source.payload == payload
    end
  end

  test "a hidden static icon button retains its native representation" do
    payload =
      update_in(
        payload(),
        ["pages", "index", "elements", "button", "%p"],
        &Map.merge(&1, %{"%9i" => "fa fa-google", "button_type" => "label_icon"})
      )

    assert {:ok, model} = Frontend.normalize(payload)
    button = hd(hd(model.pages).children)
    assert button.kind == :button
    assert button.variant == :label_icon
    assert button.box[:hidden?]
  end

  test "a fetched snapshot resolves a formatted year without discarding its expression" do
    year = %{
      "%x" => "PageData",
      "%p" => %{"%nm" => "Current Date/Time"},
      "%n" => %{"%nm" => "format_date", "%p" => %{"%ft" => "custom", "custom_format" => "yyyy"}}
    }

    expression = %{
      "%x" => "TextExpression",
      "%e" => %{"0" => "© ", "1" => year, "2" => " Example"}
    }

    payload = put_in(payload(), ["pages", "index", "elements", "button", "%p", "%3"], expression)
    assert {:ok, model} = Frontend.normalize(payload)

    context = %Fetch.Context{
      page_url: "https://example.test/",
      auth: %Auth{origin: "https://example.test"},
      snapshot_at: ~U[2026-09-10 12:00:00Z]
    }

    node =
      model
      |> InitialState.project(context)
      |> Map.fetch!(:pages)
      |> hd()
      |> Map.fetch!(:children)
      |> hd()

    assert node.content["label"][:resolved] == "© 2026 Example"
    assert node.bindings["label"].payload == expression

    context = %{context | snapshot_at: ~U[2027-09-10 12:00:00Z]}
    next = InitialState.project(model, context)
    assert hd(hd(next.pages).children).content["label"][:resolved] == "© 2027 Example"

    custom_zone = put_in(year, ["%n", "%p", "timezone"], "Pacific/Honolulu")
    unknown = put_in(expression, ["%e", "1"], custom_zone)
    payload = put_in(payload, ["pages", "index", "elements", "button", "%p", "%3"], unknown)
    assert {:ok, model} = Frontend.normalize(payload)
    projected = InitialState.project(model, context)
    refute hd(hd(projected.pages).children).content["label"][:resolved]
  end

  defp payload do
    %{
      "_id" => "initial-state",
      "pages" => %{
        "index" => %{
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "button" => %{
              "%x" => "Button",
              "id" => "signup",
              "%p" => %{"%3" => "Sign up", "%iv" => false, "collapse_when_hidden" => true},
              "%s" => %{
                "0" => %{
                  "%x" => "State",
                  "%p" => %{"%iv" => true},
                  "%c" => %{
                    "%x" => "CurrentUser",
                    "%n" => %{"%x" => "Message", "%nm" => "not_logged_in"}
                  }
                }
              }
            }
          }
        }
      }
    }
  end
end
