defmodule BubbleEx.Frontend.Auth do
  @moduledoc false

  alias BubbleEx.Apps.Validator
  alias BubbleEx.{Error, Frontend.SafeUrl}

  @enforce_keys [:origin]
  defstruct origin: nil,
            basic: nil,
            session_cookie: nil,
            taints: []

  @type origin :: {String.t(), String.t(), non_neg_integer()}
  @opaque t :: %__MODULE__{
            origin: origin(),
            basic: {String.t(), String.t()} | nil,
            session_cookie: String.t() | nil,
            taints: [String.t()]
          }

  @spec prepare(String.t(), keyword()) :: {:ok, String.t(), t()} | {:error, Error.t()}
  def prepare(input, opts) when is_binary(input) do
    with {:ok, sanitized, url_basic, url_taints} <- extract_userinfo(input),
         {:ok, option_basic} <- validate_basic(opts),
         :ok <- reject_conflict(url_basic, option_basic),
         {:ok, cookie} <- validate_cookie(Keyword.get(opts, :session_cookie)),
         basic = url_basic || option_basic,
         :ok <- require_https(sanitized, basic, cookie),
         {:ok, normalized_url} <- normalize_input(sanitized),
         {:ok, origin} <- safe_origin(normalized_url) do
      taints = credential_taints(input, url_taints, basic, cookie)

      {:ok, sanitized,
       %__MODULE__{origin: origin, basic: basic, session_cookie: cookie, taints: taints}}
    end
  end

  def prepare(_input, _opts) do
    {:error, Error.new(:invalid_input, "app must be a string", %{})}
  end

  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{basic: basic, session_cookie: cookie}),
    do: not is_nil(basic) or not is_nil(cookie)

  @spec headers(t(), String.t()) :: [{String.t(), String.t()}]
  def headers(%__MODULE__{} = auth, url) do
    if SafeUrl.same_origin?(auth.origin, url) do
      []
      |> maybe_basic(auth.basic)
      |> maybe_cookie(auth.session_cookie)
    else
      []
    end
  end

  @spec scoped_to?(t(), String.t()) :: boolean()
  def scoped_to?(%__MODULE__{origin: origin}, url), do: SafeUrl.same_origin?(origin, url)

  @spec rescope(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def rescope(%__MODULE__{} = auth, url) do
    with {:ok, origin} <- SafeUrl.origin(url),
         :ok <- require_https(url, auth.basic, auth.session_cookie) do
      {:ok, %{auth | origin: origin}}
    end
  end

  @spec taints(t()) :: [String.t()]
  def taints(%__MODULE__{taints: taints}), do: taints

  defp normalize_input(input) do
    case Validator.validate_input(input) do
      {:ok, url} -> {:ok, url}
      {:error, _} -> {:error, invalid("app is not a valid Bubble ID or URL")}
    end
  end

  defp safe_origin(url) do
    case SafeUrl.origin(url) do
      {:ok, origin} -> {:ok, origin}
      {:error, _} -> {:error, invalid("app URL has no valid origin")}
    end
  end

  defp extract_userinfo(input) do
    candidate =
      if String.contains?(input, "@") and not String.contains?(input, "://"),
        do: "https://" <> input,
        else: input

    uri = URI.parse(candidate)

    case uri.userinfo do
      nil ->
        {:ok, input, nil, []}

      userinfo ->
        with {:ok, basic} <- parse_userinfo(userinfo) do
          sanitized = %{uri | userinfo: nil, fragment: nil} |> URI.to_string()
          {:ok, sanitized, basic, [userinfo]}
        end
    end
  rescue
    _ -> {:error, invalid("credential-bearing app URL is malformed")}
  end

  defp parse_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [raw_username, raw_password] ->
        username = URI.decode(raw_username)
        password = URI.decode(raw_password)

        with :ok <- validate_value(username, "Basic username"),
             :ok <- validate_value(password, "Basic password"),
             :ok <- reject_colon(username) do
          {:ok, {username, password}}
        end

      _ ->
        {:error, invalid("credential-bearing app URL must contain username and password")}
    end
  rescue
    _ -> {:error, invalid("credential-bearing app URL is malformed")}
  end

  defp validate_basic(opts) do
    username = Keyword.get(opts, :username)
    password = Keyword.get(opts, :password)

    case {username, password} do
      {nil, nil} ->
        {:ok, nil}

      {username, password} when is_binary(username) and is_binary(password) ->
        with :ok <- validate_value(username, "Basic username"),
             :ok <- validate_value(password, "Basic password"),
             :ok <- reject_colon(username) do
          {:ok, {username, password}}
        end

      _ ->
        {:error, invalid("Basic username and password must be supplied together")}
    end
  end

  defp validate_cookie(nil), do: {:ok, nil}

  defp validate_cookie(cookie) when is_binary(cookie) do
    case validate_value(cookie, "session cookie") do
      :ok -> {:ok, cookie}
      {:error, _} = error -> error
    end
  end

  defp validate_cookie(_), do: {:error, invalid("session cookie must be a string")}

  defp validate_value(value, label) do
    cond do
      String.trim(value) == "" ->
        {:error, invalid("#{label} must not be blank")}

      String.contains?(value, ["\r", "\n"]) ->
        {:error, invalid("#{label} contains invalid header characters")}

      true ->
        :ok
    end
  end

  defp reject_colon(username) do
    if String.contains?(username, ":"),
      do: {:error, invalid("Basic username must not contain a colon")},
      else: :ok
  end

  defp reject_conflict(nil, _), do: :ok
  defp reject_conflict(_, nil), do: :ok

  defp reject_conflict(_, _),
    do: {:error, invalid("use either URL or option Basic credentials, not both")}

  defp require_https(_url, nil, nil), do: :ok

  defp require_https(url, _basic, _cookie) do
    case URI.parse(url) do
      %URI{scheme: scheme} when is_binary(scheme) ->
        if String.downcase(scheme) == "https",
          do: :ok,
          else: {:error, invalid("frontend authentication requires HTTPS")}

      _ ->
        # A Bubble ID is normalized to HTTPS by the caller.
        :ok
    end
  end

  defp credential_taints(input, url_taints, basic, cookie) do
    basic_taints =
      case basic do
        {username, password} ->
          token = Base.encode64(username <> ":" <> password)
          [username, password, token, "Basic " <> token]

        nil ->
          []
      end

    cookie_taints =
      case cookie do
        nil -> []
        value -> [value | cookie_values(value)]
      end

    original = if url_taints == [], do: [], else: [input]

    (original ++ url_taints ++ basic_taints ++ cookie_taints)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp cookie_values(cookie) do
    cookie
    |> String.split(";")
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [_name, value] -> [String.trim(value)]
        _ -> []
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_basic(headers, nil), do: headers

  defp maybe_basic(headers, {username, password}) do
    token = Base.encode64(username <> ":" <> password)
    headers ++ [{"authorization", "Basic " <> token}]
  end

  defp maybe_cookie(headers, nil), do: headers
  defp maybe_cookie(headers, cookie), do: headers ++ [{"cookie", cookie}]

  defp invalid(message), do: Error.new(:invalid_input, message, %{})
end

defimpl Inspect, for: BubbleEx.Frontend.Auth do
  import Inspect.Algebra
  def inspect(_auth, _opts), do: concat(["#BubbleEx.Frontend.Auth<redacted>"])
end
