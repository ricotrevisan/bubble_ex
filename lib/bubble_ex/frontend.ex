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
  alias BubbleEx.Frontend.{Auth, Export, Fetch, Normalize, Normalized}

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

  Always walks the full app version. Takes no v1 options; unknown keys are
  ignored. Does not scan for secrets.

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
    taints = Auth.taints(context.auth)

    if tainted?(out_dir, taints) do
      {:error,
       Error.new(:export_blocked, "export blocked by credential-tainted output path", %{})}
    else
      with {:ok, model} <- normalize(payload, credential_taints: taints) do
        internal_opts =
          opts
          |> Keyword.put(:fetch_context, context)
          |> Keyword.put(:credential_taints, taints)

        export(model, out_dir, internal_opts)
      end
    end
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
