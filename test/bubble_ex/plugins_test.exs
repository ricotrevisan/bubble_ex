defmodule BubbleEx.PluginsTest do
  use ExUnit.Case, async: false

  alias BubbleEx.HTTP
  alias BubbleEx.Plugins
  alias Plug.Conn

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  # Stubs the two endpoints fetch_plugin may hit: the marketplace meta endpoint
  # and (for marketplace-eligible plugins) the get_plugin code endpoint.
  defp stub(meta_body, code_body \\ %{"code" => "x"}) do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        if String.contains?(conn.request_path, "get_plugin"),
          do: code_body,
          else: meta_body

      conn
      |> Conn.put_resp_header("content-type", "application/json")
      |> Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp meta(data), do: [%{"data" => data}]

  test "fetches a commercial (paid) plugin" do
    stub(
      meta(%{
        "marketplace_eligible__boolean" => true,
        "name_text" => "Utilities ( bdk )",
        "description_text" => "Helpful utilities",
        "price_number" => 10,
        "one_time_price_number" => 99,
        "usage_count_number" => 500,
        "licence_text" => "commercial"
      })
    )

    assert {:ok, plugin} = Plugins.fetch_plugin("1544798294930x973076470769909800")
    assert plugin.name == "Utilities ( bdk )"
    assert plugin.public == true
    assert plugin.description != nil
    assert plugin.url == "https://bubble.io/plugin/1544798294930x973076470769909800"
    assert plugin.payload["marketplace_eligible__boolean"] == true
    assert plugin.price == 10
    assert plugin.price_one_time == 99
    assert plugin.usage_count == 500
    assert plugin.type == :commercial
  end

  test "fetches an open-source (free) plugin" do
    stub(
      meta(%{
        "marketplace_eligible__boolean" => true,
        "name_text" => "Toolbox",
        "description_text" => "Free toolbox",
        "usage_count_number" => 1000,
        "licence_text" => "open_source"
      })
    )

    assert {:ok, plugin} = Plugins.fetch_plugin("1488796042609x768734193128308700")
    assert plugin.name == "Toolbox"
    assert plugin.price == nil
    assert plugin.price_one_time == nil
    assert plugin.type == :open_source
  end

  test "fetches a private plugin (marketplace ineligible)" do
    stub(meta(%{"marketplace_eligible__boolean" => false}))

    assert {:ok, plugin} = Plugins.fetch_plugin("1549963928625x139330735232516100")
    assert plugin.payload["marketplace_eligible__boolean"] == false
    assert plugin.type == :private
    assert plugin.public == false
    refute Map.has_key?(plugin, :name)
    refute Map.has_key?(plugin, :url)
  end

  test "classifies a short-id first-party plugin from an empty payload" do
    stub([])

    assert {:ok, plugin} = Plugins.fetch_plugin("materialicons")
    assert plugin.type == :bubble
    assert plugin.public == true
    refute Map.has_key?(plugin, :payload)
  end

  test "returns a BubbleEx.Error on an HTTP failure" do
    Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 500, "boom") end)

    assert {:error, %BubbleEx.Error{kind: :http_error}} = Plugins.fetch_plugin("anything")
  end
end
