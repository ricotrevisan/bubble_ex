defmodule BubbleEx.Editor do
  @moduledoc """
  Guarded, branch-scoped editing for a bounded subset of Bubble web app definitions.

  This API is experimental because Bubble's editor endpoints are undocumented.
  It deliberately refuses protected versions, stale plans, automatic write
  retries, and edits outside the documented support matrix.
  """

  alias BubbleEx.Editor.{Client, Plan, PluginSchema, Snapshot, Target}
  alias BubbleEx.Error

  @type receipt :: map()

  @spec check(Plan.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def check(plan, cookie, opts \\ []) do
    with {:ok, target} <- target(plan, cookie, opts),
         {:ok, version} <- Client.resolve_child(target, opts),
         {:ok, plan} <- prepare_plugins(plan, target, opts),
         {:ok, snapshot} <- Client.read(target, Plan.paths(plan), opts),
         :ok <- Plan.check(plan, snapshot) do
      {:ok,
       %{
         status: "valid",
         appname: plan.appname,
         version: plan.version,
         branch: Map.get(version, "display"),
         last_change: snapshot.last_change,
         operation_count: length(plan.operations),
         paths: Plan.paths(plan)
       }}
    end
  end

  @spec apply(Plan.t(), String.t(), keyword()) :: {:ok, receipt()} | {:error, Error.t()}
  def apply(plan, cookie, opts \\ []) do
    with {:ok, target} <- target(plan, cookie, opts),
         {:ok, version} <- Client.resolve_child(target, opts),
         {:ok, plan} <- prepare_plugins(plan, target, opts),
         {:ok, before} <- Client.read(target, Plan.paths(plan), opts),
         :ok <- Plan.check(plan, before) do
      session_id = Keyword.get_lazy(opts, :session_id, &session_id/0)
      changes = Plan.changes(plan, session_id)

      case Client.write(target, changes, opts) do
        {:ok, acknowledgement} ->
          verify_acknowledged(target, plan, before, version, acknowledgement, opts)

        {:error, %Error{} = write_error} ->
          reconcile(target, plan, before, version, write_error, opts)
      end
    end
  end

  @spec read(Target.t(), [Snapshot.path()], keyword()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def read(target, paths, opts \\ []) do
    with {:ok, _version} <- Client.resolve_child(target, opts) do
      Client.read(target, paths, opts)
    end
  end

  @spec versions(Target.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def versions(target, opts \\ []), do: Client.versions(target, opts)

  @spec plugin_schemas(Target.t(), [String.t()] | :all, keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def plugin_schemas(target, groups \\ :all, opts \\ []) do
    with {:ok, _version} <- Client.resolve_child(target, opts) do
      PluginSchema.discover(target, groups, opts)
    end
  end

  defp prepare_plugins(%{plugin_types: []} = plan, _target, _opts), do: Plan.new(plan.source, %{})

  defp prepare_plugins(plan, target, opts) do
    with {:ok, discovered} <- PluginSchema.discover(target, plan.plugin_types, opts),
         :ok <- verify_schema_hashes(plan, discovered.schemas),
         {:ok, validated} <- Plan.new(plan.source, discovered.schemas) do
      guards =
        Enum.map(discovered.schemas, fn {group, schema} ->
          %{
            op: :guard,
            internal: true,
            path: ["settings", "client_safe", "plugins", group],
            expected: schema.version,
            value: schema.version
          }
        end)

      {:ok, %{validated | operations: validated.operations ++ guards}}
    end
  end

  defp verify_schema_hashes(plan, schemas) do
    expected = Map.get(plan.source, "plugin_schema_hashes", %{})
    actual = Map.new(schemas, fn {group, schema} -> {group, schema.hash} end)

    if is_map(expected) and Map.take(expected, Map.keys(actual)) == actual do
      :ok
    else
      {:error,
       Error.new(:invalid_input, "plugin schema is missing or stale; rediscover and replan", %{
         reason: :stale_plugin_schema,
         actual_hashes: actual
       })}
    end
  end

  @spec savepoints(Target.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def savepoints(target, opts \\ []) do
    with {:ok, _version} <- Client.resolve_child(target, opts),
         {:ok, history} <- Client.restore_history(target, opts) do
      {:ok, sanitize_history(history)}
    end
  end

  @spec create_savepoint(Target.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_savepoint(target, message, opts \\ []) when is_binary(message) do
    trimmed = String.trim(message)

    if trimmed == "" or byte_size(trimmed) > 500 do
      {:error,
       Error.new(:invalid_input, "savepoint message must contain 1 to 500 bytes", %{
         reason: :invalid_savepoint_message
       })}
    else
      probe = [["%p3", "__bubbleex_revision_probe__"]]

      with {:ok, _version} <- Client.resolve_child(target, opts),
           {:ok, before} <- Client.read(target, probe, opts),
           {:ok, before_history} <- Client.restore_history(target, opts),
           session <- Keyword.get_lazy(opts, :session_id, &session_id/0),
           result <- Client.create_savepoint(target, trimmed, session, opts) do
        verify_savepoint_result(target, trimmed, before, before_history, result, opts)
      end
    end
  end

  defp verify_savepoint_result(target, message, before, before_history, result, opts) do
    with {:ok, readback} <- Client.read(target, [["%p3", "__bubbleex_revision_probe__"]], opts),
         {:ok, history} <- Client.restore_history(target, opts) do
      new_annotations =
        Map.get(history, "annotations", []) -- Map.get(before_history, "annotations", [])

      created? =
        Enum.any?(new_annotations, fn annotation ->
          Map.get(annotation, "message") in [message, "commit:" <> message]
        end)

      case {result, created?} do
        {{:ok, acknowledgement}, _} ->
          {:ok,
           savepoint_receipt(
             "created",
             target,
             message,
             before,
             readback,
             acknowledgement,
             new_annotations
           )}

        {{:error, %Error{} = error}, true} ->
          {:ok,
           savepoint_receipt(
             "reconciled_created",
             target,
             message,
             before,
             readback,
             %{"write_error_kind" => to_string(error.kind)},
             new_annotations
           )}

        {{:error, %Error{} = error}, false} ->
          {:error, error}
      end
    end
  end

  defp savepoint_receipt(status, target, message, before, readback, acknowledgement, annotations) do
    %{
      status: status,
      appname: target.appname,
      version: target.version,
      message: message,
      before_last_change: before.last_change,
      verified_last_change: readback.last_change,
      acknowledgement: sanitize_acknowledgement(acknowledgement),
      annotations: Enum.map(annotations, &sanitize_annotation/1)
    }
  end

  defp sanitize_history(history) do
    %{
      "earliest_change_date" => Map.get(history, "earliest_change_date"),
      "annotations" => history |> Map.get("annotations", []) |> Enum.map(&sanitize_annotation/1)
    }
  end

  defp sanitize_annotation(annotation) when is_map(annotation) do
    Map.take(annotation, ["message", "timestamp"])
  end

  defp verify_acknowledged(target, plan, before, version, acknowledgement, opts) do
    with {:ok, acknowledged_revision} <- acknowledgement_revision(acknowledgement),
         {:ok, readback} <- Client.read(target, Plan.paths(plan), opts),
         :ok <- verify_intended(plan, readback) do
      {:ok,
       receipt(
         "applied",
         plan,
         before,
         readback,
         version,
         acknowledged_revision,
         acknowledgement
       )}
    else
      {:error, %Error{} = ack_error} ->
        reconcile(target, plan, before, version, ack_error, opts)
    end
  end

  defp reconcile(target, plan, before, version, write_error, opts) do
    case Client.read(target, Plan.paths(plan), opts) do
      {:ok, readback} ->
        intended = Enum.map(plan.operations, &operation_state(&1, readback))

        cond do
          Enum.all?(intended, &(&1 == :intended)) ->
            {:ok,
             receipt("reconciled_applied", plan, before, readback, version, nil, %{
               "warning" => "write acknowledgement was unavailable; fresh state matches the plan",
               "write_error_kind" => to_string(write_error.kind)
             })}

          Enum.zip(plan.operations, intended)
          |> Enum.all?(fn {operation, state} ->
            state == :prior or (operation.op == :guard and state == :intended)
          end) ->
            {:error,
             Error.new(:request_failed, "editor write outcome reconciled as not applied", %{
               reason: :not_applied,
               last_change: readback.last_change,
               write_error_kind: write_error.kind,
               safe_to_replan: true
             })}

          true ->
            {:error,
             Error.new(
               :invalid_input,
               "editor write outcome is mixed and requires manual reconciliation",
               %{
                 reason: :ambiguous_write,
                 last_change: readback.last_change,
                 operation_states: intended,
                 write_error_kind: write_error.kind
               }
             )}
        end

      {:error, %Error{} = read_error} ->
        {:error,
         Error.new(:request_failed, "editor write and reconciliation reads both failed", %{
           reason: :unreconciled_write,
           write_error_kind: write_error.kind,
           read_error_kind: read_error.kind
         })}
    end
  end

  defp operation_state(operation, snapshot) do
    case Snapshot.fetch(snapshot, operation.path) do
      {:ok, actual} ->
        cond do
          Plan.intended?(operation, actual) -> :intended
          actual === operation.expected -> :prior
          true -> :other
        end

      :error ->
        :other
    end
  end

  defp verify_intended(plan, snapshot) do
    failures =
      Enum.flat_map(plan.operations, fn operation ->
        case operation_state(operation, snapshot) do
          :intended -> []
          state -> [%{path: operation.path, state: state}]
        end
      end)

    case failures do
      [] ->
        :ok

      _ ->
        {:error,
         Error.new(:invalid_input, "fresh editor readback did not match the applied plan", %{
           reason: :verification_failed,
           failures: failures
         })}
    end
  end

  defp receipt(status, plan, before, readback, version, acknowledged_revision, acknowledgement) do
    %{
      "receipt_version" => 1,
      "status" => status,
      "appname" => plan.appname,
      "version" => plan.version,
      "branch" => Map.get(version, "display"),
      "base_last_change" => before.last_change,
      "acknowledged_last_change" => acknowledged_revision,
      "verified_last_change" => readback.last_change,
      "operation_count" => length(plan.operations),
      "paths" => Plan.paths(plan),
      "acknowledgement" => sanitize_acknowledgement(acknowledgement),
      "inverse_plan" => Plan.inverse(plan, readback.last_change)
    }
  end

  defp sanitize_acknowledgement(acknowledgement) when is_map(acknowledgement) do
    Map.take(acknowledgement, [
      "last_change",
      "last_change_date",
      "id_counter",
      "warning",
      "write_error_kind"
    ])
  end

  defp acknowledgement_revision(%{"last_change" => revision}) when is_integer(revision),
    do: {:ok, revision}

  defp acknowledgement_revision(%{"last_change" => revision}) when is_binary(revision) do
    case Integer.parse(revision) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> invalid_ack()
    end
  end

  defp acknowledgement_revision(_acknowledgement), do: invalid_ack()

  defp invalid_ack,
    do:
      {:error,
       Error.new(:parse_failed, "editor write acknowledgement omitted a valid last_change", %{
         reason: :invalid_acknowledgement
       })}

  defp target(plan, cookie, opts) do
    Target.new(plan.appname, plan.version, cookie,
      origin: Keyword.get(opts, :origin, "https://bubble.io")
    )
  end

  defp session_id do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end
end
