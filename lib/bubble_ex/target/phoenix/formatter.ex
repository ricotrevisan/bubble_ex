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
  (`render/2` returns the error), another patch is allowed with a warning
  and recorded in the manifest (`inputs.phoenix_live_view`), since a fresh
  render may then differ from one made at the pin (hashes, the generated
  app's `mix format --check-formatted`).

  `.ex` formatting follows the running Elixir version, which no pin
  covers: two Elixir versions may format the same source differently.
  One known difference is handled: Elixir 1.18 can leave a line one
  column over the limit when only its trailing comma overflows, which
  1.19 and later break; the generator breaks it too (WTF-543), so a
  render made on 1.18 stays formatted on 1.19 and later.
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

  # `mix format`'s default, which the generated .formatter.exs keeps.
  @line_length 98

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
  # `render/2`'s guard: refuses a mismatch; for another patch release warns
  # once per VM and returns the loaded version, which `render/2` records
  # in the manifest (`inputs.phoenix_live_view`); `{:ok, nil}` at the pin.
  @spec ensure_live_view(String.t() | nil) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def ensure_live_view(loaded \\ loaded_live_view()) do
    case live_view_check(loaded) do
      :ok ->
        {:ok, nil}

      {:warn, message} ->
        key = {__MODULE__, :warned}

        if not :persistent_term.get(key, false) do
          :persistent_term.put(key, true)
          Logger.warning(message)
        end

        {:ok, loaded}

      error ->
        error
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
        elixir(source)

      true ->
        source
    end
  end

  @doc false
  # Elixir source as the generated app's `mix format` leaves it, on the
  # running Elixir and on 1.19 and later (`fit/1`).
  @spec elixir(String.t()) :: binary()
  def elixir(source), do: source |> format_elixir() |> fit()

  defp format_elixir(source),
    do:
      source
      |> Code.format_string!(
        locals_without_parens: @locals_without_parens,
        line_length: @line_length
      )
      |> IO.iodata_to_binary()
      |> Kernel.<>("\n")

  # Elixir before 1.19 can leave a line one column over the line length
  # when only its trailing comma overflows (`ApiClients.string([env["…"]]),`
  # in a list); 1.19 and later break it ("Ensure the formatter does not go
  # over the specified limit in certain corner cases", 1.19.0), so a render
  # made on 1.18 failed the generated app's `mix format --check-formatted`
  # on a newer Elixir (WTF-543). Each such line is broken after its leading
  # openers, as 1.19 does, and formatted again: the formatter keeps a
  # newline after an opening bracket. A break that changes the code (a line
  # of a string or heredoc) is not taken. On 1.19 and later there is no
  # such line, so this only scans.
  defp fit(formatted), do: fit(formatted, nil)

  defp fit(formatted, quoted) do
    lines = String.split(formatted, "\n")

    case corners(lines) do
      [] ->
        formatted

      corners ->
        quoted = quoted || strip(formatted)

        Enum.find_value(corners, formatted, &break_corner(&1, lines, length(corners), quoted))
    end
  end

  # The formatted source with the corner broken, fitted again; nil when
  # the break changes the code or the formatter does not keep it.
  defp break_corner({i, head, rest}, lines, count, quoted) do
    broken = lines |> List.replace_at(i, head <> "\n" <> rest) |> Enum.join("\n")

    with ^quoted <- strip(broken),
         fitted = format_elixir(broken),
         true <- length(corners(String.split(fitted, "\n"))) < count do
      fit(fitted, quoted)
    else
      _ -> nil
    end
  end

  # The lines only their trailing comma takes over the line length, split
  # after their leading openers.
  defp corners(lines) do
    for {line, i} <- Enum.with_index(lines),
        String.length(line) == @line_length + 1,
        String.ends_with?(line, ","),
        not String.starts_with?(String.trim_leading(line), "#"),
        [_, head, rest] <- [Regex.run(~r/\A(\s*[^(\[{]*?(?:[(\[{]|%\{)+)(.+)\z/, line)],
        do: {i, head, rest}
  end

  # The code without positions (a break moves lines, never the code), or
  # nil when it does not parse.
  defp strip(source) do
    case Code.string_to_quoted(source, columns: false, token_metadata: false) do
      {:ok, quoted} -> Macro.prewalk(quoted, &Macro.update_meta(&1, fn _ -> [] end))
      {:error, _} -> nil
    end
  end
end
