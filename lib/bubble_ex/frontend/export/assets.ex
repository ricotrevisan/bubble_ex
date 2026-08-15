defmodule BubbleEx.Frontend.Export.Assets do
  @moduledoc false

  alias BubbleEx.{Config, HTTP}
  alias BubbleEx.Frontend.Normalized.Node

  @content_types %{
    "png" => "png",
    "jpeg" => "jpg",
    "jpg" => "jpg",
    "gif" => "gif",
    "webp" => "webp",
    "svg" => "svg",
    "woff2" => "woff2",
    "woff" => "woff"
  }

  @spec collect(Node.t(), keyword()) :: {%{optional(String.t()) => map()}, [map()]}
  def collect(nodes, opts) when is_list(nodes) do
    {assets, findings} =
      nodes
      |> Enum.flat_map(&image_nodes/1)
      |> Enum.reduce({%{}, []}, &collect_one(&1, &2, opts))

    {assets, Enum.reverse(findings)}
  end

  def collect(%Node{} = node, opts), do: collect([node], opts)

  defp collect_one(node, {assets, findings}, opts) do
    case resolved_src(node) do
      url when is_binary(url) -> merge_download(node, url, assets, findings, opts)
      _ -> {assets, findings}
    end
  end

  defp merge_download(node, url, assets, findings, opts) do
    case download(url, opts) do
      {:ok, asset} -> {Map.put(assets, node.exporter_id, asset), findings}
      {:error, finding} -> {assets, [finding | findings]}
    end
  end

  defp image_nodes(%Node{kind: :image} = node), do: [node]
  defp image_nodes(%Node{children: children}), do: Enum.flat_map(children, &image_nodes/1)

  defp resolved_src(%Node{content: %{"src" => %{resolved: url}}}), do: url
  defp resolved_src(%Node{content: %{"src" => %{"resolved" => url}}}), do: url
  defp resolved_src(_), do: nil

  defp download(url, opts) do
    if http?(url),
      do: fetch_asset(url, opts),
      else: {:error, asset_finding(url, "asset is not a public HTTP URL")}
  end

  defp fetch_asset(url, opts) do
    timeout = Config.frontend_asset_timeout(opts)
    max_bytes = Config.frontend_max_asset_bytes(opts)

    case HTTP.get(url, [], recv_timeout: timeout, timeout: timeout) do
      {:ok, %{status_code: 200, body: body, headers: headers}} ->
        store_or_reject(url, body, headers, max_bytes)

      {:ok, %{status_code: status}} ->
        {:error, asset_finding(url, "asset download returned HTTP #{status}")}

      {:error, _} ->
        {:error, asset_finding(url, "asset download failed")}
    end
  end

  defp store_or_reject(url, body, headers, max_bytes) do
    if byte_size(body) > max_bytes do
      {:error, asset_finding(url, "asset exceeded max_asset_bytes")}
    else
      {:ok, asset_record(url, body, headers)}
    end
  end

  defp asset_record(url, body, headers) do
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    name = hashed_name(hash, extension(headers, url))
    %{path: "assets/" <> name, bytes: body, sha256: hash, url: url}
  end

  defp hashed_name(hash, nil), do: hash
  defp hashed_name(hash, ext), do: hash <> "." <> ext

  defp http?(url), do: String.starts_with?(url, "http://") or String.starts_with?(url, "https://")

  defp extension(headers, url) do
    headers
    |> content_type()
    |> ext_from_content_type()
    |> Kernel.||(ext_from_url(url))
  end

  defp content_type(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == "content-type", do: v
    end)
  end

  defp ext_from_content_type(ctype) when is_binary(ctype) do
    Enum.find_value(@content_types, fn {needle, ext} ->
      if String.contains?(ctype, needle), do: ext
    end)
  end

  defp ext_from_content_type(_), do: nil

  defp ext_from_url(url) do
    path = url |> URI.parse() |> Map.get(:path)
    ext_from_path(path)
  end

  defp ext_from_path(path) when is_binary(path) do
    case Path.extname(path) do
      "." <> rest -> String.downcase(rest)
      _ -> nil
    end
  end

  defp ext_from_path(_), do: nil

  defp asset_finding(url, message) do
    %{
      "severity" => "warning",
      "type" => "asset_failure",
      "message" => message,
      "refs" => [],
      "payload" => %{"url" => url}
    }
  end
end
