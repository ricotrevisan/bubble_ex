defmodule BubbleEx.Target.Ash.LoaderTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Load.{Convert, Plan}
  alias BubbleEx.Load.Plan.{Column, Derived}
  alias BubbleEx.Model.{Field, Type}
  alias BubbleEx.Target.Ash.Loader
  alias BubbleEx.Test.LoadFixture, as: F

  defp plan(which) do
    {:ok, project} = F.project(which)
    {Loader, config} = Loader.target(project, query: fn _, _ -> {:ok, %{rows: []}} end)
    {:ok, plan} = Loader.plan(config, F.model(which))
    plan
  end

  defp column(plan, type, field),
    do: plan |> Plan.table(type) |> Map.fetch!(:columns) |> Enum.find(&(&1.field == field))

  describe "plan" do
    test "maps decisions of cut 2 to conversions and derivations" do
      plan = plan(:cut2)
      card = Plan.table(plan, "card")
      board = Plan.table(plan, "board")

      assert card.key == "id"

      assert %Column{column: "assignee_id", text_ref: true, references: %{target: "user"}} =
               column(plan, "card", "assignee_id_text")

      assert %Column{text_ref: true, encoding: {:array, :text}} =
               column(plan, "card", "blocker_ids_list_text")

      assert %Column{drop_dangling: true} = column(plan, "board", "watchers_list_user")
      refute column(plan, "board", "cards_list_custom_card")
      refute column(plan, "card", "tags_list_text").text_ref

      assert Enum.sort_by(board.derived, & &1.field) == [
               %Derived{
                 field: "card_count_number",
                 derivation: {:count, [{:reverse, "card", "board_custom_board"}]}
               },
               %Derived{
                 field: "cards_list_custom_card",
                 derivation: {:reverse, "card", "board_custom_board"}
               },
               %Derived{
                 field: "watcher_count_number",
                 derivation: {:count, [{:list, "watchers_list_user"}]}
               }
             ]

      assert %Derived{
               derivation: {:count, [{:ref, "board_custom_board"}, {:list, "watchers_list_user"}]}
             } =
               Enum.find(card.derived, &(&1.field == "board_watcher_count_number"))

      assert %Derived{
               derivation:
                 {:count,
                  [{:ref, "board_custom_board"}, {:reverse, "card", "board_custom_board"}]}
             } =
               Enum.find(card.derived, &(&1.field == "board_card_count_number"))

      assert plan.auth == %Plan.Auth{
               type: "user",
               email_column: "email",
               confirmed_column: "confirmed_at"
             }

      # The confirmed column maps no field: it is not a table column.
      refute Enum.any?(Plan.table(plan, "user").columns, &(&1.column == "confirmed_at"))
    end

    test "a Project mapped before WTF-413 (no confirmed_at) plans no confirmed column" do
      {:ok, project} = F.project(:cut2)

      resources =
        Enum.map(project.resources, fn r ->
          %{r | attributes: Enum.reject(r.attributes, &(&1.source[:auth] == "confirmed_at"))}
        end)

      {Loader, config} =
        Loader.target(%{project | resources: resources},
          query: fn _, _ -> {:ok, %{rows: []}} end
        )

      assert {:ok, %Plan{auth: %Plan.Auth{confirmed_column: nil}}} =
               Loader.plan(config, F.model(:cut2))
    end

    test "maps cut 1: related fields, refined numbers, renamed tables" do
      plan = plan(:combined)
      assert Plan.table(plan, "task").table == "todo_item"
      assert column(plan, "task", "points_number").encoding == :decimal
      assert column(plan, "project", "task_count_number").encoding == :integer

      assert %Derived{
               derivation:
                 {:related, [{:ref, "workspace_custom_workspace"}], {"workspace", "name_text"}}
             } =
               Enum.find(
                 Plan.table(plan, "project").derived,
                 &(&1.field == "sort_workspace_name_text")
               )
    end

    test "is the same with privacy: :unverified (derivations read through private twins)" do
      {:ok, project} = F.project(:cut2, privacy: :unverified)
      {Loader, config} = Loader.target(project, query: fn _, _ -> {:ok, %{rows: []}} end)
      assert {:ok, unverified} = Loader.plan(config, F.model(:cut2))
      assert Plan.sha256(unverified) == Plan.sha256(plan(:cut2))
    end

    test "encodes every field kind" do
      plan = plan(:field_types)

      assert {:enum, keys, %{"Open" => "open", "Closed" => "closed"}} =
               column(plan, "task", "status_option_status").encoding

      assert MapSet.to_list(keys) |> Enum.sort() == ["closed", "open"]

      assert {:structured, :geographic_address, parts} =
               column(plan, "task", "place_geographic_address").encoding

      assert {"formatted_address", "formatted_address", :text} in parts
      assert column(plan, "task", "dates_list_date").encoding == {:array, :datetime}
      assert column(plan, "task", "duration_dateinterval").encoding == :float
      assert %Column{files: true} = column(plan, "task", "images_list_image")
      refute column(plan, "task", "notes_list_text").files
    end
  end

  describe "schema check" do
    test "reports missing tables and columns, wrong types and extra columns" do
      plan = plan(:cut2)

      rows =
        for t <- plan.tables,
            t.type != "board",
            c <- [%{column: t.key, encoding: :text} | t.columns],
            not (t.type == "card" and c.column == "points") do
          udt = if t.type == "card" and c.column == "title", do: "int4", else: udt(c.encoding)
          nullable = if t.type == "card" and c.column == "status", do: "NO", else: "YES"
          nullable = if c.column in [t.key, "email"], do: "NO", else: nullable
          [t.table, c.column, udt, nullable]
        end

      query = fn sql, _params ->
        assert sql =~ "information_schema.columns"

        {:ok,
         %{
           rows:
             rows ++
               [["user", "confirmed_at", "timestamptz", "YES"], ["user", "legacy", "bool", "YES"]]
         }}
      end

      {:ok, project} = F.project(:cut2)
      {Loader, config} = Loader.target(project, query: query)
      assert {:ok, diags} = Loader.check_schema(config, plan)

      found =
        Enum.map(
          diags,
          &{&1.code, &1.subject,
           &1.details[:missing] || &1.details[:actual] || &1.details[:columns]}
        )

      assert {:load_schema_mismatch, %{type: "board"}, :table} in found
      assert {:load_schema_mismatch, %{type: "card", field: "points_number"}, :column} in found
      assert {:load_schema_mismatch, %{type: "card", field: "title_text"}, "int4"} in found
      assert {:load_column_extra, %{type: "user"}, ["legacy"]} in found
      assert {:load_schema_mismatch, %{type: "card", field: "status_text"}, :not_null} in found
      assert {:load_schema_mismatch, %{type: "user", field: "email"}, :not_null} in found
      email = Enum.find(diags, &(&1.subject == %{type: "user", field: "email"}))
      assert email.message =~ "allow_nil? false"
      assert length(found) == 6
    end

    test "checks the users' confirmed_at column: present, a timestamp, nullable" do
      plan = plan(:cut2)
      {:ok, project} = F.project(:cut2)

      rows = fn confirmed ->
        for t <- plan.tables, c <- [%{column: t.key, encoding: :text} | t.columns] do
          [t.table, c.column, udt(c.encoding), "YES"]
        end ++ confirmed
      end

      check = fn confirmed ->
        {Loader, config} =
          Loader.target(project, query: fn _, _ -> {:ok, %{rows: rows.(confirmed)}} end)

        {:ok, diags} = Loader.check_schema(config, plan)

        Enum.map(
          diags,
          &{&1.code, &1.details[:column], &1.details[:missing] || &1.details[:actual]}
        )
      end

      assert check.([["user", "confirmed_at", "timestamp", "YES"]]) == []

      assert check.([]) == [{:load_schema_mismatch, "confirmed_at", :column}]

      assert check.([["user", "confirmed_at", "bool", "YES"]]) ==
               [{:load_schema_mismatch, "confirmed_at", "bool"}]

      assert check.([["user", "confirmed_at", "timestamp", "NO"]]) ==
               [{:load_schema_mismatch, "confirmed_at", :not_null}]
    end

    defp udt(:text), do: "text"
    defp udt(:float), do: "float8"
    defp udt(:datetime), do: "timestamp"
    defp udt({:array, e}), do: "_" <> udt(e)
    defp udt(_), do: "jsonb"
  end

  describe "upsert" do
    test "the users' confirmed_at: a nil keeps a stored value while the email is unchanged" do
      table = Plan.table(plan(:cut2), "user")

      keep =
        ~s[CASE WHEN EXCLUDED."confirmed_at" IS NULL AND t."email" IS NOT DISTINCT FROM ] <>
          ~s[EXCLUDED."email" THEN t."confirmed_at" ELSE EXCLUDED."confirmed_at" END]

      test = self()

      query = fn sql, _params ->
        send(test, {:sql, sql})
        {:ok, %{rows: []}}
      end

      {:ok, project} = F.project(:cut2)
      {Loader, config} = Loader.target(project, query: query)
      assert {:ok, _} = Loader.upsert(config, table, [%{"id" => "x"}])
      assert_received {:sql, sql}

      assert sql =~ ~s[INSERT INTO "public"."user" AS t (] and sql =~ ~s("confirmed_at")
      assert sql =~ ~s("confirmed_at" = ) <> keep
      # the same expression in the change guard
      [_, guard] = String.split(sql, "IS DISTINCT FROM ROW(")
      assert guard =~ keep
      assert sql =~ ~s("email" = EXCLUDED."email")

      # other tables are unaffected
      {:ok, _} = Loader.upsert(config, Plan.table(plan(:cut2), "card"), [%{"id" => "x"}])
      assert_received {:sql, card}
      refute card =~ "CASE"
    end

    test "one statement per batch, idempotent, counting what changed" do
      table = Plan.table(plan(:cut2), "card")
      sql = Loader.upsert_sql("public", table)

      assert sql =~ ~s(INSERT INTO "public"."card" AS t ("id", "created_date")
      assert sql =~ ~s[jsonb_populate_recordset(NULL::"public"."card", $1::text::jsonb)]
      assert sql =~ ~s[ON CONFLICT ("id") DO UPDATE SET "created_date" = EXCLUDED."created_date"]
      assert sql =~ "IS DISTINCT FROM"
      assert sql =~ "RETURNING (xmax = 0)"
      refute sql =~ "DELETE"

      test = self()

      query = fn sql, [json] ->
        send(test, {:query, sql, Jason.decode!(json)})
        {:ok, %{rows: [[true], [false]]}}
      end

      {:ok, project} = F.project(:cut2)
      {Loader, config} = Loader.target(project, query: query)
      rows = [%{"id" => "1x1"}, %{"id" => "1x2"}, %{"id" => "1x3"}]
      assert {:ok, %{inserted: 1, updated: 1, unchanged: 1}} = Loader.upsert(config, table, rows)
      assert_received {:query, ^sql, ^rows}
    end

    test "reads a column's values and clears it by key" do
      table = Plan.table(plan(:cut2), "user")
      test = self()

      query = fn sql, params ->
        send(test, {:query, sql, params})
        {:ok, %{rows: [["1x1", "a@example.test"]]}}
      end

      {:ok, project} = F.project(:cut2)
      {Loader, config} = Loader.target(project, query: query)
      assert {:ok, [{"1x1", "a@example.test"}]} = Loader.existing(config, table, "email")
      assert_received {:query, sql, []}
      assert sql =~ ~s(SELECT "id", "email"::text FROM "public"."user" WHERE "email" IS NOT NULL)

      assert :ok = Loader.clear(config, table, "email", ["1x1"])
      assert_received {:query, sql, [["1x1"]]}
      assert sql == ~s[UPDATE "public"."user" SET "email" = NULL WHERE "id" = ANY($1)]
      assert :ok = Loader.clear(config, table, "email", [])
      refute_received {:query, _, _}
    end

    test "join membership reads all owners and treats false flags as absent" do
      join = Enum.find(plan(:cut3).joins, &(&1.table == "favorite_project"))
      flag = Enum.find(join.sides, &(&1.kind == :flag))
      position = Enum.find(join.sides, &(&1.kind == :position))
      test = self()

      query = fn sql, params ->
        send(test, {:query, sql, params})
        {:ok, %{rows: [["1x1", "1x2"]]}}
      end

      {:ok, project} = F.project(:cut3)
      {Loader, config} = Loader.target(project, query: query)
      assert {:ok, [{"1x1", "1x2"}]} = Loader.join_members(config, join, flag, :all)
      assert_received {:query, flag_sql, []}
      assert flag_sql =~ ~s(WHERE "viewers_listed" = TRUE)
      refute flag_sql =~ "ANY($1)"

      assert {:ok, [{"1x1", "1x2"}]} = Loader.join_members(config, join, position, :all)
      assert_received {:query, position_sql, []}
      assert position_sql =~ ~s(WHERE "favorites_position" IS NOT NULL)
      refute position_sql =~ "ANY($1)"
    end

    test "quotes identifiers" do
      table = %Plan.Table{type: "x", table: ~s(we"ird), key: "id", columns: []}
      assert Loader.upsert_sql("public", table) =~ ~s("we""ird")
      assert Loader.upsert_sql("public", table) =~ "DO NOTHING"
    end

    test "errors name the PostgreSQL code, never the message or a value" do
      table = Plan.table(plan(:cut2), "user")

      query = fn _sql, _params ->
        {:error,
         %{
           __exception__: true,
           postgres: %{
             code: :unique_violation,
             constraint: "user_unique_email_index",
             message: "duplicate key",
             detail: "Key (email)=(ada@example.test) already exists."
           }
         }}
      end

      {:ok, project} = F.project(:cut2)
      {Loader, config} = Loader.target(project, query: query)
      assert {:error, error} = Loader.upsert(config, table, [%{"id" => "1x1"}])
      assert error.context.sqlstate == :unique_violation
      assert error.context.constraint == "user_unique_email_index"
      refute inspect(error) =~ "ada@example"
    end

    test "a raising query function is an error" do
      {:ok, project} = F.project(:cut2)

      {Loader, config} =
        Loader.target(project, query: fn _, _ -> raise ArgumentError, "secret" end)

      assert {:error, error} = Loader.identity(config)
      refute inspect(error) =~ "secret"
    end
  end

  describe "Convert" do
    defp field(source) do
      {type, nil} = Type.classify(source)
      %Field{id: "f", type: type, path: ""}
    end

    test "dates from ISO text or epoch milliseconds, at microsecond precision" do
      col = %Column{field: "f", column: "f", encoding: :datetime}

      assert {"2024-01-01T00:00:00.000000Z", []} =
               Convert.value(field("date"), col, 1_704_067_200_000, %{})

      assert {"2024-01-01T01:00:00.123000Z", []} =
               Convert.value(field("date"), col, "2024-01-01T02:00:00.123+01:00", %{})

      assert {nil, [{:load_type_mismatch, :not_a_date}]} =
               Convert.value(field("date"), col, "soon", %{})
    end

    test "integers only when integral" do
      col = %Column{field: "f", column: "f", encoding: :integer}
      assert {3, []} = Convert.value(field("number"), col, 3.0, %{})

      assert {nil, [{:load_type_mismatch, :not_integral}]} =
               Convert.value(field("number"), col, 3.5, %{})
    end

    test "text references: trimmed, empty is nil, non-IDs reported, dangling kept" do
      col = %Column{
        field: "f",
        column: "f",
        encoding: :text,
        text_ref: true,
        references: %{target: "user", cardinality: :one}
      }

      ctx = %{ids: %{"user" => MapSet.new(["1x1"])}}
      assert {"1x1", []} = Convert.value(field("text"), col, " 1x1\n", ctx)
      assert {nil, []} = Convert.value(field("text"), col, "  ", ctx)

      assert {nil, [{:load_invalid_reference, :not_an_id}]} =
               Convert.value(field("text"), col, "bob", ctx)

      assert {"2x2", [{:load_dangling_reference, :missing}]} =
               Convert.value(field("text"), col, "2x2", ctx)
    end

    test "an empty list is empty" do
      col = %Column{field: "f", column: "f", encoding: {:array, :text}}
      assert {nil, []} = Convert.value(field("list.text"), col, [], %{})

      assert {nil, [{:load_type_mismatch, :not_a_list}]} =
               Convert.value(field("list.text"), col, "a", %{})
    end

    test "record IDs" do
      assert Convert.record_id?("1700000000000x123")
      refute Convert.record_id?("admin_user_acme_test")
      refute Convert.record_id?(nil)
    end
  end
end
