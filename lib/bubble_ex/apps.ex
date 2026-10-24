defmodule BubbleEx.Apps do
  @moduledoc """
  Main interface for interacting with Bubble.io applications.

  This module provides high-level functions for checking, fetching, and analyzing
  Bubble applications. It delegates to specialized modules for specific concerns.

  `fetch_app/2` fetches and parses an app; `fetch_plan/2` answers only the
  question of its plan and hosting, which is all a catalogue or a fleet
  reclassification needs. Both read the plan from the app's live response with
  `BubbleEx.Apps.Plan.classify/1` and share the same helpers, so the rules cannot
  drift between them.
  """

  require Logger

  alias BubbleEx.Apps.{Enricher, Parser, Plan, Validator}
  alias BubbleEx.{Error, HTTP, Telemetry}

  # Types
  @type fetch_option ::
          {:include_payload, boolean()}
          | {:include_static_js, boolean()}
          | {:include_db_diagram, boolean()}
          | {:try_test, boolean()}
          | {:template_lookup, (String.t() -> boolean())}
          | {:username, String.t()}
          | {:password, String.t()}
          | {:naming, :proper | :id}
          | {:foreign_keys, :none | :enforced}
          | {:dbml, boolean()}
          | {:format, atom()}
          | {:external_types, :preserve | :opaque | :legacy}
          | {:external_type_capabilities, %{optional(atom()) => [atom()]}}
          | {:html_max_body_length, pos_integer()}
          | {:script_max_body_length, pos_integer()}
          | {:max_body_length, pos_integer()}
          | {:total_timeout, pos_integer()}
          | {:max_retry_delay, non_neg_integer()}
          | {:max_retries, non_neg_integer()}
          | {:retry_base_delay, pos_integer()}

  @type app_plan :: :free | :paid | :dedicated | :template | nil

  @type app_attrs :: %{
          optional(:schema_diagnostics) => [BubbleEx.Diagnostic.t()],
          optional(:dbml_diagnostics) => [BubbleEx.Diagnostic.t()],
          optional(:static_js) => String.t() | nil,
          optional(:static_js_error) => Error.t(),
          app_plan: app_plan(),
          plan_basis: String.t(),
          is_dedicated: boolean(),
          dedicated_server: String.t() | nil,
          base_url: String.t() | nil,
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

  @typedoc """
  The plan attributes `fetch_plan/2` returns, and the subset of `t:app_attrs/0`
  that `fetch_app/2` fills from the same classification.
  """
  @type plan_attrs :: %{
          app_plan: app_plan(),
          plan_basis: String.t(),
          is_dedicated: boolean(),
          dedicated_server: String.t() | nil,
          base_url: String.t() | nil
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
  def check(url_or_bubble_id), do: check_with_options(url_or_bubble_id, [])

  defp check_with_options(url_or_bubble_id, opts) do
    with {:ok, url} <- Validator.validate_input(url_or_bubble_id),
         {:ok, payload} <- HTTP.fetch_page(url, opts) do
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
  Reads an app's plan and hosting without fetching or parsing the app.

  A fleet-wide reclassification has to answer "what plan is this app on?" for
  thousands of apps, and their bundles can be a hundred megabytes each. This
  function asks Bubble only what answers the question: it normalises
  `url_or_bubble_id` to the app's live origin and probes it once.

  ## Options
    * `:template_lookup` - A one-arity function taking the app's bubble id and
      returning whether it is a marketplace template (`boolean()`). Defaults to
      `Application.get_env(:bubble_ex, :template_lookup)`, then to no templates
      — the same input `fetch_app/2` uses, and likewise never an HTTP call.

  Every other option is passed to `BubbleEx.HTTP.probe/2` (retries, timeouts,
  credentials), so a caller can set `max_retries: 0`.

  ## Returned attributes

  Exactly the plan keys of `fetch_app/2`: `:app_plan`
  (`:template | :dedicated | :free | :paid | nil`), `:plan_basis` (the evidence
  it rests on), `:is_dedicated`, `:dedicated_server` and `:base_url`.

  `url_or_bubble_id` may be a bubble id (`"my-app"`), a
  `https://<id>.bubbleapps.io[/...]` URL, a version URL, or any app URL. It is
  normalised to the live origin the way `fetch_app/2` does it: a
  `/version-<name>` segment and anything after it name the served version, not
  the app, so they are dropped (a dedicated instance's `/site/<app>` path is
  kept).

  ## Requests

  At most two, and never a `dynamic_js` bundle: the live origin, then — only
  when the live answer cannot stand on its own (`live_not_supported`, a `404`, or
  a Bubble redirect that is neither a dedicated instance nor the customer's own
  domain) — one `/version-test` status check, passed to the classification as
  `exists: :yes` on a `2xx`, `:no` on `400`/`404` and `:unknown` otherwise. A
  live `200` or a custom-domain redirect needs none.

  ## Errors and unknowns

  An app that answers anything gives `{:ok, attrs}`, so a caller can store the
  observation: a `429`, `5xx` or unreadable redirect, like an app that answers
  `400`, comes back with `:app_plan` nil and a `:plan_basis` naming what was
  missing. A paid plan is never a default. `{:error, %BubbleEx.Error{}}` is
  reserved for a request that could not be made at all (an input that is not a
  URL or a bubble id, and a transport failure on the live probe), i.e. no
  evidence to store.

  ## Examples

      iex> {:ok, %{app_plan: :paid, plan_basis: "live 200"}} = BubbleEx.Apps.fetch_plan("meta")
  """
  @spec fetch_plan(String.t(), [fetch_option()]) ::
          {:ok, plan_attrs()} | {:error, Error.t()}
  def fetch_plan(url_or_bubble_id, opts \\ []) do
    Telemetry.span([:apps, :fetch_plan], %{input: url_or_bubble_id}, fn ->
      result = fetch_plan_result(url_or_bubble_id, opts)
      {result, fetch_plan_stop_metadata(result)}
    end)
  end

  defp fetch_plan_result(url_or_bubble_id, opts) do
    with {:ok, url} <- Validator.validate_input(url_or_bubble_id) do
      live_url = live_origin(url)
      bubble_id = plan_bubble_id(url_or_bubble_id, url)
      opts = Keyword.put(opts, :credential_origin, live_url)

      case probe_live(live_url, opts) do
        {:ok, live} -> {:ok, plan_attrs(plan_from_live(live, live_url, bubble_id, opts))}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp fetch_plan_stop_metadata({:ok, attrs}) do
    %{app_plan: Map.get(attrs, :app_plan), plan_basis: Map.get(attrs, :plan_basis), error: nil}
  end

  defp fetch_plan_stop_metadata({:error, error}),
    do: %{app_plan: nil, plan_basis: nil, error: error}

  @doc """

  ## Options
    * `:include_payload` - Include full app payload. Defaults to `false`.
    * `:include_static_js` - Also fetch the page's `static.js` (the installed
      plugins' definitions and client-side code) into `:static_js`, for secret
      scanning (`BubbleEx.StaticJs`). Best-effort: when it cannot be found or
      fetched, `:static_js` is nil and `:static_js_error` says why; the app
      fetch still succeeds. Defaults to `false`.
    * `:include_db_diagram` - Include database diagram. Defaults to `false`.
    * `:try_test` - Try the test version when the live version proves nothing
      (`400`/`404`, or Bubble's `live_not_supported` redirect). Defaults to `true`.
    * `:template_lookup` - A one-arity function taking the app's bubble id and
      returning whether it is a marketplace template (`boolean()`). Defaults to
      `Application.get_env(:bubble_ex, :template_lookup)`, then to no templates.
      A template serves its live version like a paid app, so this is the only
      way to know; it never performs an HTTP call.
    * `:username` - Username for authentication.
    * `:password` - Password for authentication. Credentials are restricted to the
      original logical origin, including independently fetched dynamic scripts.
    * `:dbml` - Generate DBML output. Defaults to `false`.
    * `:format` - Schema format to render; output lands in the `:schema` key. Defaults to none.
      One of `:dbml`, `:postgres`, `:sqlite`, `:tsql`, `:ecto`, `:zod`, `:xano`, `:convex`.
    * `:naming` - Naming strategy (`:proper` or `:id`).
    * `:foreign_keys` - SQL formats only: `:none` (default) declares no foreign keys
      and documents references in a comment, since Bubble data can hold dangling
      references; `:enforced` declares them (see `BubbleEx.Db.Encoder.foreign_key?/2`).
      With a SQL `:format`, any other value is an `:invalid_input` error before any
      request is made; other formats ignore it.
    * `:html_max_body_length` - Landing HTML streaming limit (default 5 MB).
    * `:script_max_body_length` - Dynamic bundle streaming limit (default 100 MB).
    * `:max_body_length` - Legacy explicit override for both size limits.
    * `:total_timeout` - Per-response streaming/retry budget in milliseconds (default 30,000).
      This is cooperative; queue consumers should also set an outer job timeout.
    * `:max_retry_delay` - Largest delay allowed inside the caller (default 1,000 ms).
    * `:max_retries` - HTTP retries (default 2); queue consumers should use 0.

  ## Returned attributes

  `:app_plan` (`:template | :dedicated | :free | :paid | nil`), `:plan_basis`
  (the evidence it rests on), `:is_dedicated`, `:dedicated_server` and
  `:base_url` come from `BubbleEx.Apps.Plan.classify/1`, which reads the live
  response instead of guessing. When the response proves nothing (429, 5xx, a
  timeout, an unreadable Bubble redirect) the plan is `nil` and `:plan_basis`
  says what was missing; a paid plan is never assumed.

  The plan is an app-level fact, so a version URL
  (`https://<id>.bubbleapps.io/version-test`, or a dedicated instance's
  `/site/<app>/version-test`) is classified from the live origin: the same URL
  with the `/version-<name>` segment removed, one extra request, fetched
  before the requested URL. `:is_dedicated` follows the hosting evidence, so a
  template on a dedicated instance is still dedicated.

  These five keys are all `fetch_plan/2` returns: it reads the same evidence
  through the same helpers, without fetching or parsing the app, so give it a
  fleet that only needs the plan.
  """

  @spec fetch_app(String.t(), [fetch_option()]) ::
          {:ok, app_attrs()} | {:error, term()}
  def fetch_app(url_or_bubble_id, opts \\ []) do
    Telemetry.span([:apps, :fetch_app], %{input: url_or_bubble_id}, fn ->
      result =
        with {:ok, url} <- Validator.validate_input(url_or_bubble_id),
             :ok <- BubbleEx.Db.Encoder.validate_options(Keyword.get(opts, :format), opts) do
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
    # A discovered bundle is a new request, not an HTTP redirect. Keep the
    # original origin even if the landing page itself redirects elsewhere.
    opts = Keyword.put(opts, :credential_origin, url)

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

  # The live response decides the plan before anything is parsed, and it is the
  # only evidence Bubble gives for it: `Plan.classify/1` turns it into a plan,
  # and the redirect target (or the test version) is fetched next.
  defp fetch_app_from_url(url, opts, context \\ %{}) do
    context = with_live_evidence(url, opts, context)

    case HTTP.probe(url, opts) do
      {:ok, probe} ->
        fetch_app_from_probe(probe, url, opts, context)

      {:error, %Error{kind: :request_failed, context: %{reason: :nxdomain}} = error} ->
        fetch_app_bundle_directly(url, error, opts)

      {:error, error} ->
        {:error, error}
    end
  end

  # The plan is a fact about the app, so it is always read from the live origin.
  # Bubble serves `/version-<name>` (including `/version-test`) for free apps
  # too, so a version URL is fetched as asked — its payload proves the app
  # exists — while the same origin without the version segment answers the
  # plan. That costs one extra request, and only for a version entry point.
  defp with_live_evidence(url, opts, context) do
    cond do
      Map.has_key?(context, :live) ->
        context

      live_url = live_url_for(url) ->
        context
        |> Map.put(:live, live_evidence(live_url, opts))
        |> Map.put(:live_probe, true)

      true ->
        context
    end
  end

  defp live_evidence(live_url, opts) do
    case probe_live(live_url, opts) do
      {:ok, live} ->
        live

      {:error, %Error{context: %{reason: reason}}} ->
        {:error, reason}

      {:error, %Error{kind: kind}} ->
        {:error, kind}
    end
  end

  # The live response as the classifier reads it: a status and its location.
  defp probe_live(url, opts) do
    case HTTP.probe(url, opts) do
      {:ok, probe} -> {:ok, %{status: probe.status, location: probe.location}}
      {:error, error} -> {:error, error}
    end
  end

  # A URL that already is a live origin is probed as given; a version URL is
  # normalised to it first (see `live_url_for/1`).
  defp live_origin(url), do: live_url_for(url) || url

  # Template evidence needs the app's bubble id, and only a bubble id or a
  # bubbleapps.io URL carries it before a payload is parsed.
  defp plan_bubble_id(url_or_bubble_id, url) do
    if Validator.valid_slug?(url_or_bubble_id) do
      url_or_bubble_id
    else
      Parser.extract_bubble_id_from_url(url)
    end
  end

  # The plan-only path: one live probe, plus the existence proof only when the
  # live answer cannot stand on its own (`Plan.existence_needed?/1`).
  defp plan_from_live(live, live_url, bubble_id, opts) do
    exists = if Plan.existence_needed?(live), do: existence(live_url, opts), else: :unknown
    plan_evidence(live, exists, bubble_id, opts)
  end

  # Existence is proven on the origin that answered: a version URL's status is
  # enough, and a 2xx means the app is served there.
  defp existence(live_url, opts) do
    case probe_live(test_version_url(live_url), opts) do
      {:ok, %{status: status}} when status in 200..299 -> :yes
      {:ok, %{status: status}} when status in [400, 404] -> :no
      _ -> :unknown
    end
  end

  defp test_version_url(live_url) do
    uri = URI.parse(live_url)
    base = URI.to_string(%{uri | query: nil, fragment: nil})
    String.trim_trailing(base, "/") <> "/version-test"
  end

  # The live origin of a version URL: the version segment and anything after it
  # name the served version, not the app.
  defp live_url_for(url) do
    uri = URI.parse(url)
    segments = String.split(uri.path || "", "/")

    case Enum.find_index(segments, &String.starts_with?(&1, "version-")) do
      nil ->
        nil

      index ->
        path =
          case segments |> Enum.take(index) |> Enum.join("/") do
            "" -> "/"
            path -> path
          end

        URI.to_string(%{uri | path: path, query: nil, fragment: nil})
    end
  end

  # The app serves its live version: parse the probed body, no second request.
  defp fetch_app_from_probe(%{status: status} = probe, _url, opts, context)
       when status in 200..299 do
    case HTTP.page_from_probe(probe) do
      {:ok, initial_payload} ->
        fetch_app_payload(initial_payload, opts, live_response(probe, context), exists(context))

      {:error, error} ->
        {:error, error}
    end
  end

  # A redirect is Bubble's answer to "may this name serve live?". A version
  # URL's own redirect is never that answer: the context's live evidence is, so
  # its redirect is followed whatever the live origin said (the plan is already
  # decided, or honestly unknown, and the fetch still reaches the app).
  defp fetch_app_from_probe(%{status: status} = probe, url, opts, context)
       when status in 300..399 do
    live = live_response(probe, context)
    classified = Plan.classify(%{live: live, exists: exists(context), template?: false})

    cond do
      Plan.live_not_supported?(live) ->
        fetch_app_test_version(live, probe, url, opts)

      classified.plan in [:paid, :dedicated] or Map.get(context, :live_probe, false) ->
        fetch_app_redirect(live, probe, opts, context, classified)

      true ->
        {:error, no_plan_error(probe, classified)}
    end
  end

  defp fetch_app_from_probe(probe, _url, _opts, _context), do: HTTP.page_from_probe(probe)

  defp fetch_app_redirect(live, probe, opts, context, classified) do
    redirects = Map.get(context, :redirects, 0)

    if redirects < 2 do
      context = context |> Map.put_new(:live, live) |> Map.put(:redirects, redirects + 1)
      follow_redirect(probe, opts, context)
    else
      {:error, no_plan_error(probe, classified)}
    end
  end

  # The redirect target's host can be dead (a lapsed custom domain) while
  # bubbleapps.io still serves this page's bundle, so fall back from the page
  # that redirected, exactly as a direct fetch of it does.
  defp follow_redirect(probe, opts, context) do
    case fetch_app_from_url(probe.location, opts, context) do
      {:error, %Error{kind: :request_failed, context: %{reason: :nxdomain}} = error} ->
        fetch_app_bundle_directly(probe.request_url, error, opts)

      result ->
        result
    end
  end

  # A `live_not_supported` redirect only says the name has no live entitlement;
  # the test version is what proves the app exists, and it is also the evidence
  # `:free` needs.
  defp fetch_app_test_version(live, probe, url, opts) do
    if Keyword.get(opts, :try_test, true) and not String.contains?(url, "version-test") do
      case fetch_app_from_url(build_test_version_url(url, url), opts, %{live: live}) do
        {:ok, attrs} ->
          {:ok, attrs}

        {:error, %Error{context: %{status: status} = ctx}} when status in [400, 404] ->
          {:ok, build_invalid_app_attrs(Map.get(ctx, :url) || url, status)}

        {:error, error} ->
          {:error, error}
      end
    else
      {:error,
       no_plan_error(probe, Plan.classify(%{live: live, exists: :unknown, template?: false}))}
    end
  end

  defp no_plan_error(probe, classified) do
    Error.new(:not_a_bubble_app, "the live response gives no plan evidence", %{
      url: probe.request_url,
      status: probe.status,
      plan_basis: classified.basis
    })
  end

  # A response carrying the plan of an earlier live request keeps it: what the
  # fetch in between proves is that the app exists.
  defp live_response(probe, context) do
    Map.get_lazy(context, :live, fn -> %{status: probe.status, location: probe.location} end)
  end

  defp exists(context), do: if(Map.has_key?(context, :live), do: :yes, else: :unknown)

  defp fetch_app_payload(initial_payload, opts, live, exists) do
    with {:ok, dynamic_js_url} <- Parser.extract_dynamic_js_url(initial_payload),
         {:ok, app_payload} <- fetch_script(dynamic_js_url, opts),
         {:ok, app_data} <- Parser.parse_app_json(app_payload.body) do
      plan = classify_plan(app_data, live, exists, opts)
      attrs = build_app_attrs(app_data, initial_payload, opts, plan)
      {:ok, maybe_add_static_js(attrs, initial_payload, opts)}
    end
  end

  # Both entry points classify from the same evidence and template input, so a
  # plan-only read and a full fetch cannot answer differently.
  defp plan_evidence(live, exists, bubble_id, opts) do
    Plan.classify(%{live: live, exists: exists, template?: template?(bubble_id, opts)})
  end

  defp plan_attrs(plan) do
    %{
      app_plan: plan.plan,
      plan_basis: plan.basis,
      is_dedicated: plan.dedicated_server != nil,
      dedicated_server: plan.dedicated_server,
      base_url: plan.base_url
    }
  end

  # A marketplace template cannot be read from the response, so the owner's
  # lookup is the input (never a request).
  defp classify_plan(app_data, live, exists, opts) do
    plan_evidence(live, exists, Map.get(app_data, "_id"), opts)
  end

  defp template?(bubble_id, opts) when is_binary(bubble_id) do
    lookup =
      Keyword.get(opts, :template_lookup) ||
        Application.get_env(:bubble_ex, :template_lookup)

    is_function(lookup, 1) and lookup.(bubble_id) == true
  end

  defp template?(_bubble_id, _opts), do: false

  defp fetch_script(script_url, opts) do
    HTTP.fetch_page(
      script_url,
      Keyword.put(opts, :max_body_length, BubbleEx.Config.apps_script_max_body_length(opts))
    )
  end

  # `*.bubbleapps.io` resolves for every name, so an NXDOMAIN there comes from
  # the custom domain Bubble redirects page routes to (a lapsed or never
  # pointed domain). Bubble still serves `/package/` routes on bubbleapps.io,
  # so fetch the index page's bundle from there. The path's hash is not
  # validated, but Bubble's cache answers a reused hash with whichever app
  # first used it: use a fresh one and require the bundle to be this app's.
  defp fetch_app_bundle_directly(url, page_error, opts) do
    with %URI{scheme: scheme, host: host, path: path} when scheme in ["http", "https"] <-
           URI.parse(url),
         [_, bubble_id] <- Regex.run(~r/\A([a-z0-9-]+)\.bubbleapps\.io\z/i, host || ""),
         version = url_version(path),
         {:ok, app_payload} <- fetch_script(bundle_url(scheme, host, bubble_id, version), opts),
         {:ok, %{"_id" => ^bubble_id} = app_data} <- Parser.parse_app_json(app_payload.body),
         true <- Map.get(app_data, "app_version", version) == version do
      Logger.info("Fetched #{bubble_id} (#{version}) bundle directly; its page redirect is dead")
      plan = Plan.classify(bundle_evidence(app_data, page_error, opts))
      attrs = build_app_attrs(app_data, %{app_payload | domain: host}, opts, plan)
      {:ok, maybe_add_static_js(attrs, nil, opts)}
    else
      _ -> {:error, page_error}
    end
  end

  # The bundle proves which app it is, but a bundle says nothing about the
  # live version's plan: the page that would have answered is the one that died.
  defp bundle_evidence(app_data, %Error{context: %{reason: reason}}, opts) do
    %{
      live: {:error, reason},
      exists: :yes,
      template?: template?(Map.get(app_data, "_id"), opts)
    }
  end

  # `static.js` is named only by the landing page; the direct bundle fallback
  # has none, so it reports the script as not found.
  defp maybe_add_static_js(attrs, initial_payload, opts) do
    if Keyword.get(opts, :include_static_js, false) do
      case fetch_static_js(initial_payload, opts) do
        {:ok, body} -> Map.put(attrs, :static_js, body)
        {:error, error} -> Map.merge(attrs, %{static_js: nil, static_js_error: error})
      end
    else
      attrs
    end
  end

  defp fetch_static_js(nil, _opts) do
    {:error,
     Error.new(:parse_failed, "could not find the app's static_js script", %{
       phase: :discover_static_js,
       reason: :no_landing_page
     })}
  end

  defp fetch_static_js(initial_payload, opts) do
    with {:ok, static_js_url} <- Parser.extract_static_js_url(initial_payload),
         {:ok, %{body: body}} when is_binary(body) <- fetch_script(static_js_url, opts) do
      {:ok, body}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      _ ->
        {:error,
         Error.new(:parse_failed, "the app's static_js script is not text", %{
           phase: :fetch_static_js
         })}
    end
  end

  defp url_version(path) do
    case Regex.run(~r{\A/version-([^/]+)}, path || "") do
      [_, version] -> version
      _ -> "live"
    end
  end

  defp bundle_url(scheme, host, bubble_id, version) do
    hash = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    "#{scheme}://#{host}/package/dynamic_js/#{hash}/#{bubble_id}/#{version}" <>
      "/index/xnull/xfalse/xtrue/en_us/xfalse/xfalse/dynamic.js"
  end

  defp maybe_try_test_version(url_or_bubble_id, url, request_url, status_code, opts) do
    if Keyword.get(opts, :try_test, true) && !String.contains?(url, "version-test") do
      test_url = build_test_version_url(url_or_bubble_id, url)
      live = %{status: status_code, location: nil}

      case fetch_app_from_url(test_url, opts, %{live: live}) do
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

    Logger.info("Fetching obj endpoint")
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

    Logger.info("Fetching workflow endpoint")
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
    base_url = "https://#{bubble_id}.bubbleapps.io/"
    opts = [username: username, password: password]

    versions =
      case check_with_options(base_url, opts) do
        %{valid: true} -> ["live"]
        _ -> []
      end

    case check_with_options(base_url <> "version-test", opts) do
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

  defp build_app_attrs(app_data, initial_payload, opts, plan) do
    Map.merge(plan_attrs(plan), %{
      bubble_id: app_data["_id"],
      url: initial_payload.domain,
      title: Parser.extract_title(app_data),
      valid?: true
    })
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
