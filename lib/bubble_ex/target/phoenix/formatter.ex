defmodule BubbleEx.Target.Phoenix.Formatter do
  @moduledoc """
  Formats the files `BubbleEx.Target.Phoenix.render/2` writes, before they
  are hashed into `.wtf/generated.json`: HEEx with
  `Phoenix.LiveView.HTMLFormatter`, Elixir with `Code.format_string!/2`.

  HEEx formatting changes in LiveView patch releases (1.2.11 changed which
  expressions it migrates), so the rendered bytes are a function of the
  loaded LiveView. bubble_ex accepts `~> 1.2.12` so owner apps can take
  patch and security releases; `live_view_check/1` compares the loaded
  version with the generator's pin (`live_view_version/0`, the version the
  generated `mix.exs` pins): another minor or major version is refused
  (`render/2` returns the error), another patch is allowed with a warning,
  since a fresh render may then differ from one made at the pin (hashes,
  the generated app's `mix format --check-formatted`).

  `.ex` formatting follows the running Elixir version, which no pin
  covers: two Elixir versions may format the same source differently.
  """

  require Logger

  alias BubbleEx.Error

  @locals_file Path.join(__DIR__, "formatter_locals.exs")
  @external_resource @locals_file
  {locals, _} = Code.eval_file(@locals_file)
  @locals_without_parens locals

  # The LiveView the generated app pins and the HEEx formatting is checked
  # against (scripts/phoenix_compile_check.sh). Bump it with mix.exs.
  @live_view "1.2.12"

  @doc "The LiveView version the generator pins (`== <version>` in the generated `mix.exs`)."
  @spec live_view_version() :: String.t()
  def live_view_version, do: @live_view

  @doc """
  Checks the loaded LiveView (`Application.spec(:phoenix_live_view, :vsn)`,
  or `loaded`) against `live_view_version/0`: `:ok` when equal, `{:warn,
  message}` for another patch release, `{:error, error}` for another
  minor or major version or none loaded.
  """
  @spec live_view_check(String.t() | nil) :: :ok | {:warn, String.t()} | {:error, Error.t()}
  def live_view_check(loaded \\ loaded_live_view()) do
    with {:ok, pin} <- Version.parse(@live_view),
         {:ok, have} <- parse(loaded) do
      cond do
        Version.compare(have, pin) == :eq ->
          :ok

        {have.major, have.minor} == {pin.major, pin.minor} ->
          {:warn,
           "phoenix_live_view #{loaded} is loaded; the generator pins #{@live_view}. HEEx " <>
             "formatting can change in patch releases, so this render's .heex files may " <>
             "differ from one made at the pin (their generated.json hashes, the generated " <>
             "app's mix format --check-formatted)"}

        true ->
          mismatch(loaded)
      end
    else
      _ -> mismatch(loaded)
    end
  end

  @doc false
  # `render/2`'s guard: refuses a mismatch, warns once per VM for a patch.
  @spec ensure_live_view() :: :ok | {:error, Error.t()}
  def ensure_live_view do
    case live_view_check() do
      {:warn, message} ->
        key = {__MODULE__, :warned}

        unless :persistent_term.get(key, false) do
          :persistent_term.put(key, true)
          Logger.warning(message)
        end

        :ok

      other ->
        other
    end
  end

  defp loaded_live_view do
    case Application.spec(:phoenix_live_view, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  defp parse(nil), do: :error
  defp parse(version), do: Version.parse(version)

  defp mismatch(loaded),
    do:
      {:error,
       Error.new(
         :invalid_input,
         "phoenix_live_view #{loaded || "(not loaded)"} cannot format the rendered HEEx: " <>
           "the generator pins #{@live_view}",
         %{loaded: loaded, pinned: @live_view}
       )}

  @spec format(String.t(), binary()) :: binary()
  def format(path, source) do
    cond do
      String.ends_with?(path, ".heex") ->
        Phoenix.LiveView.HTMLFormatter.format(source, extension: ".heex", file: path)

      Path.extname(path) in [".ex", ".exs"] ->
        source
        |> Code.format_string!(locals_without_parens: @locals_without_parens)
        |> IO.iodata_to_binary()
        |> Kernel.<>("\n")

      true ->
        source
    end
  end
end
