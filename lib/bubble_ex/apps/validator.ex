defmodule BubbleEx.Apps.Validator do
  @moduledoc """
  Validation module for Bubble.io application inputs.

  Provides validation functions for URLs, bubble IDs, and other inputs
  used when interacting with Bubble applications.
  """

  alias BubbleEx.Error

  @doc """
  Validates input which can be either a URL or bubble_id.
  """
  @spec validate_input(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_input(input) when is_binary(input) do
    cond do
      valid_slug?(input) && !contains_reserved_chars?(input) ->
        {:ok, "https://#{input}.bubbleapps.io"}

      !valid_slug?(input) && contains_reserved_chars?(input) ->
        {:ok, input}

      String.contains?(input, ".") ->
        {:ok, ensure_url_scheme(input)}

      true ->
        {:error,
         Error.new(:invalid_input, "input does not look like a Bubble app slug or URL", %{
           input: input
         })}
    end
  end

  def validate_input(input) do
    {:error, Error.new(:invalid_input, "input must be a string", %{input: input})}
  end

  @doc """
  Validates that a string is a properly formatted bubble_id.
  """
  @spec validate_bubble_id(term()) :: :ok | {:error, Error.t()}
  def validate_bubble_id(bubble_id) when is_binary(bubble_id) do
    if valid_slug?(bubble_id) do
      :ok
    else
      {:error, invalid_bubble_id_error(bubble_id)}
    end
  end

  def validate_bubble_id(bubble_id) do
    {:error, invalid_bubble_id_error(bubble_id)}
  end

  defp invalid_bubble_id_error(bubble_id) do
    Error.new(:invalid_input, "value is not a valid bubble_id format", %{bubble_id: bubble_id})
  end

  @doc """
  Checks if a string is a valid slug format (lowercase alphanumeric with hyphens).
  """
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    regex = ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
    Regex.match?(regex, slug)
  end

  def valid_slug?(_), do: false

  @doc """
  Checks if a string contains characters that would be URL encoded.
  """
  @spec contains_reserved_chars?(String.t()) :: boolean()
  def contains_reserved_chars?(string) when is_binary(string) do
    encoded = URI.encode(string)
    string != encoded
  end

  def contains_reserved_chars?(_), do: false

  defp ensure_url_scheme(input) do
    case URI.parse(input) do
      %URI{scheme: scheme} when is_binary(scheme) -> input
      _ -> "https://#{input}"
    end
  end
end
