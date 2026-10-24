defmodule BubbleEx.Apps.PlanTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Apps.Plan

  doctest BubbleEx.Apps.Plan

  defp live(status, location \\ nil), do: %{status: status, location: location}

  defp classify(live, opts \\ []) do
    Plan.classify(%{
      live: live,
      exists: Keyword.get(opts, :exists, :unknown),
      template?: Keyword.get(opts, :template?, false)
    })
  end

  describe "classify/1" do
    test "a live 200 means paid" do
      assert %{plan: :paid, basis: "live 200", dedicated_server: nil, base_url: nil} =
               classify(live(200))
    end

    test "a 301 to a customer's own domain means paid" do
      assert %{plan: :paid, basis: "live 301 -> custom domain"} =
               classify(live(301, "https://www.example.com/"))
    end

    test "a 302 to a bubble.is server means dedicated hosting" do
      assert %{
               plan: :dedicated,
               basis: "live 302 -> d121.bubble.is",
               dedicated_server: "d121",
               base_url: "https://d121.bubble.is"
             } = classify(live(302, "https://d121.bubble.is/version-live"))
    end

    test "a dedicated location without a version segment keeps its path" do
      assert %{
               plan: :dedicated,
               dedicated_server: "d123",
               base_url: "https://d123.bubble.is/site/app"
             } =
               classify(live(302, "https://d123.bubble.is/site/app"))
    end

    test "a live_not_supported redirect is free once version-test serves the app" do
      assert %{
               plan: :free,
               basis: "live 302 live_not_supported; version-test serves the app",
               dedicated_server: nil,
               base_url: nil
             } =
               classify(live(302, "https://bubble.io/live_not_supported?appname=myapp"),
                 exists: :yes
               )
    end

    test "a live_not_supported redirect proves nothing about a name nobody claimed" do
      assert %{
               plan: nil,
               basis: "no evidence (live 302 live_not_supported; the app is not confirmed)"
             } =
               classify(live(302, "https://bubble.io/live_not_supported?appname=myapp"),
                 exists: :no
               )

      assert %{
               plan: nil,
               basis: "no evidence (live 302 live_not_supported; the app is not confirmed)"
             } =
               classify(live(302, "https://bubble.io/live_not_supported?appname=myapp"),
                 exists: :unknown
               )
    end

    test "a live 400 names an invalid app" do
      assert %{plan: nil, basis: "live 400 invalid appname"} = classify(live(400))
    end

    test "a live 429 is no evidence, never paid" do
      assert %{plan: nil, basis: "no evidence (live 429)"} = classify(live(429))
    end

    test "5xx responses, timeouts and transport errors are no evidence" do
      assert %{plan: nil, basis: "no evidence (live 503)"} = classify(live(503))
      assert %{plan: nil, basis: "no evidence (timeout)"} = classify({:error, :timeout})
      assert %{plan: nil, basis: "no evidence (transport error)"} = classify({:error, %{}})
    end

    test "a template is recognized from the owner's input, never from the response" do
      assert %{plan: :template, basis: "marketplace template"} =
               classify(live(200), template?: true)
    end

    test "a template wins over dedicated and free hosting" do
      assert %{plan: :template} =
               classify(live(302, "https://d121.bubble.is/version-live"), template?: true)

      assert %{plan: :template} =
               classify(live(302, "https://bubble.io/live_not_supported?appname=myapp"),
                 template?: true,
                 exists: :yes
               )
    end

    test "a template on a dedicated instance is dedicated hosting" do
      assert %{
               plan: :template,
               basis: "marketplace template",
               dedicated_server: "d121",
               base_url: "https://d121.bubble.is"
             } = classify(live(302, "https://d121.bubble.is/version-live"), template?: true)
    end

    test "a template on bubble's own hosting reports no dedicated server" do
      assert %{plan: :template, dedicated_server: nil, base_url: nil} =
               classify(live(200), template?: true)
    end

    test "a missing app is never a template" do
      assert %{plan: :paid} = classify(live(200), template?: true, exists: :no)
      assert %{plan: nil} = classify(live(400), template?: true, exists: :no)
    end

    test "a bubble.io redirect that is not live_not_supported is no evidence" do
      assert %{plan: nil, basis: "no evidence (live 302 -> bubble.io)"} =
               classify(live(302, "https://bubble.io/version-test"))
    end

    test "a bubble host that is not a dedicated server is no evidence" do
      assert %{plan: nil, basis: "no evidence (live 302 -> myapp.bubbleapps.io)"} =
               classify(live(302, "https://myapp.bubbleapps.io/version-test"))
    end

    test "a redirect without a location is no evidence" do
      assert %{plan: nil, basis: "no evidence (live 302 without a location)"} =
               classify(live(302))
    end

    test "a 404 while the app exists is free, like live_not_supported" do
      assert %{plan: :free, basis: "live 404; version-test serves the app"} =
               classify(live(404), exists: :yes)
    end

    test "a 404 for a name that may not exist is no evidence" do
      assert %{plan: nil, basis: "live 404 not found"} = classify(live(404))
      assert %{plan: nil, basis: "live 404 not found"} = classify(live(404), exists: :no)
    end
  end

  describe "live_not_supported?/1" do
    test "reads Bubble's live_not_supported redirect" do
      assert Plan.live_not_supported?(live(302, "https://bubble.io/live_not_supported?appname=x"))
    end

    test "is false for a dedicated redirect, a live page and a transport error" do
      refute Plan.live_not_supported?(live(302, "https://d121.bubble.is/version-live"))
      refute Plan.live_not_supported?(live(200))
      refute Plan.live_not_supported?({:error, :timeout})
    end
  end
end
