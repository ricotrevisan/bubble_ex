defmodule BubbleEx.PayloadFile do
  @moduledoc """
  A private JSON artifact shared by scan stages.

  `with_file/3` encodes a map once as iodata directly to disk. The callback may
  scan or upload `artifact.path`; it must finish before returning. Cleanup runs
  even if the callback raises. This budget bounds serialized input, not the
  caller's already-decoded map or the memory of an external scanner.
  """

  alias BubbleEx.Error
  @enforce_keys [:path, :bytes]
  defstruct [:path, :bytes]
  @type t :: %__MODULE__{path: String.t(), bytes: non_neg_integer()}

  @spec with_file(map() | binary(), keyword(), (t() -> result)) :: result | {:error, Error.t()}
        when result: term()
  def with_file(payload, opts \\ [], fun) do
    limit = Keyword.get(opts, :max_input_bytes, 32_000_000)

    with true <- is_integer(limit) and limit > 0,
         {:ok, contents} <- encode(payload),
         bytes <- IO.iodata_length(contents),
         true <- bytes <= limit do
      write_file(contents, bytes, fun)
    else
      false ->
        {:error,
         Error.new(:invalid_input, "payload exceeds its byte budget or budget is invalid", %{
           reason: :input_limit
         })}

      {:error, _} ->
        {:error, Error.new(:cli_failed, "payload cannot be encoded as JSON", %{})}
    end
  end

  defp encode(payload) when is_map(payload), do: Jason.encode_to_iodata(payload, pretty: true)
  defp encode(payload) when is_binary(payload), do: {:ok, payload}
  defp encode(_), do: {:error, :invalid_payload}

  defp write_file(contents, bytes, fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bubble_ex_trufflehog_" <>
          Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      )

    case File.mkdir(dir) do
      :ok ->
        try do
          path = Path.join(dir, "payload.json")

          with :ok <- File.chmod(dir, 0o700),
               :ok <- File.write(path, contents, [:exclusive]) do
            fun.(%__MODULE__{path: path, bytes: bytes})
          else
            _ -> {:error, Error.new(:cli_failed, "could not prepare private scan input", %{})}
          end
        after
          File.rm_rf(dir)
        end

      _ ->
        {:error, Error.new(:cli_failed, "could not prepare private scan input", %{})}
    end
  end

  @doc false
  def contains?(file, needle, deadline \\ :infinity)

  def contains?(%__MODULE__{path: path}, needle, deadline)
      when is_binary(needle) and byte_size(needle) > 0 do
    overlap = byte_size(needle) - 1

    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce_while("", fn chunk, tail ->
      if deadline != :infinity and System.monotonic_time(:millisecond) >= deadline,
        do: throw({:scan_budget, :scan_timeout})

      data = tail <> chunk

      if :binary.match(data, needle) != :nomatch do
        {:halt, true}
      else
        keep = min(overlap, byte_size(data))
        {:cont, :binary.copy(binary_part(data, byte_size(data) - keep, keep))}
      end
    end)
    |> Kernel.==(true)
  end

  def contains?(_, _, _), do: false
end
