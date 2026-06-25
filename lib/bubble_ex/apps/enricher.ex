defmodule BubbleEx.Apps.Enricher do
  @moduledoc """
  Enricher module for adding additional data and processing to Bubble app attributes.

  This module handles enriching basic app data with additional information like
  database diagrams, plugin counts, metadata, and other derived attributes.
  """

  require Logger
  alias BubbleEx.Apps.Parser
  alias BubbleEx.Db.{Dbml, Encoder, Reader}
  alias BubbleEx.HTTP

  @doc """
  Adds database schema output to app attributes if requested.

  Renders DBML into `:dbml`/`:dbdiagram` when the legacy `:dbml` /
  `:include_db_diagram` options are set, and/or renders the `:format` target
  (e.g. `:postgres`) into `:schema`. The payload is parsed once and shared.
  """
  @spec maybe_add_db_diagram(map(), map(), keyword()) :: map()
  def maybe_add_db_diagram(attrs, app_data, opts) do
    legacy? = Keyword.get(opts, :include_db_diagram, false) or Keyword.get(opts, :dbml, false)
    format = Keyword.get(opts, :format)

    if legacy? or format do
      add_schemas(attrs, app_data, opts, legacy?, format)
    else
      attrs
    end
  end

  @doc """
  Adds payload to app attributes if requested.
  """
  @spec maybe_add_payload(map(), map(), keyword()) :: map()
  def maybe_add_payload(attrs, app_data, opts) do
    include_payload? = Keyword.get(opts, :include_payload, false)

    if include_payload? do
      Map.put(attrs, :payload, app_data)
    else
      attrs
    end
  end

  @doc """
  Adds description from Facebook meta tags if available.
  """
  @spec maybe_add_description(map(), map()) :: map()
  def maybe_add_description(attrs, app_data) do
    case Parser.extract_description(app_data) do
      nil -> attrs
      description -> Map.put(attrs, :description, description)
    end
  end

  @doc """
  Adds plugin count to app attributes.
  """
  @spec add_plugin_count(map(), map()) :: map()
  def add_plugin_count(attrs, app_data) do
    plugin_count = Parser.count_plugins(app_data)
    Map.put(attrs, :plugin_count, plugin_count)
  end

  @doc """
  Enriches meta endpoint response with additional data.
  """
  @spec enrich_meta_response(map()) :: map()
  def enrich_meta_response(response) do
    %{
      obj: enrich_obj_endpoints(response),
      wf: enrich_wf_endpoints(response),
      app_data: response["app_data"]
    }
  end

  @doc """
  Enriches object endpoints with sample data.
  """
  @spec enrich_obj_endpoints(map()) :: [map()]
  def enrich_obj_endpoints(response) do
    case Map.get(response, "get") do
      [] ->
        []

      endpoints ->
        bubble_id = get_in(response, ["app_data", "appname"])
        Enum.flat_map(endpoints, &enrich_obj_endpoint(&1, bubble_id))
    end
  end

  defp enrich_obj_endpoint(endpoint, bubble_id) do
    case HTTP.fetch_json(build_obj_url(bubble_id, endpoint, 5)) do
      {:ok, obj_response} ->
        # HTTP.fetch_json/2 already unwraps the Bubble "response" envelope, so
        # count/remaining/results sit at the top level of obj_response.
        count = Map.get(obj_response, "count", 0)
        remaining = Map.get(obj_response, "remaining", 0)

        [
          %{
            "endpoint" => endpoint,
            "total" => count + remaining,
            "sample_items" => Map.get(obj_response, "results")
          }
        ]

      {:error, reason} ->
        Logger.warning("Failed to fetch obj endpoint #{endpoint}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Enriches workflow endpoints by categorizing them.
  """
  @spec enrich_wf_endpoints(map()) :: map()
  def enrich_wf_endpoints(response) do
    case Map.get(response, "post") do
      nil ->
        %{public: %{get: [], post: [], count: 0}, auth: []}

      endpoints ->
        # NOTE: "auth_unecessary" is Bubble's own (misspelled) field name — keep it.
        # We prepend during the reduce (O(1)) and reverse once at the end to
        # preserve input order without the quadratic `acc ++ [x]` pattern.
        endpoints
        |> Enum.reduce(%{public: %{get: [], post: [], count: 0}, auth: []}, fn
          %{"auth_unecessary" => true, "method" => "get"} = endpoint, acc ->
            acc
            |> update_in([:public, :get], &[endpoint | &1])
            |> update_in([:public, :count], &(&1 + 1))

          %{"auth_unecessary" => true, "method" => "post"} = endpoint, acc ->
            acc
            |> update_in([:public, :post], &[endpoint | &1])
            |> update_in([:public, :count], &(&1 + 1))

          endpoint, acc ->
            update_in(acc, [:auth], &[endpoint | &1])
        end)
        |> update_in([:public, :get], &Enum.reverse/1)
        |> update_in([:public, :post], &Enum.reverse/1)
        |> update_in([:auth], &Enum.reverse/1)
    end
  end

  @doc """
  Adds workflow sample data for public GET endpoints.
  """
  @spec add_workflow_samples(map(), String.t()) :: map()
  def add_workflow_samples(enriched_wf, bubble_id) do
    public_get_endpoints = get_in(enriched_wf, [:public, :get]) || []

    updated_get_endpoints =
      Enum.map(public_get_endpoints, fn endpoint ->
        workflow_name = endpoint["name"]

        case HTTP.fetch_json(build_wf_url(bubble_id, workflow_name)) do
          {:ok, wf_response} ->
            Map.put(endpoint, "sample_response", wf_response)

          {:error, reason} ->
            Logger.warning(
              "Failed to fetch workflow sample for #{workflow_name}: #{inspect(reason)}"
            )

            Map.put(endpoint, "sample_error", inspect(reason))
        end
      end)

    put_in(enriched_wf, [:public, :get], updated_get_endpoints)
  end

  # Private functions

  defp add_schemas(attrs, app_data, opts, legacy?, format) do
    case Reader.parse(app_data) do
      {:ok, parsed_map} ->
        attrs
        |> maybe_put_dbml(parsed_map, opts, legacy?)
        |> maybe_put_schema(parsed_map, opts, format)

      error ->
        message = "Error parsing database diagram: #{inspect(error)}"
        Logger.warning(message)
        # Preserve the legacy contract: parse failures surface as the message in
        # the DBML keys. :schema is simply left unset on error.
        if legacy?,
          do: attrs |> Map.put(:dbdiagram, message) |> Map.put(:dbml, message),
          else: attrs
    end
  end

  defp maybe_put_dbml(attrs, _parsed_map, _opts, false), do: attrs

  defp maybe_put_dbml(attrs, parsed_map, opts, true) do
    naming = Keyword.get(opts, :naming, :proper)
    dbml_opts = [dbml: Keyword.get(opts, :dbml, false), naming: naming]

    content =
      case Dbml.encode(parsed_map, dbml_opts) do
        {:ok, dbml} ->
          dbml

        error ->
          message = "Error generating DBML: #{inspect(error)}"
          Logger.warning(message)
          message
      end

    attrs
    |> Map.put(:dbdiagram, content)
    |> Map.put(:dbml, content)
  end

  defp maybe_put_schema(attrs, _parsed_map, _opts, nil), do: attrs

  defp maybe_put_schema(attrs, parsed_map, opts, format) do
    naming = Keyword.get(opts, :naming, :proper)

    with {:ok, module} <- Encoder.module_for(format),
         {:ok, schema} <- module.encode(parsed_map, naming: naming) do
      Map.put(attrs, :schema, schema)
    else
      {:error, error} ->
        Logger.warning("Could not render #{inspect(format)} schema: #{inspect(error)}")
        attrs
    end
  end

  defp build_obj_url(bubble_id, obj, limit) when is_integer(limit) do
    "http://#{bubble_id}.bubbleapps.io/api/1.1/obj/#{obj}?limit=#{limit}"
  end

  defp build_wf_url(bubble_id, workflow) do
    "http://#{bubble_id}.bubbleapps.io/api/1.1/wf/#{workflow}"
  end
end
