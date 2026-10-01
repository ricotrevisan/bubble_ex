defmodule BubbleEx.Frontend.StaticAssets do
  @moduledoc """
  The static assets of a Bubble frontend (WTF-447): the images and icons
  set in the editor on its pages and reusable elements, which a migrated
  app must serve itself instead of hotlinking Bubble's storage.

  Two separate steps:

    * **Fetch** (`fetch/3`, `mix bubble.fetch_assets`): explicit and
      owner-run, the only step that makes requests. It downloads the
      assets on **Bubble's storage hosts only** (`BubbleEx.Load.Files.bubble?/2`:
      `*.cdn.bubble.io`, Bubble's S3 bucket and CloudFront distribution;
      every redirect is checked against the same allowlist) and, with
      `app_url:`, the icon libraries on the app's own origin
      (`/static/icon_libraries/…`), through the frontend exporter's fetcher
      (`BubbleEx.Frontend.Export.Assets`: public destinations only, at most
      5 redirects, a size cap and a deadline). URLs with credentials
      (userinfo, a credential-like query parameter) are never requested.
      A download is kept only if its bytes are a PNG, JPEG, GIF or WebP
      image (magic bytes, never the name or the header) or an SVG,
      which is kept sanitized (`BubbleEx.Frontend.SvgSanitizer`); icon
      libraries are kept as they are and only ever inlined one sanitized
      symbol at a time. Files are content-addressed (`<sha256>.<ext>`) in
      a store directory with an `index.json`.
    * **Render** (`BubbleEx.Target.Phoenix.render/2` with `asset_store:`,
      the store as `load_store/1` reads it): offline and deterministic. A
      stored image is served by the app from `priv/bubble_images/`
      and referenced as `/images/bubble/<sha256>.<ext>`; a Bubble-hosted
      image not in the store renders **without a source** (never its
      Bubble URL) and is `pending`; an image on any other host is
      `external`: linked to its original URL (over HTTPS), as Bubble does;
      `data:` images stay inline; anything else is dropped (`invalid`).
      `.wtf/assets.json` (`manifest/3`) lists every asset with its status.

  Images on other hosts are never fetched, proxied or dropped: Bubble
  hotlinks them, and so does the migrated app (WTF-465). The
  page links them with `referrerpolicy="no-referrer"` and
  `loading="lazy"`, the app's `img-src` allows `https:`, and they are
  listed as informational, not as work to do.
  """

  import Bitwise

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Frontend.{Normalized, ReusableParameters, ResponsiveImages, SafeUrl}
  alias BubbleEx.Frontend.Export.Assets
  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Frontend.SvgSanitizer
  alias BubbleEx.Load.Files

  @index "index.json"
  @version 1
  @icon_path ~r{\A/static/icon_libraries/[a-z0-9][a-z0-9.-]*\.svg\z}
  @stored_file ~r/\A[0-9a-f]{64}\.(?:png|jpg|gif|webp|svg)\z/
  @data_image ~r{\Adata:image/(?:png|jpeg|gif|webp)(?:;base64)?,}i

  @types %{
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp",
    "svg" => "image/svg+xml"
  }

  @typedoc "An asset the frontend references, with the elements that show it."
  @type asset_reference :: %{
          ref: String.t(),
          kind: :image | :icon,
          ids: [String.t()],
          elements: [String.t()]
        }

  @typedoc "Where a reference stands (`resolve/3`)."
  @type resolution ::
          {:local, map()}
          | {:pending, String.t()}
          | {:external, String.t()}
          | {:data, String.t()}
          | {:invalid, String.t()}

  defmodule Store do
    @moduledoc """
    Downloaded assets (`BubbleEx.Frontend.StaticAssets.load_store/1`):
    entries by reference (a Bubble URL, or an icon library's path), each
    `%{ref, url, kind, file, sha256, content_type, size, bytes}` and
    verified when read; `errors` lists the entries that failed.
    """
    defstruct entries: %{}, errors: []

    @type t :: %__MODULE__{entries: %{String.t() => map()}, errors: [map()]}
  end

  # --- references ---------------------------------------------------------------

  @doc """
  Every static asset the frontend's pages and reusable elements reference:
  images (and their responsive variants, and the values reusable instances
  give them) and icon libraries, grouped by reference and sorted.
  """
  @spec references(Normalized.t()) :: [asset_reference()]
  def references(%Normalized{} = frontend) do
    by_ref =
      Enum.reduce(frontend.reusables, %{}, fn d, acc ->
        acc |> Map.put(d.map_key, d) |> Map.put(d.source.bubble_id, d)
      end)

    (frontend.pages ++ frontend.reusables)
    |> Enum.flat_map(&walk(&1, by_ref, MapSet.new()))
    |> Enum.group_by(fn {kind, ref, _node} -> {kind, ref} end, fn {_, _, node} -> node end)
    |> Enum.map(fn {{kind, ref}, nodes} ->
      %{
        ref: ref,
        kind: kind,
        ids: nodes |> Enum.map(& &1.exporter_id) |> Enum.uniq() |> Enum.sort(),
        elements: nodes |> Enum.map(&element_id/1) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{&1.kind, &1.ref})
  end

  defp walk(%Node{kind: :image} = node, by_ref, seen) do
    own =
      case image_ref(node) do
        ref when is_binary(ref) -> [{:image, ref, node}]
        _ -> []
      end

    variants = for v <- ResponsiveImages.variants(node), do: {:image, v.src, node}
    own ++ variants ++ walk_children(node, by_ref, seen)
  end

  defp walk(%Node{kind: :reusable_instance, definition_ref: ref} = node, by_ref, seen) do
    with %Node{} = definition <- by_ref[ref],
         false <- MapSet.member?(seen, definition.map_key),
         %Node{} = expanded <- ReusableParameters.expand(definition, node) do
      walk_children(expanded, by_ref, MapSet.put(seen, definition.map_key))
    else
      _ -> []
    end
  end

  defp walk(%Node{attributes: %{"asset_fragment" => fragment} = attributes} = node, by_ref, seen)
       when is_binary(fragment) and fragment != "" do
    icon =
      case attributes["asset_src"] do
        src when is_binary(src) and src != "" -> [{:icon, src, node}]
        _ -> []
      end

    icon ++ walk_children(node, by_ref, seen)
  end

  defp walk(%Node{} = node, by_ref, seen), do: walk_children(node, by_ref, seen)

  defp walk_children(%Node{children: children}, by_ref, seen),
    do: Enum.flat_map(children || [], &walk(&1, by_ref, seen))

  @doc """
  An image element's static source, as the HEEx emitter reads it: the
  normalized fallback URL (`asset_src`), else the resolved `src`.
  """
  @spec image_ref(Node.t()) :: String.t() | nil
  def image_ref(%Node{} = node) do
    case node.attributes["asset_src"] || resolved(node, "src") do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end

  defp resolved(%Node{content: content}, slot) when is_map(content) do
    case content[slot] do
      %{resolved: value} -> value
      %{"resolved" => value} -> value
      _ -> nil
    end
  end

  defp resolved(_node, _slot), do: nil

  defp element_id(%Node{source: %{bubble_id: id}}) when is_binary(id) and id != "", do: id
  defp element_id(%Node{map_key: key}) when is_binary(key) and key != "", do: key
  defp element_id(%Node{exporter_id: id}), do: id

  # --- classification -----------------------------------------------------------

  @doc """
  What a reference is: `{:bubble, https_url}` (Bubble's storage, to fetch),
  `{:icon, path}` (an icon library on the app's origin), `{:external, https_url}`
  (another host: linked, never fetched; an `http://` reference is linked
  over HTTPS), `{:data, url}` (an inline raster image) or
  `{:invalid, reason}` (any other scheme, credentials, a relative path,
  control characters, an `http://` URL on a port other than 80).
  """
  @spec classify(term(), :image | :icon) ::
          {:bubble | :icon | :external | :data, String.t()} | {:invalid, String.t()}
  def classify(ref, kind \\ :image)

  def classify(ref, :icon) when is_binary(ref) do
    if Regex.match?(@icon_path, ref),
      do: {:icon, ref},
      else: {:invalid, "not a Bubble icon library"}
  end

  def classify(ref, :image) when is_binary(ref) do
    url = String.trim(ref)

    cond do
      url == "" -> {:invalid, "empty source"}
      Regex.match?(@data_image, url) -> {:data, url}
      true -> classify_http(Files.normalize(url))
    end
  end

  def classify(_ref, _kind), do: {:invalid, "not a URL"}

  defp classify_http(url) do
    case URI.new(url) do
      {:ok, %URI{userinfo: userinfo}} when not is_nil(userinfo) ->
        {:invalid, "the URL carries credentials"}

      # An http:// URL on another port has no HTTPS equivalent to link.
      {:ok, %URI{scheme: "http", port: port}} when port != 80 ->
        {:invalid, "an http:// URL on a port other than 80"}

      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        classify_host(url, secure(uri))

      _ ->
        {:invalid, "not an http(s) URL"}
    end
  end

  defp classify_host(url, secure) do
    cond do
      Regex.match?(~r/[\x00-\x20\x7f]/, url) -> {:invalid, "not a URL"}
      SafeUrl.sensitive_query?(url) -> {:invalid, "credential-like query parameter"}
      Files.bubble?(secure) -> {:bubble, secure}
      true -> {:external, secure}
    end
  end

  # Bubble's storage serves HTTPS; an http:// reference is fetched and
  # keyed over HTTPS, with its host in lower case. An image on another host
  # is linked over HTTPS too: Bubble serves its pages over HTTPS, where
  # browsers upgrade an http:// image, and the generated app's `img-src`
  # allows `https:` only.
  defp secure(%URI{scheme: scheme, port: port, host: host} = uri) do
    port = if scheme == "http" and port == 80, do: 443, else: port
    URI.to_string(%{uri | scheme: "https", port: port, host: String.downcase(host)})
  end

  # --- render ---------------------------------------------------------------------

  @doc """
  Where a reference stands against a store (nil: nothing downloaded):
  `{:local, entry}`, `{:pending, url}` (Bubble's, not downloaded),
  `{:external, url}`, `{:data, url}` or `{:invalid, reason}`.
  """
  @spec resolve(term(), :image | :icon, Store.t() | nil) :: resolution()
  def resolve(ref, kind, store) do
    case classify(ref, kind) do
      {class, key} when class in [:bubble, :icon] ->
        case store do
          %Store{entries: %{^key => %{kind: ^kind} = entry}} -> {:local, entry}
          _ -> {:pending, key}
        end

      other ->
        other
    end
  end

  @doc """
  The exporter's downloads (the `assets:` option of
  `BubbleEx.Target.Phoenix.render/2`, by exporter ID) as the app may
  serve them: each one's bytes checked like a fetched image's (`typed/1`:
  PNG, JPEG, GIF or WebP by their magic bytes, an SVG sanitized), its
  path content-addressed with the verified type's extension; anything
  else becomes `%{failed?: true}` (rendered without a source).
  """
  @spec verified_assets(map()) :: map()
  def verified_assets(assets) when is_map(assets) do
    Map.new(assets, fn
      {id, %{bytes: bytes} = asset} when is_binary(bytes) ->
        case typed(bytes) do
          {:ok, ext, clean} ->
            sha = sha256(clean)

            {id,
             %{asset | bytes: clean} |> Map.merge(%{path: "assets/#{sha}.#{ext}", sha256: sha})}

          {:error, _} ->
            {id, %{failed?: true}}
        end

      {id, asset} ->
        {id, asset}
    end)
  end

  def verified_assets(_assets), do: %{}

  @doc "The app path a stored image is served at."
  @spec src(map()) :: String.t()
  def src(%{file: file}), do: "/images/bubble/" <> file

  @doc "The project path a stored image is written to."
  @spec path(map()) :: String.t()
  def path(%{file: file}), do: "priv/bubble_images/" <> file

  @doc """
  `.wtf/assets.json`: every static asset of the frontend with its status
  (`local`, `pending`, `external`, `data`, `invalid`), the elements that
  show it and, when local, its path, SHA-256, content type and size.
  `assets` are the exporter's downloads by exporter ID (the `assets:`
  option), which win over the store.
  """
  @spec manifest(Normalized.t(), Store.t() | nil, map()) :: map()
  def manifest(%Normalized{} = frontend, store, assets \\ %{}) do
    # One entry per asset: references that resolve to the same URL (`//…`
    # and `https://…`, say) are merged.
    entries =
      frontend
      |> references()
      |> Enum.map(&manifest_entry(&1, store, assets))
      |> Enum.group_by(&{&1["kind"], &1["url"], &1["status"]})
      |> Enum.map(fn {_key, [first | _] = same} ->
        elements = same |> Enum.flat_map(& &1["elements"]) |> Enum.uniq() |> Enum.sort()
        Map.put(first, "elements", elements)
      end)
      |> Enum.sort_by(&{&1["kind"], &1["url"], &1["status"]})

    counts =
      Enum.reduce(
        entries,
        %{"local" => 0, "pending" => 0, "external" => 0, "data" => 0, "invalid" => 0},
        fn entry, acc -> Map.update(acc, entry["status"], 1, &(&1 + 1)) end
      )

    %{
      "version" => @version,
      "about" =>
        "Static images and icons of the Bubble pages (WTF-447). local: served by the app " <>
          "from priv/bubble_images (icons inlined); pending: on Bubble's storage, not " <>
          "downloaded, rendered without a source (run mix bubble.fetch_assets, then render " <>
          "with its store); external: on another host, linked to its original URL as " <>
          "Bubble does (informational: never fetched, nothing to fix); data: inline; " <>
          "invalid: dropped.",
      "counts" => counts,
      "assets" => entries
    }
  end

  @doc "The manifest as its JSON file."
  @spec encode_manifest(map()) :: String.t()
  def encode_manifest(manifest) do
    manifest |> CanonicalJson.ordered() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")
  end

  defp manifest_entry(reference, store, assets) do
    base = %{
      "kind" => Atom.to_string(reference.kind),
      "elements" => reference.elements
    }

    case exporter_asset(reference, assets) do
      %{path: path, bytes: bytes} = asset ->
        Map.merge(base, %{
          "url" => display_url(reference.ref),
          "status" => "local",
          "src" => "/images/bubble/" <> Path.basename(path),
          "sha256" => asset[:sha256] || sha256(bytes),
          "content_type" => @types[path |> Path.extname() |> String.trim_leading(".")],
          "size" => byte_size(bytes)
        })

      nil ->
        Map.merge(base, resolution_entry(reference, store))
    end
  end

  defp exporter_asset(%{kind: :image, ids: [id | _]}, assets) do
    case assets[id] do
      %{path: path, bytes: bytes} = asset when is_binary(path) and is_binary(bytes) -> asset
      _ -> nil
    end
  end

  defp exporter_asset(_reference, _assets), do: nil

  defp resolution_entry(reference, store) do
    case resolve(reference.ref, reference.kind, store) do
      {:local, entry} ->
        %{
          "url" => display_url(entry.url),
          "status" => "local",
          "sha256" => entry.sha256,
          "content_type" => entry.content_type,
          "size" => entry.size
        }
        |> Map.merge(
          if reference.kind == :image,
            do: %{"src" => src(entry), "path" => path(entry)},
            else: %{"inlined" => true}
        )

      {:pending, url} ->
        %{
          "url" => display_url(url),
          "status" => "pending",
          "reason" => "on Bubble's storage and not downloaded: rendered without a source"
        }

      {:external, url} ->
        %{
          "url" => display_url(url),
          "status" => "external",
          "handling" => "linked",
          "host" => host(url),
          "note" => external_note(url)
        }

      {:data, url} ->
        %{"url" => display_url(url), "status" => "data"}

      {:invalid, reason} ->
        %{"url" => display_url(reference.ref), "status" => "invalid", "reason" => reason}
    end
  end

  defp external_note(url) do
    note = "on another host: linked to its original URL, as in Bubble"

    if local_host?(host(url)),
      do: note <> "; a loopback or private address, which loads only on the viewer's network",
      else: note
  end

  @doc """
  Whether a host is a loopback, private, link-local or otherwise
  non-public address (or `localhost`): such an image is still linked, as
  in Bubble, and its manifest entry says so.
  """
  @spec local_host?(String.t() | nil) :: boolean()
  def local_host?(host) when is_binary(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()

    if host == "localhost" or String.ends_with?(host, ".localhost") do
      true
    else
      case :inet.parse_strict_address(String.to_charlist(host)) do
        {:ok, ip} -> not BubbleEx.HTTP.Destination.public_ip?(unmapped(ip))
        {:error, _} -> false
      end
    end
  end

  def local_host?(_host), do: false

  # An IPv4-mapped IPv6 address is its IPv4 address.
  defp unmapped({0, 0, 0, 0, 0, 0xFFFF, a, b}), do: {a >>> 8, a &&& 255, b >>> 8, b &&& 255}
  defp unmapped(ip), do: ip

  @doc "The host of a URL (for diagnostics), or nil."
  @spec host(String.t()) :: String.t() | nil
  def host(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end

  # URLs in reports: without credentials, and a data URL only by its type.
  defp display_url("data:" <> _ = url), do: url |> String.split(",", parts: 2) |> hd()
  defp display_url(url), do: SafeUrl.safe(url)

  # --- store ----------------------------------------------------------------------

  @doc """
  Reads a store directory (`fetch/3`'s): every entry is checked again (its
  file name, SHA-256 and size; an image's bytes must still be the type
  recorded and an SVG must still be sanitized) and dropped into `errors`
  otherwise. An absent directory is an empty store.
  """
  @spec load_store(Path.t()) :: {:ok, Store.t()} | {:error, Error.t()}
  def load_store(dir) when is_binary(dir) do
    with {:ok, index} <- read_index(dir) do
      {entries, errors} =
        index
        |> Map.get("assets", %{})
        |> Enum.sort()
        |> Enum.reduce({%{}, []}, &load_into(dir, &1, &2))

      {:ok, %Store{entries: entries, errors: Enum.reverse(errors)}}
    end
  end

  defp load_into(dir, {ref, raw}, {entries, errors}) do
    case load_entry(dir, ref, raw) do
      {:ok, entry} -> {Map.put(entries, ref, entry), errors}
      {:error, reason} -> {entries, [%{ref: SafeUrl.safe(ref), reason: reason} | errors]}
    end
  end

  defp read_index(dir) do
    path = Path.join(dir, @index)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"version" => @version, "assets" => assets} = index} when is_map(assets) ->
            {:ok, index}

          _ ->
            {:error, Error.new(:invalid_input, "asset store index is invalid", %{path: path})}
        end

      {:error, :enoent} ->
        {:ok, %{"version" => @version, "assets" => %{}}}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_input, "asset store index could not be read", %{reason: reason})}
    end
  end

  defp load_entry(dir, ref, %{"file" => file, "sha256" => sha, "size" => size} = raw)
       when is_binary(file) and is_binary(sha) and is_integer(size) do
    kind = if raw["kind"] == "icon", do: :icon, else: :image

    with :ok <- entry_fields(raw["url"], file),
         {class, ^ref} when class in [:bubble, :icon] <- classify(ref, kind),
         {:ok, bytes} <- read_stored(Path.join(dir, file)),
         true <- sha256(bytes) == sha || {:error, "SHA-256 mismatch"},
         true <- byte_size(bytes) == size || {:error, "size mismatch"},
         {:ok, ext, type} <- verify(kind, bytes),
         true <- file == sha <> "." <> ext || {:error, "file name does not match its bytes"} do
      {:ok,
       %{
         ref: ref,
         url: raw["url"] || ref,
         kind: kind,
         file: file,
         sha256: sha,
         content_type: type,
         size: size,
         bytes: bytes
       }}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "invalid entry"}
    end
  end

  defp load_entry(_dir, _ref, _raw), do: {:error, "invalid entry"}

  # The recorded download URL (reported, never requested) is a string or
  # absent; the file is a content address.
  defp entry_fields(url, file) do
    cond do
      not (is_nil(url) or (is_binary(url) and String.valid?(url))) -> {:error, "invalid url"}
      not Regex.match?(@stored_file, file) -> {:error, "invalid file name"}
      true -> :ok
    end
  end

  defp read_stored(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, bytes}
          _ -> {:error, "file could not be read"}
        end

      _ ->
        {:error, "missing or not a regular file"}
    end
  end

  # A stored image is still of its type; an SVG is still sanitized; an
  # icon library is still an SVG sprite (inlined one sanitized symbol at
  # a time, never served).
  defp verify(:image, bytes) do
    case typed(bytes) do
      {:ok, "svg", ^bytes} -> {:ok, "svg", @types["svg"]}
      {:ok, "svg", _other} -> {:error, "SVG is not sanitized"}
      {:ok, ext, _bytes} -> {:ok, ext, @types[ext]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify(:icon, bytes) do
    if sprite?(bytes), do: {:ok, "svg", @types["svg"]}, else: {:error, "not an icon library"}
  end

  @doc false
  # The type of downloaded bytes by their magic bytes: {:ok, ext, bytes}
  # (an SVG sanitized), else {:error, reason}. Never the name or header.
  @spec typed(binary()) :: {:ok, String.t(), binary()} | {:error, String.t()}
  def typed(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>> = bytes), do: {:ok, "png", bytes}
  def typed(<<0xFF, 0xD8, 0xFF, _::binary>> = bytes), do: {:ok, "jpg", bytes}
  def typed(<<"GIF87a", _::binary>> = bytes), do: {:ok, "gif", bytes}
  def typed(<<"GIF89a", _::binary>> = bytes), do: {:ok, "gif", bytes}
  def typed(<<"RIFF", _::binary-size(4), "WEBP", _::binary>> = bytes), do: {:ok, "webp", bytes}

  def typed(bytes) when is_binary(bytes) do
    case SvgSanitizer.sanitize(bytes) do
      {:ok, svg} -> {:ok, "svg", svg}
      :error -> {:error, "not a PNG, JPEG, GIF, WebP or SVG image"}
    end
  end

  defp sprite?(bytes) do
    String.valid?(bytes) and String.contains?(bytes, "<svg") and
      String.contains?(bytes, "<symbol")
  end

  @doc """
  An icon's symbol from a stored icon library, sanitized
  (`BubbleEx.Frontend.Export.Assets`), or nil.
  """
  @spec icon_symbol(map(), String.t()) :: binary() | nil
  def icon_symbol(%{kind: :icon, bytes: bytes}, fragment) do
    case Assets.sanitize_icon_sprite(bytes, fragment) do
      {:ok, svg} -> svg
      :error -> nil
    end
  end

  def icon_symbol(_entry, _fragment), do: nil

  # --- fetch ----------------------------------------------------------------------

  @doc """
  Downloads the frontend's Bubble-hosted assets into `dir` (see the
  moduledoc) and writes its `index.json`. Entries already in the store
  (and still valid) are not fetched again. Options: `:app_url` (the
  Bubble app's `https://` URL, for its icon libraries; without it icons
  stay pending), `:max_asset_bytes`, `:asset_timeout`.

  Returns a report: `fetched`, `reused`, `failed` (`[%{url, reason}]`),
  and the counts of `external` (linked to their host, as in Bubble),
  `data`, `invalid` and `skipped` (icons without `app_url`) references,
  which are never fetched.
  """
  @spec fetch(Normalized.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def fetch(%Normalized{} = frontend, dir, opts \\ []) when is_binary(dir) do
    with {:ok, origin} <- app_origin(Keyword.get(opts, :app_url)),
         :ok <- File.mkdir_p(dir) |> dir_result(dir),
         {:ok, store} <- load_store(dir) do
      frontend
      |> references()
      |> Enum.map(&{&1, classify(&1.ref, &1.kind)})
      |> Enum.uniq_by(fn {_ref, class} -> class end)
      |> Enum.reduce(new_run(store), &fetch_one(&1, &2, dir, origin, opts))
      |> finish(dir)
    end
  end

  defp new_run(store) do
    %{
      entries: store.entries,
      report: %{
        "fetched" => 0,
        "reused" => 0,
        "failed" => [],
        "external" => 0,
        "data" => 0,
        "invalid" => 0,
        "skipped" => 0
      }
    }
  end

  defp fetch_one({_reference, {class, _}}, run, _dir, _origin, _opts)
       when class in [:external, :data, :invalid],
       do: bump(run, Atom.to_string(class))

  defp fetch_one({_reference, {:icon, _path}}, run, _dir, nil, _opts), do: bump(run, "skipped")

  defp fetch_one({reference, {class, key}}, run, dir, origin, opts) do
    if Map.has_key?(run.entries, key) do
      bump(run, "reused")
    else
      url = if class == :icon, do: origin <> key, else: key
      allow = allow(class, origin)

      with {:ok, %{bytes: bytes}} <- Assets.fetch_allowed(url, allow, opts),
           {:ok, ext, bytes} <- stored_bytes(reference.kind, bytes),
           {:ok, entry} <- store_file(dir, key, url, reference.kind, ext, bytes) do
        run |> put_in([:entries, key], entry) |> bump("fetched")
      else
        {:error, %{"message" => message}} -> failed(run, url, message)
        {:error, reason} when is_binary(reason) -> failed(run, url, reason)
        _ -> failed(run, url, "asset download failed")
      end
    end
  end

  defp stored_bytes(:image, bytes), do: typed(bytes)

  defp stored_bytes(:icon, bytes),
    do: if(sprite?(bytes), do: {:ok, "svg", bytes}, else: {:error, "not an icon library"})

  # Every hop must stay on Bubble's storage (an icon library: on the app's
  # origin and path, or Bubble's storage).
  defp allow(:bubble, _origin), do: &bubble_https?/1

  defp allow(:icon, origin) do
    fn url ->
      bubble_https?(url) or
        (String.starts_with?(url, origin <> "/") and
           match?({:icon, _}, classify(String.replace_prefix(url, origin, ""), :icon)))
    end
  end

  defp bubble_https?(url),
    do: SafeUrl.https?(url) and not SafeUrl.userinfo?(url) and Files.bubble?(url)

  defp store_file(dir, key, url, kind, ext, bytes) do
    sha = sha256(bytes)
    file = sha <> "." <> ext
    path = Path.join(dir, file)

    with :ok <- write_atomic(path, bytes) do
      {:ok,
       %{
         ref: key,
         url: SafeUrl.safe(url),
         kind: kind,
         file: file,
         sha256: sha,
         content_type: @types[ext],
         size: byte_size(bytes),
         bytes: bytes
       }}
    end
  end

  defp finish(run, dir) do
    index = %{
      "version" => @version,
      "assets" =>
        Map.new(run.entries, fn {ref, e} ->
          {ref,
           %{
             "url" => e.url,
             "kind" => Atom.to_string(e.kind),
             "file" => e.file,
             "sha256" => e.sha256,
             "content_type" => e.content_type,
             "size" => e.size
           }}
        end)
    }

    body = index |> CanonicalJson.ordered() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")

    case write_atomic(Path.join(dir, @index), body) do
      :ok ->
        report = Map.update!(run.report, "failed", &Enum.sort_by(&1, fn f -> f["url"] end))
        {:ok, Map.put(report, "stored", map_size(run.entries))}

      {:error, _} = error ->
        error
    end
  end

  defp write_atomic(path, bytes) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, Error.new(:invalid_input, "asset store write failed", %{reason: reason})}
    end
  end

  defp dir_result(:ok, _dir), do: :ok

  defp dir_result({:error, reason}, dir),
    do:
      {:error,
       Error.new(:invalid_input, "asset store directory could not be created", %{
         dir: dir,
         reason: reason
       })}

  defp bump(run, key), do: update_in(run, [:report, key], &(&1 + 1))

  defp failed(run, url, reason) do
    update_in(run, [:report, "failed"], &[%{"url" => SafeUrl.safe(url), "reason" => reason} | &1])
  end

  defp app_origin(nil), do: {:ok, nil}

  defp app_origin(url) when is_binary(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil} = uri}
      when is_binary(host) and host != "" ->
        port = if uri.port in [nil, 443], do: "", else: ":#{uri.port}"
        {:ok, "https://" <> String.downcase(host) <> port}

      _ ->
        {:error,
         Error.new(:invalid_input, "app_url must be an https:// URL without credentials", %{})}
    end
  end

  defp app_origin(_url),
    do: {:error, Error.new(:invalid_input, "app_url must be an https:// URL", %{})}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
