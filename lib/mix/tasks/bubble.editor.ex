defmodule Mix.Tasks.Bubble.Editor do
  @shortdoc "Guarded reads and edits for isolated Bubble editor branches"

  @moduledoc """
  Experimental Bubble editor CLI.

      mix bubble.editor schema
      mix bubble.editor generate-ids COUNT
      mix bubble.editor versions APP VERSION
      mix bubble.editor savepoint-list APP VERSION
      mix bubble.editor savepoint-create APP VERSION MESSAGE
      mix bubble.editor read APP VERSION '["%p3","page_key"]'
      mix bubble.editor check PLAN.json
      mix bubble.editor apply PLAN.json --receipt RECEIPT.json
      mix bubble.editor rollback RECEIPT.json --receipt NEW_RECEIPT.json

  Authenticated commands read the cookie from `BUBBLE_EX_EDITOR_COOKIE`. The
  cookie is never printed or written to a receipt. Writes refuse `test` and
  `live`, do not retry, and verify fresh persisted state.
  """

  use Mix.Task

  alias BubbleEx.Editor
  alias BubbleEx.Editor.{Plan, Snapshot, Target}

  @switches [receipt: :string]

  @impl Mix.Task
  def run(["schema"]) do
    output(
      Map.put(Plan.schema(), :excluded, [
        "test/live writes",
        "cross-owner moves",
        "runtime data/files/logs",
        "deployment",
        "branch merge"
      ])
    )
  end

  def run(["generate-ids", encoded_count]) do
    case Integer.parse(encoded_count) do
      {count, ""} when count > 0 and count <= 1_000 ->
        output(%{ids: BubbleEx.Editor.Id.generate(count)})

      _ ->
        Mix.raise("COUNT must be an integer between 1 and 1000")
    end
  end

  def run(["versions", appname, version]) do
    with_cookie(fn cookie ->
      with {:ok, target} <- Target.new(appname, version, cookie),
           {:ok, versions} <- Editor.versions(target) do
        output(versions)
      end
    end)
  end

  def run(["savepoint-list", appname, version]) do
    with_cookie(fn cookie ->
      with {:ok, target} <- Target.new(appname, version, cookie),
           {:ok, history} <- Editor.savepoints(target) do
        output(history)
      end
    end)
  end

  def run(["savepoint-create", appname, version, message]) do
    with_cookie(fn cookie ->
      with {:ok, target} <- Target.new(appname, version, cookie),
           {:ok, result} <- Editor.create_savepoint(target, message) do
        output(result)
      end
    end)
  end

  def run(["read", appname, version, encoded_path]) do
    with_cookie(fn cookie ->
      with {:ok, path} <- decode_path(encoded_path),
           {:ok, target} <- Target.new(appname, version, cookie),
           {:ok, snapshot} <- Editor.read(target, [path]) do
        {:ok, value} = Snapshot.fetch(snapshot, path)

        output(%{
          appname: appname,
          version: version,
          last_change: snapshot.last_change,
          path: path,
          value: value
        })
      end
    end)
  end

  def run(["check", plan_path]) do
    with_cookie(fn cookie ->
      with {:ok, plan} <- Plan.load_file(plan_path),
           {:ok, result} <- Editor.check(plan, cookie) do
        output(result)
      end
    end)
  end

  def run(["apply", plan_path | argv]) do
    with_cookie(fn cookie ->
      with {:ok, receipt_path} <- receipt_path(argv),
           {:ok, plan} <- Plan.load_file(plan_path),
           {:ok, receipt} <- Editor.apply(plan, cookie),
           :ok <- write_json(receipt_path, receipt) do
        output(%{
          status: receipt["status"],
          receipt: Path.expand(receipt_path),
          verified_last_change: receipt["verified_last_change"]
        })
      end
    end)
  end

  def run(["rollback", receipt_path | argv]) do
    with_cookie(fn cookie ->
      with {:ok, output_path} <- receipt_path(argv),
           {:ok, receipt} <- read_json(receipt_path),
           {:ok, inverse} <- fetch_inverse(receipt),
           {:ok, plan} <- Plan.new(inverse),
           {:ok, rollback_receipt} <- Editor.apply(plan, cookie),
           :ok <- write_json(output_path, rollback_receipt) do
        output(%{
          status: rollback_receipt["status"],
          receipt: Path.expand(output_path),
          verified_last_change: rollback_receipt["verified_last_change"]
        })
      end
    end)
  end

  def run(_argv), do: Mix.raise("invalid arguments; run `mix help bubble.editor`")

  defp with_cookie(fun) do
    Mix.Task.run("app.start")

    case System.get_env("BUBBLE_EX_EDITOR_COOKIE") do
      cookie when is_binary(cookie) and cookie != "" -> finish(fun.(cookie))
      _ -> Mix.raise("BUBBLE_EX_EDITOR_COOKIE is required")
    end
  end

  defp finish(:ok), do: :ok
  defp finish({:error, error}), do: Mix.raise(Exception.message(error))
  defp finish(other), do: other

  defp receipt_path(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    case {Keyword.get(opts, :receipt), rest, invalid} do
      {path, [], []} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, BubbleEx.Error.new(:invalid_input, "--receipt PATH is required")}
    end
  end

  defp decode_path(encoded) do
    case Jason.decode(encoded) do
      {:ok, path} when is_list(path) and path != [] ->
        if Enum.all?(path, &is_binary/1) do
          {:ok, path}
        else
          {:error,
           BubbleEx.Error.new(:invalid_input, "PATH must be a non-empty JSON string array")}
        end

      _ ->
        {:error, BubbleEx.Error.new(:invalid_input, "PATH must be a non-empty JSON string array")}
    end
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, value} <- Jason.decode(body) do
      {:ok, value}
    else
      {:error, reason} ->
        {:error,
         BubbleEx.Error.new(:invalid_input, "receipt could not be read", %{
           reason: inspect(reason)
         })}
    end
  end

  defp fetch_inverse(%{"inverse_plan" => inverse}) when is_map(inverse), do: {:ok, inverse}

  defp fetch_inverse(_receipt),
    do: {:error, BubbleEx.Error.new(:invalid_input, "receipt has no inverse plan")}

  defp write_json(path, value) do
    with :ok <- File.mkdir_p(Path.dirname(Path.expand(path))),
         :ok <- File.write(path, Jason.encode_to_iodata!(value, pretty: true)) do
      :ok
    else
      {:error, reason} ->
        {:error,
         BubbleEx.Error.new(:invalid_input, "receipt could not be written", %{
           path: path,
           reason: inspect(reason)
         })}
    end
  end

  defp output(value), do: Mix.shell().info(Jason.encode!(value, pretty: true))
end
