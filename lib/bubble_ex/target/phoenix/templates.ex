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
