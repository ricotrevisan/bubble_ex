defmodule BubbleEx.Verify.Replay do
  @moduledoc """
  Where Bubble evidence may come from (decision D1 on WTF-358): a replay
  child branch of the owner's app, never live and never the shared `test`
  version.

    * `app` - the Bubble app ID (the `<app>` of `<app>.bubbleapps.io`):
      lowercase letters, digits and `-`. A custom domain is refused: it
      serves live at its root, so the harness never takes one
    * `branch` - a bare branch name starting with the replay prefix
      `wtfreplay` (e.g. `wtfreplay`, `wtfreplay-2`), lowercase letters,
      digits, `-` and `_`. It is an allowlist: `live`, `test`, their
      `version-…` URL forms, other case or whitespace are all refused
      rather than normalized, so the stored value is exactly what was
      checked
    * `branch_id` - the short ID Bubble gives the branch (`version-<id>` in
      its URLs; a branch's name is not part of any URL). The operator reads
      it from the editor or the branch list and supplies it; the driver
      never derives it. Lowercase letters and digits, 4 to 12 characters,
      at least one digit; `live`, `test` and every `version-…` form are
      refused
    * `host` - where the app is served: `<app>.bubbleapps.io` by default,
      or a custom domain the owner confirmed (a bare lowercase DNS name,
      no scheme, port, path or IP address; another app's `bubbleapps.io`
      host is refused). Requests go only to that exact host over HTTPS
  """

  alias BubbleEx.Verify.Json

  @prefix "wtfreplay"
  @branch ~r/\Awtfreplay[a-z0-9_-]*\z/
  @app ~r/\A[a-z0-9][a-z0-9-]*\z/
  @branch_id ~r/\A(?=[a-z0-9]*[0-9])[a-z0-9]{4,12}\z/
  @reserved_ids ~w(live test)
  @host_label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  @doc "The branch prefix every replay branch starts with."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "Validates a replay branch name."
  @spec branch(term()) :: {:ok, String.t()} | {:error, BubbleEx.Error.t()}
  def branch(branch) when is_binary(branch) do
    if branch =~ @branch,
      do: {:ok, branch},
      else:
        Json.error(
          "Bubble evidence comes from a replay child branch (#{@prefix}…), never live or test",
          %{branch: branch}
        )
  end

  def branch(branch),
    do: Json.error("a Bubble oracle needs its replay branch", %{branch: branch})

  @doc "Validates a Bubble app ID."
  @spec app(term()) :: {:ok, String.t()} | {:error, BubbleEx.Error.t()}
  def app(app) when is_binary(app) do
    if app =~ @app,
      do: {:ok, app},
      else: Json.error("source app must be a Bubble app ID, not a domain or URL", %{app: app})
  end

  def app(app), do: Json.error("source app must be a Bubble app ID", %{app: app})

  @doc "Validates a Bubble branch ID (the `<id>` of `version-<id>`)."
  @spec branch_id(term()) :: {:ok, String.t()} | {:error, BubbleEx.Error.t()}
  def branch_id(id) when is_binary(id) do
    if id =~ @branch_id and id not in @reserved_ids,
      do: {:ok, id},
      else:
        Json.error(
          "a replay branch ID is the short ID Bubble gives the branch, never live or test",
          %{branch_id: id}
        )
  end

  def branch_id(id),
    do: Json.error("a replay branch needs its Bubble branch ID", %{branch_id: id})

  @doc "The default host of a Bubble app: `<app>.bubbleapps.io`."
  @spec default_host(String.t()) :: String.t()
  def default_host(app), do: app <> ".bubbleapps.io"

  @doc """
  Validates the host `app` is served from: its `bubbleapps.io` host, or an
  owner-confirmed custom domain (a bare lowercase DNS name that
  `BubbleEx.HTTP` accepts as an HTTPS destination, not an IP address, not
  another app's `bubbleapps.io` host and not Bubble's own domains).
  """
  @spec host(String.t(), term()) :: {:ok, String.t()} | {:error, BubbleEx.Error.t()}
  def host(app, host) when is_binary(app) and is_binary(host) do
    cond do
      host == default_host(app) ->
        {:ok, host}

      custom_host?(host) and
          match?({:ok, %URI{host: ^host}}, BubbleEx.HTTP.Destination.parse("https://#{host}/")) ->
        {:ok, host}

      true ->
        Json.error(
          "a replay host is the app's bubbleapps.io host or a custom domain the owner confirmed",
          %{host: host}
        )
    end
  end

  def host(_app, host), do: Json.error("a replay host must be a DNS name", %{host: host})

  defp custom_host?(host) do
    labels = String.split(host, ".")

    byte_size(host) <= 253 and length(labels) >= 2 and
      Enum.all?(labels, &(&1 =~ @host_label)) and
      not (List.last(labels) =~ ~r/\A[0-9]+\z/) and
      not bubble_domain?(host)
  end

  defp bubble_domain?(host) do
    Enum.any?(~w(bubbleapps.io bubble.io bubble.is), fn domain ->
      host == domain or String.ends_with?(host, "." <> domain)
    end)
  end
end
