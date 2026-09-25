defmodule BubbleEx.Secrets.Output do
  @moduledoc false

  # Incremental NDJSON parsing. No full stdout binary or list of all lines.
  defstruct pending: "",
            findings: [],
            bytes: 0,
            count: 0,
            max_bytes: 8_000_000,
            max_line: 1_000_000,
            max_findings: 10_000

  def new(opts) do
    %__MODULE__{
      max_bytes: Keyword.get(opts, :max_output_bytes, 8_000_000),
      max_line: Keyword.get(opts, :max_line_bytes, 1_000_000),
      max_findings: Keyword.get(opts, :max_findings, 10_000)
    }
  end

  def push(state, chunk, enhance) do
    bytes = state.bytes + byte_size(chunk)

    if bytes > state.max_bytes do
      {:error, :output_limit}
    else
      consume(%{state | bytes: bytes}, chunk, enhance)
    end
  end

  def finish(state, enhance) do
    with {:ok, state} <- line(state, state.pending, enhance) do
      {:ok, Enum.reverse(state.findings)}
    end
  end

  defp consume(state, chunk, enhance) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        if byte_size(state.pending) + byte_size(chunk) > state.max_line,
          do: {:error, :line_limit},
          else: {:ok, %{state | pending: state.pending <> chunk}}

      {index, 1} ->
        consume_line(state, chunk, index, enhance)
    end
  end

  defp consume_line(state, chunk, index, enhance) do
    if byte_size(state.pending) + index > state.max_line do
      {:error, :line_limit}
    else
      text = state.pending <> binary_part(chunk, 0, index)
      rest = binary_part(chunk, index + 1, byte_size(chunk) - index - 1)

      with {:ok, state} <- line(%{state | pending: ""}, text, enhance),
           do: consume(state, rest, enhance)
    end
  end

  defp line(state, text, enhance) do
    case Jason.decode(text, strings: :copy) do
      {:ok, %{"DecoderName" => decoder, "Raw" => raw} = finding}
      when is_binary(decoder) and is_binary(raw) ->
        retain(state, finding, enhance)

      _ ->
        {:ok, state}
    end
  end

  defp retain(state, _finding, _enhance) when state.count >= state.max_findings,
    do: {:error, :findings_limit}

  defp retain(state, finding, enhance) do
    case enhance.(finding) do
      nil -> {:ok, %{state | count: state.count + 1}}
      finding -> {:ok, %{state | findings: [finding | state.findings], count: state.count + 1}}
    end
  end
end
