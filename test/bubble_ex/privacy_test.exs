defmodule BubbleEx.PrivacyTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Error, Expression, Privacy, SampleHelper}
  alias BubbleEx.Expression.Diagnostic

  alias BubbleEx.Expression.Ast.{
    Check,
    Compare,
    CurrentUser,
    Field,
    ListOp,
    Logical,
    OptionValue,
    Raw,
    ThisThing
  }

  alias BubbleEx.Privacy.{DataType, Permissions, Rule}

  @app SampleHelper.load_json_sample("synthetic_privacy_export")

  defp parse!(app \\ @app) do
    {:ok, %Privacy{} = privacy} = Privacy.parse(app)
    privacy
  end

  defp type!(privacy, id), do: Enum.find(privacy.data_types, &(&1.id == id))
  defp rule!(privacy, type, id), do: Enum.find(type!(privacy, type).rules, &(&1.id == id))

  defp with_rule(rule), do: put_in(@app, ["user_types", "task", "privacy_role", "x_"], rule)

  describe "data types" do
    test "are sorted with availability that separates no rules from not supplied" do
      privacy = parse!()
      assert Enum.map(privacy.data_types, & &1.id) == ~w(note role task user workspace)

      assert %DataType{availability: :present, name: "Task", path: "/user_types/task"} =
               type!(privacy, "task")

      assert %DataType{availability: :none, rules: []} = type!(privacy, "note")
      assert privacy.diagnostics == []
    end

    test "live payload types (compact keys) are unavailable, not rule-free" do
      app = %{"user_types" => %{"task" => %{"%d" => "Task", "%f3" => %{}}}}
      assert %DataType{availability: :unavailable, name: "Task"} = type!(parse!(app), "task")
    end

    test "rules are ordered with the default rule last" do
      ids = Enum.map(type!(parse!(), "task").rules, & &1.id)
      assert ids == ~w(admins_ owner_ unassigned_ watchers_ workspace_public_ everyone)
    end
  end

  describe "rules" do
    test "carry name, comment, default flag and source path" do
      privacy = parse!()

      assert %Rule{name: "Members", comment: "Members see everything", default?: false} =
               rule!(privacy, "workspace", "members_")

      assert %Rule{default?: true, condition: nil, path: "/user_types/task/privacy_role/everyone"} =
               rule!(privacy, "task", "everyone")
    end

    test "conditions are typed ASTs with This Thing as the rule's type" do
      privacy = parse!()

      assert %Compare{
               op: :equals,
               left: %Field{builtin: :created_by, subject: %ThisThing{type: "custom.task"}},
               right: %CurrentUser{}
             } = rule!(privacy, "task", "owner_").condition

      assert %Logical{
               op: :and,
               left: %Compare{
                 left: %Field{
                   field: "workspace_custom_workspace",
                   subject: %Field{type: "custom.role"}
                 },
                 right: %Field{field: "workspace_custom_workspace", subject: %ThisThing{}}
               },
               right: %Check{op: :is_true, subject: %Field{field: "public_boolean"}}
             } = rule!(privacy, "task", "workspace_public_").condition

      assert %Logical{
               op: :and,
               left: %Check{op: :logged_in},
               right: %ListOp{op: :contains, arg: %CurrentUser{}}
             } =
               rule!(privacy, "task", "watchers_").condition

      assert %Logical{
               op: :or,
               left: %Compare{right: %OptionValue{option_set: "option.os_role", value: "admin"}}
             } =
               rule!(privacy, "task", "admins_").condition

      assert %Compare{right: %ThisThing{type: "user"}} = rule!(privacy, "user", "self_").condition
    end

    test "every condition round-trips to its source JSON" do
      privacy = parse!()

      for type <- privacy.data_types, rule <- type.rules, rule.condition do
        source = @app["user_types"][type.id]["privacy_role"][rule.id]["condition"]
        {:ok, encoded} = Expression.to_bubble(rule.condition)

        assert CanonicalJson.sha256(encoded) == CanonicalJson.sha256(source),
               "#{type.id}/#{rule.id}"
      end
    end

    test "non-default rule without a condition is diagnosed" do
      privacy = parse!(with_rule(%{"display" => "X", "permissions" => %{}}))

      assert [%Diagnostic{code: :missing_condition, path: "/user_types/task/privacy_role/x_"}] =
               privacy.diagnostics
    end

    test "unmodeled condition pieces are itemized, not dropped" do
      condition = %{
        "type" => "CurrentUser",
        "next" => %{"type" => "Message", "name" => "mystery", "args" => 1}
      }

      privacy = parse!(with_rule(%{"condition" => condition, "permissions" => %{}}))

      assert %Rule{condition: %Raw{reason: :unknown_operator, subject: %CurrentUser{}}} =
               rule!(privacy, "task", "x_")

      assert [
               %Diagnostic{
                 code: :unknown_operator,
                 path: "/user_types/task/privacy_role/x_/condition/next"
               }
             ] =
               privacy.diagnostics
    end

    test "a malformed rule is preserved raw" do
      privacy = parse!(with_rule("oops"))

      assert %Rule{condition: %Raw{raw: "oops", reason: :malformed_node}} =
               rule!(privacy, "task", "x_")

      assert [%Diagnostic{code: :malformed_node}] = privacy.diagnostics
    end

    test "unexpected rule members are diagnosed" do
      privacy = parse!(with_rule(%{"condition" => %{"type" => "CurrentUser"}, "priority" => 1}))

      assert [
               %Diagnostic{
                 code: :uninterpreted_field,
                 path: "/user_types/task/privacy_role/x_/priority"
               }
             ] =
               privacy.diagnostics
    end

    test "malformed privacy_role" do
      app = put_in(@app, ["user_types", "task", "privacy_role"], [])
      privacy = parse!(app)
      assert %DataType{availability: :unavailable, rules: []} = type!(privacy, "task")
      assert [%Diagnostic{code: :malformed_node}] = privacy.diagnostics
    end
  end

  describe "permissions" do
    test "flags and field visibility lists" do
      privacy = parse!()

      assert %Permissions{
               view_all: true,
               search_for: true,
               auto_binding: true,
               view_attachments: true,
               binding_fields: ["title_text", "public_boolean"],
               view_fields: nil,
               create_via_api: true,
               modify_via_api: true,
               delete_via_api: false,
               extra: %{}
             } = rule!(privacy, "task", "owner_").permissions

      assert %Permissions{
               view_all: false,
               search_for: true,
               auto_binding: false,
               view_attachments: true,
               view_fields: ["title_text", "workspace_custom_workspace"],
               create_via_api: nil
             } = rule!(privacy, "task", "workspace_public_").permissions

      assert %Permissions{view_all: false, search_for: false, view_fields: ["name_text"]} =
               rule!(privacy, "workspace", "everyone").permissions
    end

    test "each flag is read independently" do
      for {key, field} <- [
            {"view_all", :view_all},
            {"search_for", :search_for},
            {"auto_binding", :auto_binding},
            {"view_attachments", :view_attachments},
            {"create_api", :create_via_api},
            {"modify_api", :modify_via_api},
            {"delete_api", :delete_via_api}
          ],
          value <- [true, false] do
        privacy =
          parse!(
            with_rule(%{
              "condition" => %{"type" => "CurrentUser"},
              "permissions" => %{key => value}
            })
          )

        assert Map.fetch!(rule!(privacy, "task", "x_").permissions, field) == value
        assert privacy.diagnostics == []
      end
    end

    test "invalid and unmodeled permissions are kept and diagnosed" do
      perms = %{"view_all" => "yes", "view_fields" => %{"a" => "x"}, "export" => true}

      privacy =
        parse!(with_rule(%{"condition" => %{"type" => "CurrentUser"}, "permissions" => perms}))

      assert %Permissions{view_all: nil, view_fields: nil, extra: ^perms} =
               rule!(privacy, "task", "x_").permissions

      assert Enum.map(privacy.diagnostics, &{&1.code, &1.path}) == [
               {:unknown_permission, "/user_types/task/privacy_role/x_/permissions/export"},
               {:invalid_permission, "/user_types/task/privacy_role/x_/permissions/view_all"},
               {:invalid_permission, "/user_types/task/privacy_role/x_/permissions/view_fields"}
             ]
    end

    test "field lists may be arrays" do
      perms = %{"view_fields" => ["a", "b"]}

      privacy =
        parse!(with_rule(%{"condition" => %{"type" => "CurrentUser"}, "permissions" => perms}))

      assert %Permissions{view_fields: ["a", "b"]} = rule!(privacy, "task", "x_").permissions
    end
  end

  test "parsing is deterministic" do
    assert parse!() == parse!()

    hashes = fn privacy ->
      for t <- privacy.data_types,
          r <- t.rules,
          r.condition,
          do: elem(Expression.sha256(r.condition), 1)
    end

    assert hashes.(parse!()) == hashes.(parse!(@app |> Jason.encode!() |> Jason.decode!()))
  end

  test "input errors" do
    assert {:error, %Error{kind: :invalid_input}} = Privacy.parse(%{"pages" => %{}})
    assert {:error, %Error{kind: :invalid_input}} = Privacy.parse(%{"user_types" => []})
    assert {:error, %Error{kind: :invalid_input}} = Privacy.parse("app")
  end
end
