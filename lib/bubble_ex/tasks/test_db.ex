defmodule BubbleEx.Tasks.TestDb do
  @moduledoc """
  The test database `mix wtf.task complete` and `audit` may use (WTF-448).

  Tagged-test criteria (`BubbleEx.Target.Phoenix.Checks`) run `mix test`
  in the owner's project with `MIX_ENV=test`. A generated project's `test`
  alias runs `ash.setup`, which creates and migrates the database of
  `config/test.exs`, by default `<app>_test` on `localhost:5432`: whatever
  PostgreSQL the owner runs every day. So nothing that touches a database
  runs without an explicit choice, one of:

    * `{:url, url}` (`WTF_TASK_TEST_DB` or `--test-db URL`) - a PostgreSQL
      URL (`ecto://`, `postgres://` or `postgresql://`) naming a loopback
      host (unless `allow_remote: true`, `WTF_TASK_ALLOW_REMOTE_TEST_DB=1`),
      an explicit port that is not 5432 (unless `allow_5432: true`,
      `WTF_TASK_ALLOW_5432=1`), a database whose name ends in `_test` or
      starts with `wtf_`, no query parameter but `ssl=true|false` (a
      `socket`, `socket_dir` or `port` parameter would bypass the host and
      port) and no fragment. It reaches `mix test` as `TEST_DATABASE_URL`
      in the subprocess's environment, never on its command line; the
      generated `config/test.exs` uses `TEST_DATABASE_URL` when it is set
      (never `DATABASE_URL`), and a project whose `config/test.exs` never
      reads it is refused
    * `:project` (`--use-project-test-config`) - the project's
      `config/test.exs` as it is, **unchecked**: in a generated project,
      `<app>_test` on `localhost:5432`, and the caller's
      `TEST_DATABASE_URL` and `PG*` variables pass through. Only for a
      project whose test config already names a throwaway database

  Either way `DATABASE_URL` is removed from the subprocess's environment:
  owners often point it at a development or production database, and the
  test alias creates and migrates whatever database the tests use.

  Checks that need no database (the manifest, compile, format and Credo,
  the source scans, results) run without either.
  """

  alias BubbleEx.Error

  @type t :: :project | {:url, String.t()}

  @schemes ~w(ecto postgres postgresql)
  @example "ecto://postgres:postgres@127.0.0.1:55432/my_app_test"

  @doc "An example URL, for messages."
  @spec example() :: String.t()
  def example, do: @example

  @doc """
  Validates `url` (see the module doc). `allow_5432: true` accepts port
  5432; `allow_remote: true` a host that is not loopback. Messages never
  repeat the URL (it may carry a password).
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def parse(url, opts \\ []) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- shape(uri),
         :ok <- server(uri, opts),
         :ok <- database_name(uri) do
      {:ok, {:url, url}}
    end
  end

  defp shape(uri) do
    cond do
      uri.scheme not in @schemes ->
        error("the test database URL must be an ecto:// or postgres:// URL (e.g. #{@example})")

      uri.host in [nil, ""] ->
        error("the test database URL must name its host (e.g. #{@example})")

      # None of these schemes has a default port: nil when not given.
      is_nil(uri.port) ->
        error("the test database URL must name its port explicitly (e.g. #{@example})")

      # Query parameters override the host and port (socket, socket_dir,
      # port, hostname) and an invalid one makes Ecto print the whole URL,
      # password included: only ssl=true|false.
      not query?(uri.query) ->
        error(
          "the test database URL may take no query parameter but ssl=true or ssl=false " <>
            "(socket, socket_dir, port and the like would bypass its host and port)"
        )

      uri.fragment != nil ->
        error("the test database URL must have no #fragment")

      true ->
        :ok
    end
  end

  defp server(uri, opts) do
    cond do
      not loopback?(uri.host) and not Keyword.get(opts, :allow_remote, false) ->
        error(
          "the test database URL must name a loopback host (localhost, 127.0.0.1, ::1): " <>
            "mix test creates and migrates its database; set WTF_TASK_ALLOW_REMOTE_TEST_DB=1 " <>
            "for another host"
        )

      uri.port == 5432 and not Keyword.get(opts, :allow_5432, false) ->
        error(
          "the test database URL points at port 5432, usually an everyday PostgreSQL: " <>
            "use one of its own, or set WTF_TASK_ALLOW_5432=1"
        )

      true ->
        :ok
    end
  end

  defp database_name(uri) do
    if test_database?(database(uri)),
      do: :ok,
      else:
        error(
          "the test database URL must name a database ending in _test or starting with wtf_ " <>
            "(mix test creates, migrates and fills it)"
        )
  end

  defp query?(nil), do: true

  defp query?(query) do
    case String.split(query, "&") do
      ["ssl=" <> value] -> value in ["true", "false"]
      _ -> false
    end
  end

  defp loopback?("localhost"), do: true

  defp loopback?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  defp database(%URI{path: "/" <> name}), do: name
  defp database(_uri), do: ""

  defp test_database?(name) do
    name =~ ~r/\A[A-Za-z0-9_]+\z/ and
      (String.ends_with?(name, "_test") or String.starts_with?(name, "wtf_"))
  end

  @doc "The environment of a `mix test` run against `test_db`."
  # A nil value removes the variable from the subprocess's environment.
  @spec env(t()) :: [{String.t(), String.t() | nil}]
  def env(:project), do: [{"MIX_ENV", "test"}, {"DATABASE_URL", nil}]

  def env({:url, url}),
    do: [{"MIX_ENV", "test"}, {"DATABASE_URL", nil}, {"TEST_DATABASE_URL", url}]

  @doc """
  `:ok` when the project at `root` can use `test_db`. With a URL:

    * `config/test.exs` must read `TEST_DATABASE_URL` (a
      `"TEST_DATABASE_URL"` string in its code, not in a comment), or the
      URL would go nowhere and the tests would run on the configured
      database
    * `config/runtime.exs`, outside `if config_env() == :prod` blocks,
      must neither read `DATABASE_URL` nor set a Repo's connection
      (`url`, `hostname`, `port`, `database`, `socket`, `socket_dir`):
      it runs after `config/test.exs` and would override the URL
    * no Repo config in `config/config.exs` or `config/test.exs` sets
      `socket` or `socket_dir`, which Postgrex prefers to the URL's host
      and port

  These read the code, not what it computes: config built another way (a
  helper, another file, a variable holding the Repo) is not seen.
  `:project` is not checked at all.
  """
  @spec usable(Path.t(), t()) :: :ok | {:error, Error.t()}
  def usable(_root, :project), do: :ok

  def usable(root, {:url, _url}) do
    with {:ok, test} <- config_ast(root, "test.exs"),
         :ok <- reads_test_url(test),
         {:ok, runtime} <- config_ast(root, "runtime.exs"),
         :ok <- runtime_override(runtime),
         {:ok, config} <- config_ast(root, "config.exs") do
      no_socket([{"config/config.exs", config}, {"config/test.exs", test}])
    end
  end

  defp config_ast(root, file) do
    path = Path.join([root, "config", file])

    case File.read(path) do
      {:ok, source} ->
        case Code.string_to_quoted(source) do
          {:ok, ast} -> {:ok, ast}
          _ -> error("config/#{file} does not parse, so --test-db cannot check it")
        end

      # A missing test.exs reads no TEST_DATABASE_URL: refused below.
      {:error, _} ->
        {:ok, nil}
    end
  end

  defp reads_test_url(ast) do
    if strings(ast, "TEST_DATABASE_URL"),
      do: :ok,
      else:
        error(
          "config/test.exs does not read TEST_DATABASE_URL, so --test-db cannot point the " <>
            "tests at its database: regenerate the project (its config/test.exs uses " <>
            "TEST_DATABASE_URL when set) or make the Repo config read it"
        )
  end

  defp runtime_override(nil), do: :ok

  defp runtime_override(ast) do
    ast = without_prod(ast)

    cond do
      strings(ast, "DATABASE_URL") ->
        error(
          "config/runtime.exs reads DATABASE_URL outside an `if config_env() == :prod` block: " <>
            "it would override the test database; keep it prod-only"
        )

      repo_keys(ast, ~w(url hostname port database socket socket_dir)a) ->
        error(
          "config/runtime.exs sets a Repo's connection outside an `if config_env() == :prod` " <>
            "block: it would override the test database; keep it prod-only"
        )

      true ->
        :ok
    end
  end

  defp no_socket(files) do
    case for({name, ast} <- files, repo_keys(ast, ~w(socket socket_dir)a), do: name) do
      [] ->
        :ok

      [name | _] ->
        error(
          "#{name} sets a Repo's socket or socket_dir, which Postgrex uses instead of the " <>
            "test database URL's host and port: remove it"
        )
    end
  end

  # Whether `ast` holds the string `value` (code, not comments).
  defp strings(nil, _value), do: false

  defp strings(ast, value) do
    ast
    |> Macro.prewalk(false, fn
      ^value = node, _acc -> {node, true}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  # Whether a `config _, <...>.Repo, [...]` call in `ast` sets one of `keys`.
  defp repo_keys(nil, _keys), do: false

  defp repo_keys(ast, keys) do
    ast
    |> Macro.prewalk(false, fn
      {:config, _, [_app, {:__aliases__, _, parts}, kw]} = node, acc when is_list(kw) ->
        hit =
          List.last(parts) == :Repo and
            Enum.any?(kw, fn entry ->
              match?({k, _} when is_atom(k), entry) and elem(entry, 0) in keys
            end)

        {node, acc or hit}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # `ast` with every `if config_env() == :prod` branch dropped (its else
  # branch kept).
  defp without_prod(ast) do
    Macro.prewalk(ast, fn
      {:if, _, [condition, branches]} = node when is_list(branches) ->
        if prod?(condition), do: Keyword.get(branches, :else), else: node

      node ->
        node
    end)
  end

  defp prod?({:==, _, [left, right]}), do: prod_side?(left, right) or prod_side?(right, left)
  defp prod?(_condition), do: false

  defp prod_side?({:config_env, _, args}, :prod) when args in [nil, []], do: true
  defp prod_side?(_, _), do: false

  @doc "Why a run that needs a database was refused (`ids`: the tasks)."
  @spec refusal([String.t()]) :: Error.t()
  def refusal(ids) do
    Error.new(
      :invalid_input,
      "#{Enum.join(ids, ", ")} run mix test (MIX_ENV=test; its ash.setup creates and migrates " <>
        "the test database), and no test database was chosen: set WTF_TASK_TEST_DB (or pass " <>
        "--test-db URL) to a throwaway PostgreSQL on a loopback host, with an explicit port " <>
        "(not 5432 unless WTF_TASK_ALLOW_5432=1) and a database ending in _test or starting " <>
        "with wtf_, e.g. #{@example}. (--use-project-test-config uses config/test.exs " <>
        "unchecked: in a generated project, <app>_test on localhost:5432.)",
      %{tasks: ids}
    )
  end

  defp error(message), do: {:error, Error.new(:invalid_input, message)}
end
