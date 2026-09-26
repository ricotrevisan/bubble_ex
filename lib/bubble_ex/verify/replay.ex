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
  """

  alias BubbleEx.Verify.Json

  @prefix "wtfreplay"
  @branch ~r/\Awtfreplay[a-z0-9_-]*\z/
  @app ~r/\A[a-z0-9][a-z0-9-]*\z/

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
end
