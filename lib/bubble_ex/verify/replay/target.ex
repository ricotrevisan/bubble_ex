defmodule BubbleEx.Verify.Replay.Target do
  @moduledoc """
  The one Bubble version the replay driver may call (WTF-358 §6.1 rule 1,
  decision D1): a `wtfreplay…` child branch of one Bubble app, never live,
  never `test`.

      {:ok, target} =
        Target.new("acme", "wtfreplay", System.fetch_env!("WTF_REPLAY_ADMIN_TOKEN"),
          branch_id: "4k2xq"
        )

      Target.data_url(target, "task")
      #=> {:ok, "https://acme.bubbleapps.io/version-4k2xq/api/1.1/obj/task"}

  **What it accepts.**

    * `app` - a Bubble app ID (`BubbleEx.Verify.Replay.app/1`: lowercase
      letters, digits and `-`, at most 63 bytes). Never a domain or a URL
    * `branch` - exactly a `wtfreplay…` branch name
      (`BubbleEx.Verify.Replay.branch/1`, at most 64 bytes). `live`,
      `test`, `version-test`, `version-live`, `version-wtfreplay`, other
      case, whitespace, look-alikes (`wtf-replay`, `xwtfreplay`) and path
      tricks (`wtfreplay/../live`) are refused, not normalized. The name
      is what the owner reviewed; it is kept in ledgers and recordings but
      is not part of any URL
    * `admin_token` - the owner's dedicated replay API token (§6.3), in
      memory only; `Inspect` redacts it

  Options:

    * `:branch_id` (required) - the short ID Bubble gives that branch
      (`BubbleEx.Verify.Replay.branch_id/1`). Bubble serves a child branch
      at `/version-<id>/`, not at its name. The operator reads the ID next
      to the branch's name (editor or branch list) and supplies both; the
      driver never looks it up, so it cannot be steered to another branch.
      `live` and `test` are refused
    * `:host` - an owner-confirmed custom domain the app is served from
      (`BubbleEx.Verify.Replay.host/2`), for apps whose `bubbleapps.io`
      host redirects to their domain. Default `<app>.bubbleapps.io`. A
      custom domain serves live at its root; the driver still only builds
      `/version-<id>/api/1.1/` URLs under it

  **URLs.** Every URL is built here, under
  `https://<host>/version-<branch_id>/api/1.1/`, from validated segments
  (a type path, a Bubble record ID, a workflow name). `check_url/2`
  re-checks any URL against that prefix and the exact host before the
  client sends it, so a URL that was not built for this branch never
  leaves the process. `BubbleEx.HTTP` checks the destination on every
  request (public addresses only), and the client never follows redirects
  (an app on a custom domain redirects `bubbleapps.io` to it: that is an
  error, not a hop; pass `:host`).
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Replay

  @enforce_keys [:app, :branch, :branch_id, :host, :admin_token]
  defstruct [:app, :branch, :branch_id, :host, :admin_token]

  @type t :: %__MODULE__{
          app: String.t(),
          branch: String.t(),
          branch_id: String.t(),
          host: String.t(),
          admin_token: String.t()
        }

  @segment ~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/
  @record_id ~r/\A[0-9]{1,20}x[0-9]{1,24}\z/
  @token ~r/\A[\x21-\x7e]{8,512}\z/

  @doc "Validates and builds a target. See the moduledoc."
  @spec new(term(), term(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(app, branch, admin_token, opts \\ []) do
    with {:ok, app} <- app(app),
         {:ok, branch} <- branch(branch),
         {:ok, branch_id} <- branch_id(opts),
         {:ok, host} <- host(app, opts),
         {:ok, token} <- token(admin_token) do
      {:ok,
       %__MODULE__{
         app: app,
         branch: branch,
         branch_id: branch_id,
         host: host,
         admin_token: token
       }}
    end
  end

  defp branch_id(opts) when is_list(opts) do
    case Keyword.fetch(opts, :branch_id) do
      {:ok, id} ->
        case Replay.branch_id(id) do
          {:ok, id} ->
            {:ok, id}

          {:error, _} ->
            invalid(
              "the replay branch ID must be the short ID Bubble gives the branch, never live or test",
              :not_a_branch_id
            )
        end

      :error ->
        invalid(
          "a replay target needs the branch's Bubble ID (:branch_id): Bubble serves a branch at /version-<id>/",
          :missing_branch_id
        )
    end
  end

  defp branch_id(_opts), do: invalid("replay target options must be a keyword list", :bad_options)

  defp host(app, opts) do
    case Replay.host(app, Keyword.get(opts, :host, Replay.default_host(app))) do
      {:ok, host} -> {:ok, host}
      {:error, _} -> invalid("the replay host must be the app's own host", :not_a_replay_host)
    end
  end

  defp app(app) when is_binary(app) and byte_size(app) <= 63 do
    case Replay.app(app) do
      {:ok, app} -> {:ok, app}
      {:error, _} -> invalid("replay target app must be a Bubble app ID", :not_an_app_id)
    end
  end

  defp app(_), do: invalid("replay target app must be a Bubble app ID", :not_an_app_id)

  defp branch(branch) when is_binary(branch) and byte_size(branch) <= 64 do
    case Replay.branch(branch) do
      {:ok, branch} ->
        {:ok, branch}

      {:error, _} ->
        invalid(
          "replay runs only on a #{Replay.prefix()}… child branch, never live or test",
          :not_a_replay_branch
        )
    end
  end

  defp branch(_),
    do: invalid("replay runs only on a #{Replay.prefix()}… child branch", :not_a_replay_branch)

  defp token(token) when is_binary(token) do
    if token =~ @token,
      do: {:ok, token},
      else: invalid("the replay admin token is malformed", :invalid_token)
  end

  defp token(_), do: invalid("a replay admin token is required", :missing_token)

  @doc "`https://<host>`."
  @spec origin(t()) :: String.t()
  def origin(%__MODULE__{host: host}), do: "https://" <> host

  @doc "The API root every replay URL starts with: `…/version-<branch_id>/api/1.1`."
  @spec api_root(t()) :: String.t()
  def api_root(%__MODULE__{} = t), do: origin(t) <> "/version-#{t.branch_id}/api/1.1"

  @doc "Data API URL of a type (`/obj/<type path>`), or of one record of it."
  @spec data_url(t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  def data_url(%__MODULE__{} = t, type_path, id \\ nil) do
    with :ok <- segment(type_path, "Data API type path"),
         :ok <- record_id(id) do
      suffix = if id, do: "/" <> id, else: ""
      {:ok, api_root(t) <> "/obj/" <> type_path <> suffix}
    end
  end

  @doc "Workflow API URL of an API workflow (`/wf/<name>`)."
  @spec workflow_url(t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def workflow_url(%__MODULE__{} = t, name) do
    with :ok <- segment(name, "API workflow name"), do: {:ok, api_root(t) <> "/wf/" <> name}
  end

  @doc "The API metadata URL (`/meta`) the replay-kit preflight reads."
  @spec meta_url(t()) :: String.t()
  def meta_url(%__MODULE__{} = t), do: api_root(t) <> "/meta"

  @doc """
  Checks that `url` is under this target's API root: HTTPS, exactly the
  target's host (default port), the `/version-<branch_id>/api/1.1/` prefix,
  no dot segments, no encoded slashes, no userinfo, no fragment.
  """
  @spec check_url(t(), String.t()) :: :ok | {:error, Error.t()}
  def check_url(%__MODULE__{} = t, url) when is_binary(url) do
    prefix = api_root(t) <> "/"
    path = url |> String.split(["?", "#"], parts: 2) |> hd()

    cond do
      not String.starts_with?(url, prefix) -> refuse(url)
      String.contains?(url, "#") -> refuse(url)
      path |> String.split("/") |> Enum.any?(&(&1 in [".", ".."])) -> refuse(url)
      String.match?(path, ~r/%(?:2f|5c|2e)/i) -> refuse(url)
      exact_host?(t, url) -> :ok
      true -> refuse(url)
    end
  end

  def check_url(_t, _url), do: refuse(nil)

  defp exact_host?(%__MODULE__{host: host}, url) do
    match?(
      {:ok, %URI{scheme: "https", host: ^host, port: 443, userinfo: nil}},
      URI.new(url)
    )
  end

  defp refuse(_url),
    do: invalid("URL is outside the replay branch's API", :outside_replay_branch)

  defp segment(value, name) when is_binary(value) do
    if value =~ @segment,
      do: :ok,
      else: {:error, Error.new(:invalid_input, "invalid #{name}", %{reason: :invalid_segment})}
  end

  defp segment(_value, name),
    do: {:error, Error.new(:invalid_input, "invalid #{name}", %{reason: :invalid_segment})}

  defp record_id(nil), do: :ok

  defp record_id(id) when is_binary(id) do
    if id =~ @record_id,
      do: :ok,
      else:
        {:error, Error.new(:invalid_input, "invalid Bubble record ID", %{reason: :invalid_id})}
  end

  defp record_id(_),
    do: {:error, Error.new(:invalid_input, "invalid Bubble record ID", %{reason: :invalid_id})}

  @doc false
  @spec record_id?(term()) :: boolean()
  def record_id?(id), do: record_id(id) == :ok

  defp invalid(message, reason),
    do: {:error, Error.new(:invalid_input, message, %{reason: reason})}
end

defimpl Inspect, for: BubbleEx.Verify.Replay.Target do
  import Inspect.Algebra

  def inspect(target, opts) do
    concat([
      "#BubbleEx.Verify.Replay.Target<",
      to_doc(
        %{
          app: target.app,
          branch: target.branch,
          branch_id: target.branch_id,
          host: target.host
        },
        opts
      ),
      ", admin_token: [REDACTED]>"
    ])
  end
end
