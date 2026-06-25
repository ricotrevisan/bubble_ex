defmodule BubbleEx.Plugins do
  @moduledoc """
  Utilities to get information about a Bubble plugin.
  """

  require Logger
  alias BubbleEx.{Error, HTTP}

  @meta_url "https://bubble.io/api/1.1/init/data?location="
  @plugin_page_url "https://bubble.io/plugin/"
  @get_plugin_url "https://bubble.io/appeditor/get_plugin?id="
  @marketplace_url "https://bubble.io/apiservice/doapicallfromserver"

  # Marketplace plugin ids are long (`<timestamp>x<random>`); Bubble's own
  # first-party plugins use short slugs like "materialicons". A short id is the
  # signal that a plugin is official/first-party.
  @official_id_max_length 32

  @type plugin_type :: :bubble | :private | :open_source | :commercial

  @type attrs :: %{
          required(:bubble_id) => String.t(),
          required(:type) => plugin_type(),
          required(:public) => boolean(),
          optional(:name) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:price) => number() | nil,
          optional(:price_one_time) => number() | nil,
          optional(:payload) => map(),
          optional(:usage_count) => integer() | nil,
          optional(:url) => String.t(),
          optional(:code) => map() | nil
        }

  @doc """
  Fetches and parses a single plugin's marketplace metadata by its bubble id.
  """
  @spec fetch_plugin(String.t()) :: {:ok, attrs()} | {:error, Error.t()}
  def fetch_plugin(bubble_id) do
    case HTTP.fetch_json(assemble_url(bubble_id)) do
      {:ok, [parsed_body | _]} -> parse_response(parsed_body["data"], bubble_id)
      {:ok, []} -> parse_response([], bubble_id)
      {:ok, _other} -> parse_response([], bubble_id)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Fetches a plugin's source code payload. Returns `{:ok, nil}` when the code is
  not accessible (e.g. private plugins returning 401), rather than failing.
  """
  @spec fetch_plugin_code(String.t()) :: {:ok, map() | nil} | {:error, Error.t()}
  def fetch_plugin_code(id) do
    case HTTP.fetch_json(@get_plugin_url <> id) do
      {:ok, body} ->
        {:ok, body}

      {:error, %Error{kind: :unauthorized}} ->
        {:ok, nil}

      {:error, %Error{} = error} ->
        Logger.info("Could not fetch code for plugin #{id}: #{Exception.message(error)}")
        {:error, error}
    end
  end

  @doc """
  Fetches the public marketplace page data for a plugin.
  """
  @spec get_plugin_public_page(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_plugin_public_page(plugin_id) do
    encoded_url = URI.encode_www_form(@plugin_page_url <> plugin_id)
    HTTP.fetch_json(@meta_url <> encoded_url)
  end

  @doc """
  Fetches the list of integrated plugins from the Bubble marketplace.
  """
  @spec fetch_list_from_marketplace() :: {:ok, map()} | {:error, Error.t()}
  def fetch_list_from_marketplace do
    body =
      Jason.encode!(%{
        "properties" => %{"provider" => "bubble_plugins.get_integrated_plugins"},
        "serialized_context" => %{"skip_property_security" => true},
        "call_name" => "get_integrated_plugins",
        "service_name" => "bubble_plugins"
      })

    HTTP.post_json(@marketplace_url, body, [{"Content-Type", "application/json"}])
  end

  @doc false
  @spec assemble_url(String.t()) :: String.t()
  def assemble_url(bubble_id) do
    @meta_url <> URI.encode_www_form(@plugin_page_url <> bubble_id)
  end

  # ── Response parsing ───────────────────────────────────────────────────────

  defp parse_response([], bubble_id) do
    # Empty payload: either a first-party/official plugin or a private one.
    attrs =
      if official_plugin?(bubble_id) do
        %{bubble_id: bubble_id, type: :bubble, public: true}
      else
        %{bubble_id: bubble_id, type: :private, public: false}
      end

    {:ok, attrs}
  end

  defp parse_response(%{"marketplace_eligible__boolean" => false} = payload, bubble_id) do
    {:ok, %{bubble_id: bubble_id, type: :private, public: false, payload: payload}}
  end

  defp parse_response(payload, bubble_id) do
    code =
      case fetch_plugin_code(bubble_id) do
        {:ok, code} -> code
        {:error, _} -> nil
      end

    attrs = %{
      bubble_id: bubble_id,
      name: Map.get(payload, "name_text"),
      description: Map.get(payload, "description_text"),
      price: Map.get(payload, "price_number"),
      price_one_time: Map.get(payload, "one_time_price_number"),
      payload: payload,
      usage_count: Map.get(payload, "usage_count_number"),
      type: licence_type(payload),
      public: true,
      url: @plugin_page_url <> bubble_id,
      code: code
    }

    {:ok, attrs}
  end

  defp licence_type(payload) do
    case Map.get(payload, "licence_text") do
      "open_source" -> :open_source
      "commercial" -> :commercial
      _ -> nil
    end
  end

  defp official_plugin?(bubble_id), do: String.length(bubble_id) < @official_id_max_length
end
