defmodule BubbleEx.Target.Phoenix.Templates do
  @moduledoc false
  # The EEx templates of `BubbleEx.Target.Phoenix` (templates/**/*.eex),
  # compiled into `render/2` clauses keyed by their path relative to
  # templates/ without the `.eex` suffix.

  require EEx

  @root Path.join(__DIR__, "templates")

  @templates @root
             |> Path.join("**/*.eex")
             |> Path.wildcard()
             |> Enum.sort()

  for file <- @templates do
    @external_resource file
    name = file |> Path.relative_to(@root) |> String.replace_suffix(".eex", "")
    compiled = EEx.compile_file(file)

    def render(unquote(name), var!(assigns)) when is_map(var!(assigns)) do
      unquote(compiled)
    end
  end

  @doc false
  # Elixir source of a term for the templates, never truncated
  # (`inspect/1` cuts strings at 4096 characters).
  @spec source(term()) :: String.t()
  def source(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  @doc false
  # A string literal inside a HEEx `{…}` expression: braces and `<` as hex
  # escapes (HEEx counts braces, strings included; EEx reads `<%`).
  @spec heex_literal(String.t()) :: String.t()
  def heex_literal(value) do
    value
    |> source()
    |> String.replace("{", "\\x7B")
    |> String.replace("}", "\\x7D")
    |> String.replace("<", "\\x3C")
  end

  @doc false
  @spec names() :: [String.t()]
  def names,
    do:
      Enum.map(@templates, &(&1 |> Path.relative_to(@root) |> String.replace_suffix(".eex", "")))

  # Recompile when a template is added or removed.
  @doc false
  def __mix_recompile__? do
    @root |> Path.join("**/*.eex") |> Path.wildcard() |> Enum.sort() != @templates
  end
end
