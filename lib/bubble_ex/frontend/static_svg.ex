defmodule BubbleEx.Frontend.StaticSvg do
  @moduledoc false

  @number ~r/^-?(?:\d+(?:\.\d+)?|\.\d+)$/
  @path ~r/^[0-9eE.,+\-\sMmZzLlHhVvCcSsQqTtAa]+$/

  @spec parse(term()) :: {:ok, String.t()} | :unsupported
  def parse(html) when is_binary(html) and byte_size(html) <= 100_000 do
    with {:ok, nodes} <- Floki.parse_fragment(html),
         [{"svg", attributes, children}] <- nonblank(nodes),
         true <- safe_attributes?(attributes, :svg),
         paths when paths != [] <- nonblank(children),
         true <- Enum.all?(paths, &safe_path?/1) do
      attributes = Enum.map(attributes, &restore_attribute_case/1)
      {:ok, Floki.raw_html([{"svg", attributes, paths}])}
    else
      _ -> :unsupported
    end
  end

  def parse(_html), do: :unsupported

  defp nonblank(nodes) do
    Enum.reject(nodes, fn
      text when is_binary(text) -> String.trim(text) == ""
      _ -> false
    end)
  end

  defp safe_path?({"path", attributes, children}) do
    nonblank(children) == [] and List.keymember?(attributes, "d", 0) and
      safe_attributes?(attributes, :path)
  end

  defp safe_path?(_), do: false

  defp safe_attributes?(attributes, kind) do
    Enum.all?(attributes, fn {key, value} -> safe_attribute?(key, value, kind) end)
  end

  defp safe_attribute?("xmlns", "http://www.w3.org/2000/svg", :svg), do: true
  defp safe_attribute?("d", value, :path), do: Regex.match?(@path, value)

  defp safe_attribute?("viewbox", value, :svg) do
    values = String.split(value, ~r/[\s,]+/, trim: true)
    length(values) == 4 and Enum.all?(values, &Regex.match?(@number, &1))
  end

  defp safe_attribute?(key, value, _kind)
       when key in [
              "width",
              "height",
              "stroke-width",
              "stroke-miterlimit",
              "opacity",
              "fill-opacity",
              "stroke-opacity"
            ],
       do: Regex.match?(@number, value)

  defp safe_attribute?(key, value, _kind) when key in ["fill", "stroke"] do
    value in ["none", "currentColor", "black", "white", "transparent"] or
      Regex.match?(~r/^#[0-9A-Fa-f]{3}(?:[0-9A-Fa-f]{3})?$/, value)
  end

  defp safe_attribute?("stroke-linecap", value, _kind), do: value in ~w(butt round square)
  defp safe_attribute?("stroke-linejoin", value, _kind), do: value in ~w(miter round bevel)

  defp safe_attribute?(key, value, _kind) when key in ["fill-rule", "clip-rule"],
    do: value in ~w(nonzero evenodd)

  defp safe_attribute?("class", value, _kind), do: Regex.match?(~r/^[A-Za-z0-9_\-\s]+$/, value)
  defp safe_attribute?(_key, _value, _kind), do: false

  defp restore_attribute_case({"viewbox", value}), do: {"viewBox", value}
  defp restore_attribute_case(attribute), do: attribute
end
