defmodule BubbleEx.Frontend do
  @moduledoc """
  Export one modern-responsive Bubble app version as portable HTML, CSS,
  downloaded assets, binding metadata, and explicit findings.

  Three public seams:

    * `normalize/2` — decoded app payload → `%BubbleEx.Frontend.Normalized{}`
    * `export/3` — normalized model → on-disk package + `%Export.Result{}`
    * `export_payload/3` — normalize then export

  `BubbleEx.export_frontend/3` fetches one named app version and calls
  `export_payload/3`. `BubbleEx.AppTree` is a separate product.
  """

  alias BubbleEx.{Error, Telemetry}

  alias BubbleEx.Frontend.{
    Auth,
    EditorGeometry,
    Export,
    Fetch,
    InitialState,
    Normalize,
    Normalized
  }

  @type normalize_option :: {atom(), term()}
  @type export_option ::
          {:pages, :all | [String.t()]}
          | {:fallback, boolean()}
          | {:force, boolean()}
          | {:secret_scan_adapter, module()}
          | {:asset_timeout, pos_integer()}
          | {:max_asset_bytes, pos_integer()}
          | {:asset_access, :public | :same_origin}

  @doc """
  Pure, deterministic normalization of a decoded app payload.

  Always walks the full app version. Unknown option keys are ignored. Does
  not scan for secrets.

  ## Options

    * `:geometry` - `:editor` reads the payload's layout as Bubble editor
      JSON (a `.bubble` export, a Buildprint v5 workspace), `:runtime` as
      Bubble's runtime payload (`BubbleEx.Frontend.EditorGeometry`).
      Default: `:editor` when the payload carries the editor mark
      (`read_bubble_export/1`, `decode_bubble_export/1` and
      `BubbleEx.Buildprint.V5.load/2` set it), else `:runtime`.

  Returns `{:ok, %Normalized{}}` or `{:error, %BubbleEx.Error{}}` with kind
  `:invalid_input`, `:parse_failed`, or `:unsupported_renderer`.
  """
  @spec normalize(term(), keyword()) :: {:ok, Normalized.t()} | {:error, Error.t()}
  def normalize(payload, opts \\ []) do
    Telemetry.span([:frontend, :normalize], %{}, fn ->
      result = Normalize.run(payload, opts)
      {result, normalize_stop(result)}
    end)
  end

  @doc """
  Reads a `.bubble` export (Bubble's editor JSON) from `path`: the decoded
  app, marked as editor JSON (`BubbleEx.Frontend.EditorGeometry.mark/1`)
  so `normalize/2` reads its layout as Bubble does.

  Returns `{:ok, app}` or `{:error, %BubbleEx.Error{}}` with kind
  `:invalid_input` (unreadable file) or `:parse_failed` (not a JSON object).
  """
  @spec read_bubble_export(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def read_bubble_export(path) when is_binary(path) do
    case File.read(path) do
      {:ok, json} ->
        decode_bubble_export(json)

      {:error, reason} ->
        {:error, Error.new(:invalid_input, "cannot read the .bubble export", %{reason: reason})}
    end
  end

  @doc "`read_bubble_export/1` for the export's JSON text."
  @spec decode_bubble_export(binary()) :: {:ok, map()} | {:error, Error.t()}
  def decode_bubble_export(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, app} when is_map(app) -> {:ok, EditorGeometry.mark(app)}
      _ -> {:error, Error.new(:parse_failed, "a .bubble export must be a JSON object", %{})}
    end
  end

  @doc """
  Writes a portable frontend package from a normalized model.

  Always secret-scans the source payload. A leaked-credential finding returns
  `:export_blocked` and writes nothing.
  """
  @spec export(Normalized.t(), String.t(), keyword()) ::
          {:ok, Export.Result.t()} | {:error, Error.t()}
  def export(model, out_dir, opts \\ [])

  def export(%Normalized{} = model, out_dir, opts) when is_binary(out_dir) do
    Telemetry.span([:frontend, :export], %{out_dir: out_dir}, fn ->
      result = Export.run(model, out_dir, opts)
      {result, export_stop(result)}
    end)
  end

  def export(_model, _out_dir, _opts) do
    {:error, Error.new(:invalid_input, "export/3 expects a normalized frontend model", %{})}
  end

  @doc """
  Normalizes a decoded payload and writes the export package.
  """
  @spec export_payload(term(), String.t(), keyword()) ::
          {:ok, Export.Result.t()} | {:error, Error.t()}
  def export_payload(payload, out_dir, opts \\ []) do
    if Enum.any?([:username, :password, :session_cookie], &Keyword.has_key?(opts, &1)) do
      {:error,
       Error.new(
         :invalid_input,
         "export_payload/3 does not accept transport authentication without a fetched origin",
         %{}
       )}
    else
      with {:ok, model} <- normalize(payload, []) do
        export(model, out_dir, opts)
      end
    end
  end

  @doc false
  @spec export_fetched(term(), String.t(), keyword(), Fetch.Context.t()) ::
          {:ok, Export.Result.t()} | {:error, Error.t()}
  def export_fetched(payload, out_dir, opts, %Fetch.Context{} = context) do
    context = %{context | snapshot_at: context.snapshot_at || DateTime.utc_now()}
    taints = Auth.taints(context.auth)

    if tainted?(out_dir, taints) do
      {:error,
       Error.new(:export_blocked, "export blocked by credential-tainted output path", %{})}
    else
      with {:ok, model} <- normalize(payload, credential_taints: taints) do
        model = InitialState.project(model, context)

        export(model, out_dir, fetched_options(opts, context, taints))
      end
    end
  end

  defp fetched_options(opts, context, taints) do
    initial_user = if InitialState.anonymous?(context), do: "anonymous", else: "unknown"

    opts
    |> Keyword.put(:fetch_context, context)
    |> Keyword.put(:credential_taints, taints)
    |> Keyword.put(:initial_user, initial_user)
    |> Keyword.put(:snapshot_at, DateTime.to_iso8601(context.snapshot_at))
  end

  defp tainted?(value, taints) do
    Enum.any?(taints, &(is_binary(&1) and &1 != "" and String.contains?(value, &1)))
  end

  defp normalize_stop({:ok, model}),
    do: %{page_count: length(model.pages), error: nil}

  defp normalize_stop({:error, error}), do: %{page_count: 0, error: error}

  defp export_stop({:ok, result}),
    do: %{file_count: length(result.files), error: nil}

  defp export_stop({:error, error}), do: %{file_count: 0, error: error}
end
