defmodule BubbleEx.Apps do
  @moduledoc """
  Main interface for interacting with Bubble.io applications.

  This module provides high-level functions for checking, fetching, and analyzing
  Bubble applications. It delegates to specialized modules for specific concerns.
  """

  require Logger

  alias BubbleEx.Apps.{Enricher, Parser, Validator}
  alias BubbleEx.{Error, HTTP, Telemetry}

  # Types
  @type fetch_option ::
          {:include_payload, boolean()}
          | {:include_db_diagram, boolean()}
          | {:try_test, boolean()}
          | {:username, String.t()}
          | {:password, String.t()}
          | {:naming, :proper | :id}
          | {:dbml, boolean()}
          | {:format, atom()}
          | {:external_types, :preserve | :opaque | :legacy}
          | {:external_type_capabilities, %{optional(atom()) => [atom()]}}
          | {:max_retries, non_neg_integer()}
          | {:retry_base_delay, pos_integer()}

  @type app_plan :: :free | :paid | :agency | :template | nil

  @type app_attrs :: %{
          optional(:schema_warnings) => [map()],
          optional(:dbml_warnings) => [map()],
          app_plan: app_plan(),
          bubble_id: String.t(),
          url: String.t() | nil,
          title: String.t() | nil,
          plugin_count: non_neg_integer() | nil,
          description: String.t() | nil,
          payload: map() | nil,
          dbdiagram: String.t() | nil,
          notes: String.t() | nil,
          valid?: boolean(),
          dbml: String.t() | nil,
          schema: String.t() | nil
        }

  @type check_result :: %{
          valid: boolean(),
          bubble_id: String.t() | nil,
          url: String.t() | nil,
          domain: String.t() | nil,
          payload: map() | nil
        }

  @doc """
  Checks if a Bubble app exists and is accessible.

  ## Examples

      BubbleEx.Apps.check("meta")
      #=> %{valid: true, bubble_id: "meta", url: "https://bubble.io"}

      BubbleEx.Apps.check("https://theverge.com")
      #=> %{valid: false, bubble_id: nil, url: "https://theverge.com"}
  """
  @spec check(String.t()) :: check_result()
  def check(url_or_bubble_id) do
    with {:ok, url} <- Validator.validate_input(url_or_bubble_id),
         {:ok, payload} <- HTTP.fetch_page(url) do
      %{
        valid: true,
        bubble_id: payload.bubble_id,
        url: payload.url,
        domain: payload.domain,
        payload: payload
      }
    else
      {:error, %Error{context: %{url: request_url}}} ->
        %{valid: false, bubble_id: nil, url: request_url}

      {:error, _reason} ->
        %{valid: false, bubble_id: nil, url: nil}
    end
  end

  @doc """
  Checks what versions are available for a Bubble app.

  Returns a list of available versions (e.g., ["live", "test"]).
  """
  @spec check_versions(String.t(), String.t() | nil, String.t() | nil) :: [String.t()]
  def check_versions(bubble_id, username \\ nil, password \\ nil)

  def check_versions(bubble_id, nil, nil) do
    check_public_versions(bubble_id)
  end

  def check_versions(bubble_id, username, password) do
    authenticated_versions = check_authenticated_versions(bubble_id, username, password)
    public_versions = check_public_versions(bubble_id)

    (authenticated_versions ++ public_versions) |> Enum.uniq()
  end

  @doc """
  Determines if an app is hosted on a dedicated Bubble instance.

  ## Examples

      BubbleEx.Apps.dedicated?("some_id")
      #=> {:ok, %{base_url: ..., instance: "d111", url: ..., is_dedicated: true}}
  """
  @spec dedicated?(String.t(), String.t()) ::
          {:ok, map()} | {:error, BubbleEx.Error.t()}
  def dedicated?(bubble_id, version \\ "live") do
    with :ok <- Validator.validate_bubble_id(bubble_id),
         {:ok, redirect_info} <- HTTP.check_redirect(bubble_id, version) do
      process_redirect_result(redirect_info, bubble_id, version)
    end
  end

  @doc """
  Fetches comprehensive information about a Bubble application.

  ## Options
    * `:include_payload` - Include full app payload. Defaults to `false`.
    * `:include_db_diagram` - Include database diagram. Defaults to `false`.
    * `:try_test` - Try test version if live fails. Defaults to `true`.
    * `:username` - Username for authentication.
    * `:password` - Password for authentication.
    * `:dbml` - Generate DBML output. Defaults to `false`.
    * `:format` - Schema format to render; output lands in the `:schema` key. Defaults to none.
      One of `:dbml`, `:postgres`, `:sqlite`, `:tsql`, `:ecto`, `:zod`, `:xano`, `:convex`.
    * `:naming` - Naming strategy (`:proper` or `:id`).
  """
  @spec fetch_app(String.t(), [fetch_option()]) ::
          {:ok, app_attrs()} | {:error, term()}
  def fetch_app(url_or_bubble_id, opts \\ []) do
    Telemetry.span([:apps, :fetch_app], %{input: url_or_bubble_id}, fn ->
      result =
        with {:ok, url} <- Validator.validate_input(url_or_bubble_id) do
          fetch_app_url(url_or_bubble_id, url, opts)
        end

      {result, fetch_app_stop_metadata(result)}
    end)
  end

  defp fetch_app_stop_metadata({:ok, attrs}),
    do: %{bubble_id: Map.get(attrs, :bubble_id), valid?: Map.get(attrs, :valid?), error: nil}

  defp fetch_app_stop_metadata({:error, error}),
    do: %{bubble_id: nil, valid?: false, error: error}

  defp fetch_app_url(url_or_bubble_id, url, opts) do
    case fetch_app_from_url(url, opts) do
      {:ok, attrs} ->
        {:ok, attrs}

      {:error, %Error{context: %{status: status_code} = ctx}}
      when status_code in [400, 404] ->
        maybe_try_test_version(url_or_bubble_id, url, Map.get(ctx, :url), status_code, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_app_from_url(url, opts) do
    with {:ok, initial_payload} <- HTTP.fetch_page(url, opts),
         {:ok, dynamic_js_url} <- Parser.extract_dynamic_js_url(initial_payload),
         {:ok, app_payload} <- HTTP.fetch_page(dynamic_js_url, opts),
         {:ok, app_data} <- Parser.parse_app_json(app_payload.body) do
      attrs = build_app_attrs(app_data, initial_payload, url, opts)
      {:ok, attrs}
    end
  end

  defp maybe_try_test_version(url_or_bubble_id, url, request_url, status_code, opts) do
    if Keyword.get(opts, :try_test, true) && !String.contains?(url, "version-test") do
      test_url = build_test_version_url(url_or_bubble_id, url)

      case fetch_app_from_url(test_url, opts) do
        {:ok, attrs} ->
          {:ok, attrs}

        {:error, %Error{context: %{status: test_status_code} = ctx}}
        when test_status_code in [400, 404] ->
          {:ok,
           build_invalid_app_attrs(Map.get(ctx, :url) || request_url || url, test_status_code)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, build_invalid_app_attrs(request_url || url, status_code)}
    end
  end

  @doc """
  Fetches metadata endpoint information for an app.
  """
  @spec fetch_meta_endpoint(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_meta_endpoint(bubble_id) do
    url = build_api_url(bubble_id, "meta")
    HTTP.fetch_json(url)
  end

  @doc """
  Fetches object endpoint data for an app.
  """
  @spec fetch_obj_endpoint(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_obj_endpoint(bubble_id, obj, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    url = build_obj_url(bubble_id, obj, limit)

    Logger.info("Fetching obj endpoint: #{obj}")
    HTTP.fetch_json(url)
  end

  @doc """
  Executes a workflow endpoint for an app.

  ## Examples

      fetch_wf_endpoint("byword", "shopify_storeerasure")
      #=> {:ok, %{"status" => "success", "response" => %{"message" => "store_data_deleted"}}}
  """
  @spec fetch_wf_endpoint(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def fetch_wf_endpoint(bubble_id, workflow) do
    url = build_api_url(bubble_id, "wf/#{workflow}")

    Logger.info("Fetching workflow endpoint: #{bubble_id}/#{workflow}")
    HTTP.fetch_json(url)
  end

  @doc """
  Enriches meta endpoint response with additional data.
  """
  @spec enrich_meta_response(map()) :: map()
  def enrich_meta_response(response) do
    Enricher.enrich_meta_response(response)
  end

  # Private functions

  defp check_public_versions(bubble_id) do
    base_url = "https://#{bubble_id}.bubbleapps.io/"

    versions =
      case check(base_url) do
        %{valid: true} -> ["live"]
        _ -> []
      end

    case check(base_url <> "version-test") do
      %{valid: true} -> versions ++ ["test"]
      _ -> versions
    end
    |> Enum.uniq()
  end

  defp check_authenticated_versions(bubble_id, username, password) do
    base_url = "https://#{username}:#{password}@#{bubble_id}.bubbleapps.io/"

    versions =
      case check(base_url) do
        %{valid: true} -> ["live"]
        _ -> []
      end

    case check(base_url <> "version-test") do
      %{valid: true} -> versions ++ ["test"]
      _ -> versions
    end
  end

  defp process_redirect_result(%{is_redirect: false}, bubble_id, version) do
    base_url = "https://#{bubble_id}.bubbleapps.io"
    url = "#{base_url}/version-#{version}/"

    {:ok,
     %{
       is_dedicated: false,
       base_url: base_url,
       url: url,
       instance: nil
     }}
  end

  defp process_redirect_result(%{is_redirect: true, location: location}, bubble_id, version) do
    location = if is_list(location), do: List.first(location), else: location

    if String.contains?(location, "bubble.is") do
      base_url = location |> String.split("/version-#{version}") |> List.first()
      instance = extract_instance_from_url(base_url)

      {:ok,
       %{
         is_dedicated: true,
         base_url: base_url,
         url: location,
         instance: instance
       }}
    else
      # Handle case where redirect doesn't go to bubble.is (not dedicated)
      base_url = "https://#{bubble_id}.bubbleapps.io"
      url = "#{base_url}/version-#{version}/"

      {:ok,
       %{
         is_dedicated: false,
         base_url: base_url,
         url: url,
         instance: nil
       }}
    end
  end

  defp extract_instance_from_url(base_url) do
    base_url
    |> String.split("https://")
    |> List.last()
    |> String.split(".")
    |> List.first()
  end

  defp build_app_attrs(app_data, initial_payload, url, opts) do
    username = Keyword.get(opts, :username)

    %{
      app_plan: determine_app_plan(url, username),
      bubble_id: app_data["_id"],
      url: initial_payload.domain,
      title: Parser.extract_title(app_data),
      valid?: true
    }
    |> Enricher.maybe_add_db_diagram(app_data, opts)
    |> Enricher.maybe_add_payload(app_data, opts)
    |> Enricher.maybe_add_description(app_data)
    |> Enricher.add_plugin_count(app_data)
  end

  defp build_invalid_app_attrs(url, status_code) do
    bubble_id = Parser.extract_bubble_id_from_url(url)
    message = "Got a #{status_code}, not a valid app."

    %{
      bubble_id: bubble_id,
      notes: message,
      valid?: false
    }
  end

  defp determine_app_plan(url, username) do
    is_live = not String.contains?(url, "version-test")

    case {is_live, username} do
      {true, nil} -> :paid
      {true, _username} -> :agency
      {false, nil} -> :free
      {false, _username} -> :agency
    end
  end

  defp build_api_url(bubble_id, endpoint) do
    "http://#{bubble_id}.bubbleapps.io/api/1.1/#{endpoint}"
  end

  defp build_test_version_url(url_or_bubble_id, _url) do
    if Validator.valid_slug?(url_or_bubble_id) do
      "https://#{url_or_bubble_id}.bubbleapps.io/version-test"
    else
      url_or_bubble_id
      |> String.trim_trailing("/")
      |> Kernel.<>("/version-test")
    end
  end

  defp build_obj_url(bubble_id, obj, nil) do
    build_api_url(bubble_id, "obj/#{obj}")
  end

  defp build_obj_url(bubble_id, obj, limit) do
    build_api_url(bubble_id, "obj/#{obj}?limit=#{limit}")
  end
end
