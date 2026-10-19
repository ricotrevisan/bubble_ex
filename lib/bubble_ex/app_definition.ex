defmodule BubbleEx.AppDefinition do
  @moduledoc """
  Imports a local Bubble app definition and its stack-neutral data model.

  `load/2` accepts a `.bubble`/JSON file (regardless of extension), a
  Buildprint v5 workspace root, or its `.buildprint` directory. It reuses
  `BubbleEx.Frontend.read_bubble_export/1` and `BubbleEx.Buildprint.V5.load/2`,
  preserving the editor-geometry mark without normalizing the frontend or
  compiling workflows. Legacy split-export directories are not supported.

  A Buildprint import reads the stored SQLite snapshot, not unapplied `.ts`
  edits; it never parses or evaluates TypeScript or writes to the workspace.
  V5's redactions mean it is not a lossless credential backup. A `.bubble`
  file's raw `app` map may contain secrets: loading does not secret-scan it.
  Keep imported definitions private. Source metadata contains no local paths.

  Importing a definition is not execution parity or record migration.
  """

  alias BubbleEx.{Diagnostic, Error, Frontend, Model}
  alias BubbleEx.Buildprint.V5

  @enforce_keys [:app, :model, :source]
  defstruct [:app, :model, :source, diagnostics: []]

  @type source :: %{
          kind: :bubble_export | :buildprint_v5,
          geometry: :editor,
          metadata: map()
        }
  @type t :: %__MODULE__{
          app: map(),
          model: Model.t(),
          source: source(),
          diagnostics: [Diagnostic.t()]
        }

  @doc """
  Loads a local app definition with normalized reader and model diagnostics.

  The path must be a nonempty binary. Options must be a keyword list; the
  only supported option is `:max_index_bytes`, a positive integer passed to
  the V5 reader (default 512 MB). File imports have empty source metadata;
  workspace imports retain versions, counts and snapshot verification data.

  Returns `{:error, %BubbleEx.Error{kind: :invalid_input}}` for invalid
  arguments, missing paths or unsupported directories. Detected V5
  workspaces delegate errors without falling back to another format.
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def load(path, opts \\ [])

  def load(path, opts) when is_binary(path) and byte_size(path) > 0 and is_list(opts) do
    with :ok <- validate_options(opts) do
      cond do
        V5.workspace?(path) -> load_workspace(path, opts)
        File.regular?(path) -> load_file(path)
        true -> invalid_input("expected a local app JSON file or Buildprint v5 workspace")
      end
    end
  end

  def load(_, _), do: invalid_input("expected a nonempty path and keyword options")

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn
           {:max_index_bytes, limit} when is_integer(limit) and limit > 0 -> true
           _ -> false
         end) do
      :ok
    else
      invalid_input("only :max_index_bytes with a positive integer is supported")
    end
  end

  defp load_workspace(path, opts) do
    with {:ok, reader} <- V5.load(path, opts) do
      {:ok,
       %__MODULE__{
         app: reader.app,
         model: reader.model,
         source: %{
           kind: :buildprint_v5,
           geometry: :editor,
           metadata:
             Map.take(Map.from_struct(reader), [
               :format_version,
               :schema_version,
               :counts,
               :symbol_counts,
               :snapshot
             ])
         },
         diagnostics: Diagnostic.normalize(reader.diagnostics ++ reader.model.diagnostics)
       }}
    end
  end

  defp load_file(path) do
    with {:ok, app} <- Frontend.read_bubble_export(path),
         {:ok, model} <- Model.build(app) do
      {:ok,
       %__MODULE__{
         app: app,
         model: model,
         source: %{kind: :bubble_export, geometry: :editor, metadata: %{}},
         diagnostics: Diagnostic.normalize(model.diagnostics)
       }}
    end
  end

  defp invalid_input(message), do: {:error, Error.new(:invalid_input, message)}
end
