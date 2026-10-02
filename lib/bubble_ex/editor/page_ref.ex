defmodule BubbleEx.Editor.PageRef do
  @moduledoc """
  A page's stable editor map key and Bubble ID, bound to an app version.

  Names are display attributes, never editor paths. `source` records the runtime
  URL and JSON pointer used for discovery; it is not an access grant. References
  must be rediscovered after a rename or replacement.
  """

  alias BubbleEx.Editor.Target
  alias BubbleEx.Error

  @enforce_keys [:appname, :version, :key, :id, :name, :path, :source]
  defstruct [:appname, :version, :key, :id, :name, :path, :source]

  @type t :: %__MODULE__{
          appname: String.t(),
          version: String.t(),
          key: String.t(),
          id: String.t(),
          name: String.t(),
          path: [String.t()],
          source: map()
        }

  @doc false
  @spec validate(t(), Target.t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = ref, %Target{} = target) do
    if ref.appname == target.appname and ref.version == target.version and
         segment?(ref.key) and segment?(ref.id) and is_binary(ref.name) and ref.name != "" and
         ref.path == ["%p3", ref.key] do
      :ok
    else
      {:error,
       Error.new(:invalid_input, "page reference does not match the editor target", %{
         reason: :invalid_page_reference
       })}
    end
  end

  def validate(_ref, _target),
    do: {:error, Error.new(:invalid_input, "a discovered page reference is required")}

  @doc false
  @spec matches?(t(), term()) :: boolean()
  def matches?(ref, page) when is_map(page) do
    matches_fields?(page, ["id", "%id"], ref.id) and
      matches_fields?(page, ["name", "%nm"], ref.name) and
      matches_fields?(page, ["type", "%x"], "Page")
  end

  def matches?(_ref, _page), do: false

  defp matches_fields?(map, keys, expected) do
    values = keys |> Enum.filter(&Map.has_key?(map, &1)) |> Enum.map(&Map.fetch!(map, &1))
    values != [] and Enum.all?(values, &(&1 == expected))
  end

  defp segment?(value) when is_binary(value), do: Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, value)
  defp segment?(_value), do: false
end
