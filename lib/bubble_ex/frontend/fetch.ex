defmodule BubbleEx.Frontend.Fetch do
  @moduledoc false

  alias BubbleEx.Apps.Parser
  alias BubbleEx.{Config, Error, HTTP}
  alias BubbleEx.Frontend.{Auth, Naming, Payload, SafeUrl}
  alias BubbleEx.Frontend.Export.Fonts

  @default_max_page_fetches 20
  @max_redirects 5

  defmodule Context do
    @moduledoc false
    @enforce_keys [:page_url, :auth]
    defstruct [:page_url, :auth, font_sources: []]

    @type t :: %__MODULE__{
            page_url: String.t(),
            auth: BubbleEx.Frontend.Auth.t(),
            font_sources: [String.t()]
          }
  end

  @spec run(String.t(), Auth.t(), keyword()) ::
          {:ok, map(), Context.t()} | {:error, Error.t()}
  def run(url, %Auth{} = auth, opts \\ []) do
    with {:ok, page_url, scoped_auth} <- resolve_dedicated(url, auth, opts),
         {:ok, payload, effective_page_url, font_sources} <-
           fetch_page_payload(
             page_url,
             scoped_auth,
             auth_state(scoped_auth, page_url),
             opts
           ),
         {:ok, effective_auth} <- Auth.rescope(scoped_auth, effective_page_url) do
      {:ok, payload,
       %Context{page_url: effective_page_url, auth: effective_auth, font_sources: font_sources}}
    end
  end

  @spec hydrate_selected_pages(map(), Context.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def hydrate_selected_pages(payload, %Context{} = context, opts \\ []) when is_map(payload) do
    with {:ok, max_page_fetches} <- max_page_fetches(opts),
         {:ok, jobs, unhydrated_names} <- hydration_jobs(payload, context, opts),
         :ok <- within_page_fetch_bound(jobs, unhydrated_names, max_page_fetches, context.auth) do
      fetch_hydration_jobs(payload, jobs, context, opts)
    end
  end

  defp fetch_page_payload(page_url, auth, page_state, opts) do
    with {:ok, page} <- fetch_bubble_page(page_url, auth, page_state, opts),
         {:ok, dynamic_url} <- dynamic_url(page, auth),
         {:ok, dynamic} <-
           fetch_bubble_page(dynamic_url, auth, auth_state(auth, dynamic_url), opts),
         {:ok, payload} <- parse_payload(dynamic.body) do
      {:ok, payload, page.url, Fonts.discover(page.body, page.url)}
    end
  end

  defp max_page_fetches(opts) do
    case Keyword.get(opts, :max_page_fetches, @default_max_page_fetches) do
      max when is_integer(max) and max >= 0 ->
        {:ok, max}

      _max ->
        {:error,
         Error.new(:invalid_input, "max_page_fetches must be a non-negative integer", %{})}
    end
  end

  defp hydration_jobs(payload, context, opts) do
    selected = Keyword.get(opts, :pages, :all)
    pages = Payload.pages(payload)

    with :ok <- validate_selected_pages(pages, selected) do
      pages
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.filter(fn {key, page} ->
        is_map(page) and selected_page?(key, page, selected) and
          Payload.unhydrated_page?(page)
      end)
      |> build_hydration_jobs(context)
    end
  end

  defp validate_selected_pages(_pages, :all), do: :ok

  defp validate_selected_pages(_pages, []) do
    {:error, Error.new(:invalid_input, "pages filter must not be empty", %{})}
  end

  defp validate_selected_pages(pages, refs) when is_list(refs) do
    if Enum.all?(refs, &known_page_ref?(pages, &1)) do
      :ok
    else
      {:error, Error.new(:invalid_input, "unknown page ref", %{})}
    end
  end

  defp validate_selected_pages(_pages, _selected) do
    {:error, Error.new(:invalid_input, "pages must be :all or a list of page refs", %{})}
  end

  defp known_page_ref?(pages, ref) do
    Enum.any?(pages, fn
      {key, page} when is_map(page) -> ref in page_refs(key, page)
      _ -> false
    end)
  end

  defp build_hydration_jobs(candidates, context) do
    candidates
    |> Enum.reduce_while({:ok, []}, fn {key, page}, {:ok, targets} ->
      name = Payload.page_path(page)

      case page_url(context.page_url, name, context.auth) do
        {:ok, url} ->
          target = %{key: key, name: name, url: url, normalized_url: SafeUrl.normalize(url)}
          {:cont, {:ok, [target | targets]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> finish_hydration_jobs()
  end

  defp finish_hydration_jobs({:ok, targets}) do
    targets = Enum.reverse(targets)
    {:ok, group_hydration_jobs(targets), Enum.map(targets, & &1.name) |> Enum.uniq()}
  end

  defp finish_hydration_jobs({:error, _} = error), do: error

  defp group_hydration_jobs(targets) do
    {order, grouped} =
      Enum.reduce(targets, {[], %{}}, fn target, {order, grouped} ->
        normalized = target.normalized_url

        case Map.fetch(grouped, normalized) do
          :error ->
            job = %{url: target.url, normalized_url: normalized, targets: [target]}
            {order ++ [normalized], Map.put(grouped, normalized, job)}

          {:ok, job} ->
            updated = %{job | targets: job.targets ++ [target]}
            {order, Map.put(grouped, normalized, updated)}
        end
      end)

    Enum.map(order, &Map.fetch!(grouped, &1))
  end

  defp selected_page?(_key, _page, :all), do: true

  defp selected_page?(key, page, refs) when is_list(refs) do
    Enum.any?(page_refs(key, page), &(&1 in refs))
  end

  defp selected_page?(_key, _page, _selected), do: false

  defp page_refs(key, page) do
    path = Payload.page_path(page)
    normalized_name = Payload.name(page)
    bubble_id = Payload.bubble_id(page)

    [
      key,
      path,
      normalized_name,
      Naming.slug(path),
      Naming.slug(normalized_name),
      Naming.slug(key),
      bubble_id
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp page_url(base_url, name, auth) when is_binary(name) do
    with :ok <- validate_page_path(name, auth) do
      build_page_url(base_url, name, auth)
    end
  end

  defp validate_page_path(name, auth) do
    cond do
      credential_tainted?(name, auth) ->
        {:error,
         Error.new(:export_blocked, "page hydration blocked by credential-tainted path", %{})}

      valid_page_path?(name) ->
        :ok

      true ->
        {:error, Error.new(:invalid_input, "Bubble page path is invalid", %{})}
    end
  end

  defp credential_tainted?(value, auth) do
    Enum.any?(Auth.taints(auth), fn
      taint when is_binary(taint) and taint != "" -> String.contains?(value, taint)
      _ -> false
    end)
  end

  defp build_page_url(base_url, name, auth) do
    uri = URI.parse(base_url)
    prefix = version_prefix(uri.path)
    encoded_name = URI.encode(name, &URI.char_unreserved?/1)

    url =
      %{uri | path: prefix <> "/" <> encoded_name, query: nil, fragment: nil, userinfo: nil}
      |> URI.to_string()

    if SafeUrl.https?(url) and Auth.scoped_to?(auth, url) do
      {:ok, url}
    else
      {:error,
       Error.new(:request_failed, "frontend page hydration URL left the app origin", %{
         url: safe(url, auth)
       })}
    end
  rescue
    _ -> {:error, Error.new(:invalid_input, "Bubble page path is invalid", %{})}
  end

  defp valid_page_path?(name) do
    name not in [".", ".."] and not String.contains?(name, ["/", "\\", "?", "#"]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, name)
  end

  defp version_prefix(path) when is_binary(path) do
    case Regex.run(~r{^/(version-[A-Za-z0-9_-]+)(?:/|$)}, path, capture: :all_but_first) do
      [prefix] -> "/" <> prefix
      _ -> ""
    end
  end

  defp version_prefix(_path), do: ""

  defp within_page_fetch_bound(jobs, names, max, auth) do
    if length(jobs) <= max do
      :ok
    else
      {:error,
       Error.new(
         :invalid_input,
         "requested page hydration exceeds max_page_fetches",
         %{
           max_page_fetches: max,
           page_fetches: length(jobs),
           unhydrated_pages: redact_names(names, auth)
         }
       )}
    end
  end

  defp redact_names(names, auth) do
    taints = Auth.taints(auth)

    Enum.map(names, fn name ->
      Enum.reduce(taints, name, fn
        taint, acc when is_binary(taint) and taint != "" ->
          String.replace(acc, taint, "[REDACTED]")

        _taint, acc ->
          acc
      end)
    end)
  end

  defp fetch_hydration_jobs(payload, jobs, context, opts) do
    Enum.reduce_while(jobs, {:ok, payload}, fn job, {:ok, merged} ->
      fetch_hydration_job(job, merged, context, opts)
    end)
  end

  defp fetch_hydration_job(job, merged, context, opts) do
    if Enum.all?(job.targets, &hydrated_page?(merged, &1.key)) do
      {:cont, {:ok, merged}}
    else
      do_fetch_hydration_job(job, merged, context, opts)
    end
  end

  defp do_fetch_hydration_job(job, merged, context, opts) do
    case fetch_page_payload(job.url, context.auth, :scoped, opts) do
      {:ok, fetched, _effective_page_url, _font_sources} ->
        hydrated =
          merged
          |> merge_reusable_definitions(fetched)
          |> merge_styles(fetched)
          |> merge_job_targets(fetched, job.targets)

        {:cont, {:ok, hydrated}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp merge_reusable_definitions(payload, fetched) do
    fetched_definitions = reusable_definitions(fetched)

    if map_size(fetched_definitions) == 0 do
      payload
    else
      key = reusable_definitions_key(payload, fetched)
      Map.put(payload, key, Map.merge(reusable_definitions(payload), fetched_definitions))
    end
  end

  defp merge_styles(payload, fetched) do
    fetched_styles = Payload.styles(fetched)

    if map_size(fetched_styles) == 0 do
      payload
    else
      key = if is_map(payload["%s"]), do: "%s", else: "styles"
      Map.put(payload, key, Map.merge(Payload.styles(payload), fetched_styles))
    end
  end

  # A decoded payload should normally use only one of these keys. Combining both
  # keeps every definition if a bundle contains a mixed readable/aliased shape.
  # Page bundles are merged in hydration-job order, so the current bundle wins
  # duplicate keys deterministically.
  defp reusable_definitions(payload) do
    aliased = if is_map(payload["%ed"]), do: payload["%ed"], else: %{}

    readable =
      if is_map(payload["element_definitions"]), do: payload["element_definitions"], else: %{}

    Map.merge(aliased, readable)
  end

  defp reusable_definitions_key(payload, fetched) do
    cond do
      is_map(payload["element_definitions"]) -> "element_definitions"
      is_map(payload["%ed"]) -> "%ed"
      is_map(fetched["element_definitions"]) -> "element_definitions"
      true -> "%ed"
    end
  end

  defp merge_job_targets(payload, fetched, targets) do
    Enum.reduce(targets, payload, fn target, acc ->
      merge_page_payload(acc, fetched, target.key)
    end)
  end

  defp hydrated_page?(payload, key) do
    case Map.get(Payload.pages(payload), key) do
      page when is_map(page) -> Payload.hydrated_page?(page)
      _ -> false
    end
  end

  defp merge_page_payload(payload, fetched, key) do
    fetched_page = Map.get(Payload.pages(fetched), key)

    payload
    |> merge_page(key, fetched_page)
    |> merge_id_to_path(fetched)
  end

  defp merge_page(payload, _key, fetched_page) when not is_map(fetched_page), do: payload

  defp merge_page(payload, key, fetched_page) do
    cond do
      is_map(payload["%p3"]) ->
        update_in(payload, ["%p3", key], fn
          existing when is_map(existing) -> Map.merge(existing, fetched_page)
          _ -> fetched_page
        end)

      is_map(payload["pages"]) ->
        update_in(payload, ["pages", key], fn
          existing when is_map(existing) -> Map.merge(existing, fetched_page)
          _ -> fetched_page
        end)

      true ->
        payload
    end
  end

  defp merge_id_to_path(payload, fetched) do
    case get_in(fetched, ["_index", "id_to_path"]) do
      fetched_paths when is_map(fetched_paths) ->
        update_in(payload, [Access.key("_index", %{}), Access.key("id_to_path", %{})], fn
          existing when is_map(existing) -> Map.merge(existing, fetched_paths)
          _ -> fetched_paths
        end)

      _ ->
        payload
    end
  end

  defp resolve_dedicated(url, auth, opts) do
    if Auth.enabled?(auth) and SafeUrl.bubbleapps_host?(url) do
      case request_once(url, [], opts, Auth.taints(auth)) do
        {:ok, %{status_code: status, headers: headers}} when status in 300..399 ->
          resolve_dedicated_redirect(url, headers, auth)

        _ ->
          {:ok, url, auth}
      end
    else
      {:ok, url, auth}
    end
  end

  defp resolve_dedicated_redirect(url, headers, auth) do
    with {:ok, location} <- redirect_location(url, headers, auth),
         true <- SafeUrl.https?(location) and SafeUrl.dedicated_host?(location),
         {:ok, scoped} <- Auth.rescope(auth, location) do
      {:ok, location, scoped}
    else
      _ -> {:error, unsafe_dedicated_error(url, auth)}
    end
  end

  defp fetch_bubble_page(url, auth, state, opts) do
    with {:ok, response, effective_url} <- fetch_redirects(url, auth, state, opts),
         :ok <- require_bubble_header(response.headers, effective_url, auth) do
      {:ok, %{body: response.body, url: effective_url}}
    end
  end

  defp fetch_redirects(url, auth, state, opts) do
    do_fetch_redirects(url, auth, state, opts, MapSet.new(), 0)
  end

  defp do_fetch_redirects(_url, _auth, _state, _opts, _visited, hops)
       when hops > @max_redirects do
    {:error, Error.new(:request_failed, "frontend request exceeded the redirect limit", %{})}
  end

  defp do_fetch_redirects(url, auth, state, opts, visited, hops) do
    normalized = SafeUrl.normalize(url)

    if MapSet.member?(visited, normalized) do
      {:error,
       Error.new(:request_failed, "frontend request encountered a redirect loop", %{
         url: safe(url, auth)
       })}
    else
      headers = if state == :scoped, do: Auth.headers(auth, url), else: []

      case request_once(url, headers, opts, Auth.taints(auth)) do
        {:ok, %{status_code: 200} = response} ->
          {:ok, response, url}

        {:ok, %{status_code: status, headers: response_headers}} when status in 300..399 ->
          follow_redirect(url, response_headers, auth, state, opts, visited, normalized, hops)

        {:ok, %{status_code: status}} ->
          {:error, status_error(status, url, auth)}

        {:error, %HTTP.Error{reason: :body_too_large}} ->
          {:error,
           Error.new(:body_too_large, "frontend response exceeded the configured size limit", %{
             url: safe(url, auth)
           })}

        {:error, _} ->
          {:error, Error.new(:request_failed, "frontend request failed", %{url: safe(url, auth)})}
      end
    end
  end

  defp follow_redirect(url, response_headers, auth, state, opts, visited, normalized, hops) do
    with {:ok, next} <- redirect_location(url, response_headers, auth),
         {:ok, next_state} <- redirect_state(state, auth, next) do
      do_fetch_redirects(
        next,
        auth,
        next_state,
        opts,
        MapSet.put(visited, normalized),
        hops + 1
      )
    end
  end

  defp redirect_state(:none, auth, next) do
    if SafeUrl.https?(next), do: {:ok, :none}, else: {:error, unsafe_redirect_error(next, auth)}
  end

  defp redirect_state(:scoped, auth, next) do
    if SafeUrl.https?(next) and Auth.scoped_to?(auth, next) do
      {:ok, :scoped}
    else
      {:error, unsafe_redirect_error(next, auth)}
    end
  end

  defp request_once(url, headers, opts, taints) do
    timeout = Config.apps_timeout(opts)

    HTTP.get(url, headers,
      follow_redirect: false,
      timeout: timeout,
      recv_timeout: timeout,
      max_body_length: Config.apps_max_body_length(opts),
      redact_values: taints
    )
  end

  defp redirect_location(base, headers, auth) do
    case header(headers, "location") do
      location when is_binary(location) and location != "" ->
        case SafeUrl.resolve(base, location) do
          {:ok, url} ->
            {:ok, url}

          {:error, _} ->
            {:error,
             Error.new(:request_failed, "frontend redirect location is invalid", %{
               url: SafeUrl.safe(location, Auth.taints(auth))
             })}
        end

      _ ->
        {:error,
         Error.new(:request_failed, "frontend redirect had no location", %{
           url: safe(base, auth)
         })}
    end
  end

  defp dynamic_url(page, auth) do
    case Parser.extract_dynamic_js_url(page) do
      {:ok, url} ->
        if SafeUrl.userinfo?(url) or not SafeUrl.https?(url) do
          {:error,
           Error.new(
             :parse_failed,
             "dynamic app payload URL must be an HTTPS URL without userinfo",
             %{}
           )}
        else
          {:ok, url}
        end

      {:error, _} ->
        {:error,
         Error.new(:parse_failed, "failed to discover the dynamic app payload", %{
           url: safe(page.url, auth)
         })}
    end
  end

  defp parse_payload(body) do
    case Parser.parse_app_json(body) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      {:ok, _} ->
        {:error, Error.new(:parse_failed, "dynamic app payload is not an object", %{})}

      {:error, _} ->
        {:error, Error.new(:parse_failed, "failed to parse the dynamic app payload", %{})}
    end
  end

  defp require_bubble_header(headers, url, auth) do
    if Enum.any?(normalize_headers(headers), fn {key, _} ->
         String.starts_with?(String.downcase(key), "x-bubble")
       end) do
      :ok
    else
      {:error,
       Error.new(:not_a_bubble_app, "response is missing the x-bubble header", %{
         url: safe(url, auth)
       })}
    end
  end

  defp header(headers, name) do
    headers
    |> normalize_headers()
    |> Enum.find_value(fn {key, value} -> if String.downcase(key) == name, do: value end)
  end

  defp normalize_headers(headers) when is_map(headers),
    do: Enum.flat_map(headers, &normalize_header/1)

  defp normalize_headers(headers) when is_list(headers),
    do: Enum.flat_map(headers, &normalize_header/1)

  defp normalize_headers(_), do: []

  defp normalize_header({key, values}) when is_list(values),
    do: Enum.map(values, &{to_string(key), to_string(&1)})

  defp normalize_header({key, value}), do: [{to_string(key), to_string(value)}]
  defp normalize_header(_), do: []

  defp auth_state(auth, url) do
    if Auth.enabled?(auth) and Auth.scoped_to?(auth, url), do: :scoped, else: :none
  end

  defp status_error(401, url, auth),
    do:
      Error.new(:unauthorized, "frontend authentication failed (HTTP 401)", %{
        status: 401,
        url: safe(url, auth)
      })

  defp status_error(403, url, auth),
    do:
      Error.new(:forbidden, "frontend authorization failed (HTTP 403)", %{
        status: 403,
        url: safe(url, auth)
      })

  defp status_error(404, url, auth),
    do:
      Error.new(:not_found, "frontend request returned HTTP 404", %{
        status: 404,
        url: safe(url, auth)
      })

  defp status_error(status, url, auth),
    do:
      Error.new(:http_error, "frontend request returned HTTP #{status}", %{
        status: status,
        url: safe(url, auth)
      })

  defp safe(url, auth), do: SafeUrl.safe(url, Auth.taints(auth))

  defp unsafe_redirect_error(url, auth) do
    Error.new(
      :request_failed,
      "frontend payload redirected to an untrusted origin; provide the final URL directly",
      %{url: safe(url, auth)}
    )
  end

  defp unsafe_dedicated_error(url, auth) do
    Error.new(
      :request_failed,
      "Bubble dedicated-instance redirect was not a trusted HTTPS bubble.is URL; provide the final URL directly",
      %{url: safe(url, auth)}
    )
  end
end

defimpl Inspect, for: BubbleEx.Frontend.Fetch.Context do
  import Inspect.Algebra
  def inspect(_context, _opts), do: concat(["#BubbleEx.Frontend.Fetch.Context<redacted>"])
end
