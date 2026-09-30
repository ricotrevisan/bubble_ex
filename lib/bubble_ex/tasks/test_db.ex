defmodule BubbleEx.Tasks.TestDb do
  @moduledoc """
  The test database `mix wtf.task complete` and `audit` may use (WTF-448).

  Tagged-test criteria (`BubbleEx.Target.Phoenix.Checks`) run `mix test`
  in the owner's project with `MIX_ENV=test`. A generated project's `test`
  alias runs `ash.setup`, which creates and migrates the database of
  `config/test.exs`, by default `<app>_test` on `localhost:5432`: whatever
  PostgreSQL the owner runs every day. So nothing that touches a database
  runs without an explicit choice, one of:

    * `{:url, url}` (`--test-db URL` or `WTF_TASK_TEST_DB`) - a PostgreSQL
      URL (`ecto://`, `postgres://` or `postgresql://`) naming its host,
      an explicit port that is not 5432 (unless `allow_5432: true`,
      `WTF_TASK_ALLOW_5432=1`) and a database whose name ends in `_test`
      or starts with `wtf_`. It reaches `mix test` as `DATABASE_URL` in the
      subprocess's environment, never on its command line; the generated
      `config/test.exs` uses `DATABASE_URL` when it is set, and a project
      whose `config/test.exs` never reads it is refused
    * `:project` (`--use-project-test-config`) - the project's
      `config/test.exs` as it is (and the caller's environment)

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
  5432. Messages never repeat the URL (it may carry a password).
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def parse(url, opts \\ []) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in @schemes ->
        error("the test database URL must be an ecto:// or postgres:// URL (e.g. #{@example})")

      uri.host in [nil, ""] ->
        error("the test database URL must name its host (e.g. #{@example})")

      # None of these schemes has a default port: nil when not given.
      is_nil(uri.port) ->
        error("the test database URL must name its port explicitly (e.g. #{@example})")

      uri.port == 5432 and not Keyword.get(opts, :allow_5432, false) ->
        error(
          "the test database URL points at port 5432, usually an everyday PostgreSQL: " <>
            "use one of its own, or set WTF_TASK_ALLOW_5432=1"
        )

      not test_database?(database(uri)) ->
        error(
          "the test database URL must name a database ending in _test or starting with wtf_ " <>
            "(mix test creates, migrates and fills it)"
        )

      true ->
        {:ok, {:url, url}}
    end
  end

  defp database(%URI{path: "/" <> name}), do: name
  defp database(_uri), do: ""

  defp test_database?(name) do
    name =~ ~r/\A[^\/]+\z/ and
      (String.ends_with?(name, "_test") or String.starts_with?(name, "wtf_"))
  end

  @doc "The environment of a `mix test` run against `test_db`."
  @spec env(t()) :: [{String.t(), String.t()}]
  def env(:project), do: [{"MIX_ENV", "test"}]
  def env({:url, url}), do: [{"MIX_ENV", "test"}, {"DATABASE_URL", url}]

  @doc """
  `:ok` when the project at `root` can use `test_db`: with a URL, its
  `config/test.exs` must read `DATABASE_URL` (a `"DATABASE_URL"` string in
  its code, not in a comment), or the URL would go nowhere and the tests
  would run on the configured database.
  """
  @spec usable(Path.t(), t()) :: :ok | {:error, Error.t()}
  def usable(_root, :project), do: :ok

  def usable(root, {:url, _url}) do
    path = Path.join(root, "config/test.exs")

    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source),
         true <- reads_database_url?(ast) do
      :ok
    else
      _ ->
        error(
          "config/test.exs does not read DATABASE_URL, so --test-db cannot point the tests at " <>
            "its database: regenerate the project (its config/test.exs uses DATABASE_URL when " <>
            "set) or make the Repo config read it, or pass --use-project-test-config when " <>
            "config/test.exs already names a database of its own"
        )
    end
  end

  defp reads_database_url?(ast) do
    ast
    |> Macro.prewalk(false, fn
      "DATABASE_URL" = node, _acc -> {node, true}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  @doc "Why a run that needs a database was refused (`ids`: the tasks)."
  @spec refusal([String.t()]) :: Error.t()
  def refusal(ids) do
    Error.new(
      :invalid_input,
      "#{Enum.join(ids, ", ")} run mix test (MIX_ENV=test; its ash.setup creates and migrates " <>
        "the test database), and no test database was chosen: pass --test-db URL (or set " <>
        "WTF_TASK_TEST_DB; an explicit port, not 5432 unless WTF_TASK_ALLOW_5432=1, and a " <>
        "database ending in _test or starting with wtf_, e.g. #{@example}), or " <>
        "--use-project-test-config to use config/test.exs as it is",
      %{tasks: ids}
    )
  end

  defp error(message), do: {:error, Error.new(:invalid_input, message)}
end
