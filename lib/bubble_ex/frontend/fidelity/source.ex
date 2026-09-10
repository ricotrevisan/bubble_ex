defmodule BubbleEx.Frontend.Fidelity.Source do
  @moduledoc false

  alias BubbleEx.Error
  alias BubbleEx.Frontend.Payload

  # Bubble's editor enum values, verified against the generated Buildprint schema
  # and the corrected tiptap-plugin/83jop source on 2026-09-10.
  @input_formats ~w(text email password int_number float_number geographic_address us_phone
    percentage currency date date_2 numerical_ref credit_card_number credit_card_cvc
    credit_card_exp_month credit_card_exp_year appname_validate)

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(value) do
    case invalid_nodes(value) do
      [] ->
        :ok

      nodes ->
        {:error,
         Error.new(:invalid_input, "frozen source contains invalid control definitions", %{
           nodes: nodes
         })}
    end
  end

  defp invalid_nodes(value) when is_map(value) do
    own =
      case Payload.type(value) do
        "Input" ->
          invalid_format(value, "content_format", @input_formats, "text") ++
            invalid_content(value)

        "DateInput" ->
          invalid_format(value, "input_type", ~w(date time date_time), "date")

        _ ->
          []
      end

    own ++ Enum.flat_map(Map.values(value), &invalid_nodes/1)
  end

  defp invalid_nodes(value) when is_list(value), do: Enum.flat_map(value, &invalid_nodes/1)
  defp invalid_nodes(_value), do: []

  defp invalid_content(node) do
    format = Payload.prop(node, "content_format") || "text"
    content = Payload.prop(node, "content")
    numeric? = format in ~w(int_number float_number percentage currency)
    text? = format in ~w(text email password us_phone numerical_ref)

    if (numeric? and is_binary(content)) or (text? and is_number(content)) do
      [
        %{
          id: Payload.bubble_id(node),
          property: "content",
          expected: if(numeric?, do: "number", else: "text")
        }
      ]
    else
      []
    end
  end

  defp invalid_format(node, property, accepted, default) do
    value = Payload.prop(node, property) || default

    if value in accepted do
      []
    else
      [%{id: Payload.bubble_id(node), property: property, value: value}]
    end
  end
end
