defmodule BubbleEx.Load.Storage do
  @moduledoc """
  A target's file storage, as `BubbleEx.Load` copies Bubble files into it
  (`BubbleEx.Load.Files.copy/4`). Passed as `{module, config}`.

  `put/3` stores a file and returns the reference its fields will hold: a
  URL for a public file; for a private one, a reference the app resolves
  behind its own authorization (never a public URL). It must be idempotent
  (the same file again returns the same reference) and must honour
  `visibility`. `verify/3` re-reads what was stored and checks it against
  the SHA-256 and size; a file counts as copied only when it passes.
  `identity/1` names the storage without credentials; it is part of the
  loader's ledger key, so a ledger never claims files copied to another
  storage.

  Copied files keep their names and extensions (`.html`, `.svg`, …), and
  Bubble apps accept uploads from their users: **serve public files from a
  separate origin** (a bucket or CDN domain), or else with
  `Content-Disposition: attachment` and `X-Content-Type-Options: nosniff`,
  never inline from the app's own origin (stored XSS).

  `BubbleEx.Load.Storage.Local` stores files in a directory. Object stores
  (S3, Tigris, R2) implement the same callbacks.
  """

  alias BubbleEx.Error

  @type meta :: %{
          sha256: String.t(),
          bytes: non_neg_integer() | nil,
          name: String.t(),
          content_type: String.t() | nil,
          visibility: :public | :private
        }

  @callback put(config :: term(), meta(), source :: Path.t()) ::
              {:ok, String.t()} | {:error, Error.t()}
  @callback verify(config :: term(), reference :: String.t(), meta()) :: :ok | {:error, Error.t()}
  @callback identity(config :: term()) :: String.t()
end

defmodule BubbleEx.Load.Storage.Local do
  @moduledoc """
  File storage in a local directory (development, tests, or a volume
  served by a separate file origin). Content-addressed: a file is stored
  at `<root>/<visibility>/<sha256>/<name>`.

  References: a public file's is `<public_url>/<sha256>/<name>`; a private
  file's is `private/<sha256>/<name>`, a key the app resolves through its
  own authorized route. `<root>/private` and its directories are created
  `0700` and its files `0600` (written to a temporary name inside the
  `0700` directory, then renamed); it must never be served as is.

      storage =
        BubbleEx.Load.Storage.Local.new(
          root: "/srv/uploads",
          public_url: "https://files.example.com"
        )

  `public_url` should be a **separate origin** from the app (see
  `BubbleEx.Load.Storage` on stored XSS). If the app itself must serve
  `<root>/public`, it must add `Content-Disposition: attachment` and
  `X-Content-Type-Options: nosniff` to those responses (for
  `Plug.Static`, its `:headers` option). The generated Phoenix project
  serves `<root>` itself, safely (WTF-415): its `<Web>.Uploads` and
  `<Web>.UploadsController` (see `BubbleEx.Target.Phoenix`), configured
  with this `root` and `public_url`; private files stay off there until
  the owner opts in.
  """

  @behaviour BubbleEx.Load.Storage

  alias BubbleEx.Error
  alias BubbleEx.Load.Export

  @enforce_keys [:root, :public_url]
  defstruct [:root, :public_url]

  @type t :: %__MODULE__{root: Path.t(), public_url: String.t()}

  @doc "`{BubbleEx.Load.Storage.Local, config}` for `root:` and `public_url:`."
  @spec new(keyword()) :: {module(), t()}
  def new(opts) do
    {__MODULE__,
     %__MODULE__{
       root: opts |> Keyword.fetch!(:root) |> Path.expand(),
       public_url: opts |> Keyword.fetch!(:public_url) |> String.trim_trailing("/")
     }}
  end

  @impl true
  def identity(%__MODULE__{} = s), do: "local:#{s.root}|#{s.public_url}"

  @impl true
  def put(%__MODULE__{} = s, meta, source) do
    path = path(s, meta)

    if File.exists?(path) and verify_path(path, meta) == :ok,
      do: {:ok, reference(s, meta)},
      else: store(s, meta, source, path)
  end

  defp store(s, meta, source, path) do
    make_dirs(s, meta, Path.dirname(path))
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    case File.cp(source, tmp) do
      :ok ->
        File.chmod!(tmp, if(meta.visibility == :private, do: 0o600, else: 0o644))
        File.rename!(tmp, path)
        {:ok, reference(s, meta)}

      {:error, reason} ->
        File.rm(tmp)
        {:error, Error.new(:request_failed, "cannot store the file", %{reason: reason})}
    end
  end

  # Private directories are 0700 from the root down.
  defp make_dirs(s, %{visibility: :private}, dir) do
    base = Path.join(s.root, "private")
    File.mkdir_p!(s.root)

    for d <- [base, Path.dirname(dir), dir] |> Enum.uniq(), not File.dir?(d) do
      File.mkdir_p!(d)
      File.chmod!(d, 0o700)
    end

    File.chmod!(base, 0o700)
  end

  defp make_dirs(_s, _meta, dir), do: File.mkdir_p!(dir)

  @impl true
  def verify(%__MODULE__{} = s, reference, meta) do
    if reference == reference(s, meta),
      do: verify_path(path(s, meta), meta),
      else: failed(:reference_mismatch)
  end

  defp verify_path(path, meta) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         true <- is_nil(meta.bytes) or size == meta.bytes,
         {:ok, sha} <- Export.file_sha256(path),
         true <- sha == meta.sha256 do
      :ok
    else
      _ -> failed(:storage_checksum_mismatch)
    end
  end

  defp failed(reason),
    do: {:error, Error.new(:request_failed, "the stored file does not verify", %{reason: reason})}

  defp path(s, meta),
    do: Path.join([s.root, Atom.to_string(meta.visibility), meta.sha256, meta.name])

  defp reference(_s, %{visibility: :private} = meta), do: "private/#{meta.sha256}/#{meta.name}"
  defp reference(s, meta), do: "#{s.public_url}/#{meta.sha256}/#{meta.name}"
end
