defmodule BubbleEx.Editor.Pages do
  @moduledoc false

  alias BubbleEx.Apps.Parser
  alias BubbleEx.Editor.{PageRef, Target}
  alias BubbleEx.Workflows.Source
  alias BubbleEx.{Error, HTTP}

  @spec discover(Target.t(), keyword()) :: {:ok, [PageRef.t()]} | {:error, Error.t()}
  def discover(target, opts) do
    with {:ok, url} <- runtime_url(target, Keyword.get(opts, :runtime_page, "index")),
         {:ok, html} <- fetch(url, opts),
         {:ok, bundle_url} <- parse_url(html, url),
         {:ok, bundle} <- fetch(bundle_url, opts),
         {:ok, app} <- parse_app(bundle) do
      references(app, target, url)
    end
  end

  defp runtime_url(target, page) when is_binary(page) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, page) do
      version = if target.version == "live", do: "", else: "/version-" <> target.version
      {:ok, "https://#{target.appname}.bubbleapps.io#{version}/#{page}"}
    else
      {:error, Error.new(:invalid_input, "runtime page must be a page route segment")}
    end
  end

  defp runtime_url(_target, _page),
    do: {:error, Error.new(:invalid_input, "runtime page must be a page route segment")}

  # Never inherit editor auth/options. The shared HTTP layer still owns DNS,
  # destination policy, body limits and deadlines. Only this GET seam is injectable.
  defp fetch(url, opts) do
    get = Keyword.get(opts, :runtime_get_fun, &HTTP.get/3)

    request_opts = [
      retry: false,
      follow_redirect: false,
      redirect: false,
      auth: nil,
      anonymous: true,
      decode_body: false,
      bounded_body: true,
      max_body_length: BubbleEx.Config.apps_max_body_length([])
    ]

    case get.(url, [], request_opts) do
      {:ok, %HTTP.Response{status_code: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %HTTP.Response{status_code: status}} ->
        error = Error.from_http(status, nil)

        {:error,
         %{error | message: "runtime discovery request failed", context: %{status: status}}}

      {:error, _error} ->
        {:error, Error.new(:request_failed, "runtime discovery request failed")}

      _ ->
        parse_error()
    end
  end

  defp parse_url(html, url) do
    case Parser.extract_dynamic_js_url(%{body: html, url: url}) do
      {:ok, bundle_url} ->
        uri = URI.parse(bundle_url)

        if uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
             is_nil(uri.fragment) and String.starts_with?(uri.path || "", "/package/dynamic_js") do
          {:ok, bundle_url}
        else
          parse_error()
        end

      _ ->
        parse_error()
    end
  end

  defp parse_app(bundle) do
    case Parser.parse_app_json(bundle) do
      {:ok, app} when is_map(app) -> {:ok, app}
      _ -> parse_error()
    end
  rescue
    _exception -> parse_error()
  end

  defp references(app, target, url) do
    # Discovery needs only owner metadata. Do not index/traverse page elements,
    # workflows or other descendants just to extract an identity.
    refs =
      for section <- ["pages", "%p3"],
          pages = Map.get(app, section, %{}),
          {key, node} <- if(is_map(pages), do: Source.entries(pages), else: [{nil, nil}]),
          do: reference(node, section, key, target, url)

    if refs != [] and Enum.all?(refs, &(PageRef.validate(&1, target) == :ok)) and
         unique?(refs, :key) and unique?(refs, :id) do
      {:ok, Enum.sort_by(refs, & &1.key)}
    else
      parse_error()
    end
  end

  defp reference(node, section, key, target, url) when is_map(node) and is_binary(key) do
    ref = %PageRef{
      appname: target.appname,
      version: target.version,
      key: key,
      id: Source.value(node, ~w(id %id)),
      name: Source.value(node, ~w(name %nm default_name)),
      path: ["%p3", key],
      source: %{kind: :runtime, url: url, pointer: Source.pointer([section, key])}
    }

    # The page section identifies the kind when no type is emitted; every
    # explicit type/ID/name field must still agree, including both key forms.
    if PageRef.matches?(ref, Map.put_new(node, "type", "Page")), do: ref
  end

  defp reference(_node, _section, _key, _target, _url), do: nil

  defp unique?(refs, field) do
    values = Enum.map(refs, &Map.fetch!(&1, field))
    length(values) == length(Enum.uniq(values))
  end

  defp parse_error,
    do:
      {:error,
       Error.new(:parse_failed, "runtime page discovery did not provide valid page identities")}
end
