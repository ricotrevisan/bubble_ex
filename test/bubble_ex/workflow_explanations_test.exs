defmodule BubbleEx.WorkflowExplanationsTest do
  use ExUnit.Case, async: true
  alias BubbleEx.Workflows

  @page "bubbleex_explain_91"
  @workflow "bphznajk"
  @path ["pages", @page, "workflows", @workflow]

  defp fixture,
    do: File.read!("test/support/workflows/editor_conditions_data.json") |> Jason.decode!()

  defp workflow(payload) do
    {:ok, %{workflows: [workflow]}} = Workflows.inventory(payload)
    workflow
  end

  test "editor-verified create/change assignments, grouped conditions, flags and prior result" do
    p = fixture()
    w = workflow(p)
    assert w.ordering == "numeric_keys"
    assert Enum.map(w.actions, & &1.id) == ~w(bpomiami bpomiamj bpomiamk)
    assert w.event.description.status == "fully_supported"
    [condition] = w.event.conditions
    assert condition.expression.operator == "and_"
    [left, right] = condition.expression.children
    assert left.operator == "equals"
    assert right.operator == "or_"
    assert Enum.at(right.children, 1).operator == "greater_than"
    assert condition.text =~ "current page's record's \"owner\" [owner_user] is current user"
    assert [%{raw: true, text: "workflow_disabled: true"}] = w.event.description.flags

    [create, change, previous] = w.actions
    assert Enum.all?(w.actions, &(&1.description.status == "fully_supported"))
    assignments = create.description.intent.assignments.children

    assert Enum.map(assignments, & &1.field.raw) ==
             ~w(status_text owner_user count_number enabled_boolean)

    assert Enum.map(assignments, & &1.value.raw) == [
             "Draft",
             %{"type" => "CurrentUser"},
             0,
             false
           ]

    assert change.description.intent.text =~ "set \"status\" [status_text] = \"Done\""
    assert [%{text: text}] = change.conditions
    assert text =~ "is \"Draft\""
    assert [%{raw: false, status: "fully_supported"}] = previous.conditions
    assert previous.description.intent.target.text =~ "result of action"
    assert hd(previous.description.intent.assignments.children).value.raw == ""
    assert [%{raw: true}] = previous.description.flags
    assert_source(p, w)
  end

  test "equivalent compact payload retains keys, names, operands and assignment operation" do
    p = compact(fixture())
    w = workflow(p)
    assert w.event.description.status == "fully_supported"
    assert Enum.all?(w.actions, &(&1.description.status == "fully_supported"))
    assert w.event.conditions |> hd() |> Map.fetch!(:path) |> String.ends_with?("/%p/%c")
    assert_source(p, w)
  end

  test "unknown nested operator is explicit without flattening the supported boolean group" do
    p = fixture()

    raw = %{
      "type" => "CurrentUser",
      "next" => %{"type" => "Message", "name" => "unverified_owns", "args" => [false, nil, 0, ""]}
    }

    p = put_in(p, @path ++ ["properties", "condition", "next", "next", "next", "args"], raw)
    [c] = workflow(p).event.conditions
    assert c.status == "partial"
    assert c.expression.operator == "and_"
    assert c.text =~ "Unsupported operator"
    assert Enum.at(c.expression.children, 1).raw == raw
    refute c.text =~ "owns this"
    assert_source(p, workflow(p))
  end

  test "null, empty, zero and false conditions remain distinct from absence" do
    for value <- [nil, "", 0, false, true, [], %{}] do
      p = put_in(fixture(), @path ++ ["properties", "condition"], value)
      [c] = workflow(p).event.conditions
      assert c.raw === value
      assert c.status == "fully_supported" == is_boolean(value)
      assert_source(p, workflow(p))
    end

    p = update_in(fixture(), @path ++ ["properties"], &Map.delete(&1, "condition"))
    assert workflow(p).event.conditions == []
  end

  test "all supplied assignment values survive including explicit null and missing value" do
    for value <- [nil, "", 0, false, true, %{"type" => "Future", "raw" => [nil, false]}] do
      p =
        put_in(fixture(), @path ++ ["actions", "1", "properties", "changes", "0", "value"], value)

      a = Enum.at(workflow(p).actions, 1).description.intent.assignments.children |> hd()
      assert a.value.raw === value
      assert_source(p, workflow(p))
    end

    p =
      update_in(
        fixture(),
        @path ++ ["actions", "1", "properties", "changes", "0"],
        &Map.delete(&1, "value")
      )

    a = Enum.at(workflow(p).actions, 1).description.intent.assignments.children |> hd()
    assert a.value.status == "unavailable"
    refute Map.has_key?(a.value, :raw)
  end

  test "unproven field operation and unknown action properties preclude full support" do
    p =
      put_in(
        fixture(),
        @path ++ ["actions", "1", "properties", "changes", "0", "action_kind"],
        "add"
      )

    p = put_in(p, @path ++ ["actions", "1", "properties", "create_if_missing"], true)
    action = Enum.at(workflow(p).actions, 1)
    assert action.description.status == "partial"
    assert action.description.intent.text =~ "Unproven assignment operation"
    assert [%{raw: true}] = action.description.uninterpreted
    assert_source(p, workflow(p))
  end

  test "missing schema, malformed fields and duplicate data identities do not invent field names" do
    p = update_in(fixture(), ["user_types"], &Map.delete(&1, "explanation_task_91"))
    assert hd(workflow(p).actions).description.status == "partial"
    refute hd(workflow(p).actions).explanation =~ "set \"status\""
    p = put_in(fixture(), ["user_types", "explanation_task_91", "fields", "status_text"], false)
    assert hd(workflow(p).actions).description.status == "partial"

    p =
      put_in(fixture(), ["user_types", "duplicate"], %{
        "id" => "explanation_task_91",
        "display" => "Wrong Task"
      })

    action = hd(workflow(p).actions)
    assert action.description.intent.target.reference.status == "ambiguous"
    refute action.explanation =~ "Wrong Task"
  end

  test "element captions retain IDs and ambiguous/missing element references stay explicit" do
    p = fixture()

    p =
      put_in(p, ["pages", @page, "elements", "duplicate"], %{
        "id" => "bpomiamg",
        "name" => "Wrong"
      })

    assert workflow(p).event.description.intent.children
           |> hd()
           |> Map.fetch!(:reference)
           |> Map.fetch!(:status) == "ambiguous"

    refute workflow(p).event.explanation =~ "Wrong"
    p = put_in(fixture(), ["pages", @page, "elements"], %{})
    assert workflow(p).event.explanation =~ "bpomiamg"
    assert workflow(p).event.explanation =~ "unavailable"
  end

  test "previous-step identity alone cannot prove earlier order" do
    for id <- ["missing", "bpomiamk"] do
      p =
        put_in(
          fixture(),
          @path ++ ["actions", "2", "properties", "to_change", "properties", "action_id"],
          id
        )

      target = Enum.at(workflow(p).actions, 2).description.intent.target
      refute target.status == "fully_supported"
    end

    p =
      update_in(fixture(), @path ++ ["actions"], fn actions ->
        Map.put(Map.delete(actions, "0"), "first", actions["0"])
      end)

    assert workflow(p).ordering == "unresolved"

    assert Enum.at(workflow(p).actions, 1).description.intent.target.reference.status ==
             "unresolved_order"
  end

  test "malformed collections, operands, aliases and entries never drop raw data or crash" do
    for value <- [nil, false, 0, "", [], %{"bad" => nil}, %{"01" => %{}, "1" => %{}}] do
      p = put_in(fixture(), @path ++ ["actions", "0", "properties", "initial_values"], value)
      assert_source(p, workflow(p))
    end

    p = put_in(fixture(), @path ++ ["actions", "0", "properties", "%tt"], "custom.conflict")
    assert hd(workflow(p).actions).description.status == "partial"

    p =
      put_in(fixture(), @path ++ ["properties", "condition"], %{
        "type" => "CurrentUser",
        "%x" => "Future",
        "next" => nil
      })

    refute hd(workflow(p).event.conditions).status == "fully_supported"
    assert_source(p, workflow(p))
  end

  test "text expressions preserve numeric entry order and dynamic unknown subtrees" do
    value = %{
      "type" => "TextExpression",
      "entries" => %{"10" => "!", "2" => %{"type" => "CurrentUser"}, "0" => "Hello "}
    }

    p =
      put_in(
        fixture(),
        @path ++ ["actions", "0", "properties", "initial_values", "0", "value"],
        value
      )

    e = hd(hd(workflow(p).actions).description.intent.assignments.children).value
    assert Enum.map(e.children, & &1.raw) == ["Hello ", %{"type" => "CurrentUser"}, "!"]
    assert e.status == "fully_supported"

    p =
      put_in(
        p,
        @path ++ ["actions", "0", "properties", "initial_values", "0", "value", "entries", "bad"],
        false
      )

    assert hd(hd(workflow(p).actions).description.intent.assignments.children).value.status ==
             "unresolved"
  end

  test "versioned reports visibly separate event/action conditions and count supplied explanations" do
    assert {:ok, a} = Workflows.render(fixture())
    assert a.inventory.schema_version == 3
    assert a.inventory.explanation_coverage.conditions == %{"fully_supported" => 3}
    assert a.inventory.explanation_coverage.data_actions == %{"fully_supported" => 3}
    assert a.inventory.coverage.workflow_entries == 1
    assert a.inventory.coverage.action_entries == 3
    assert a.markdown =~ "Event only when"
    assert a.markdown =~ "Action only when"
    assert a.markdown =~ "workflow\\_disabled: true"
    assert a.markdown =~ "Done"
    assert a.markdown =~ "Explanation source"
    assert a.markdown =~ "/fields/status\\_text"
  end

  test "bare nonboolean references and malformed boolean operands are not unconditional conditions" do
    for value <- [
          %{"type" => "CurrentUser"},
          %{"type" => "CurrentPageItem"},
          %{"type" => "TextExpression", "entries" => ["yes"]}
        ] do
      p = put_in(fixture(), @path ++ ["properties", "condition"], value)
      assert hd(workflow(p).event.conditions).status == "unresolved"
    end

    for message <- [
          %{"type" => "Message", "name" => "equals"},
          %{"type" => "Message", "name" => "is_true", "args" => false}
        ] do
      p =
        put_in(fixture(), @path ++ ["properties", "condition"], %{
          "type" => "CurrentUser",
          "next" => message
        })

      refute hd(workflow(p).event.conditions).status == "fully_supported"
      assert_source(p, workflow(p))
    end
  end

  test "unknown metadata, simultaneous conditions and caption aliases remain explicit" do
    p = put_in(fixture(), @path ++ ["only_when"], false)
    assert length(workflow(p).event.conditions) == 2
    assert workflow(p).event.description.status == "partial"

    p =
      put_in(
        fixture(),
        ["user_types", "explanation_task_91", "fields", "status_text", "%d"],
        "Misleading"
      )

    action = hd(workflow(p).actions)
    refute action.description.status == "fully_supported"
    refute action.explanation =~ "Misleading"
    p = put_in(fixture(), @path ++ ["actions", "2", "properties", "action_disabled"], nil)
    assert [%{status: "unresolved", raw: nil}] = Enum.at(workflow(p).actions, 2).description.flags
    assert_source(p, workflow(p))
  end

  test "second editor-verified example covers every vocabulary operator with named and compact keys" do
    p = File.read!("test/support/workflows/editor_operators.json") |> Jason.decode!()

    for source <- [p, compact(p)] do
      w = workflow(source)
      assert w.event.description.status == "fully_supported"
      assert hd(w.actions).description.status == "fully_supported"
      text = hd(w.event.conditions).text

      for token <- [
            "is not",
            "is empty",
            "is not empty",
            "<=",
            ">=",
            "is yes",
            "is no",
            "is logged out"
          ] do
        assert text =~ token
      end

      assert_source(source, w)
    end
  end

  test "previous-step type inference stops at conflicting creation properties" do
    p =
      put_in(fixture(), @path ++ ["actions", "0", "properties", "type_to_create"], "custom.wrong")

    target = Enum.at(workflow(p).actions, 2).description.intent.target
    assert target.data_type == nil
    assert Enum.at(workflow(p).actions, 2).description.status == "partial"
    assert_source(p, workflow(p))
  end

  test "array action order and unknown page scope preserve references without guessing" do
    p = update_in(fixture(), @path ++ ["actions"], fn a -> [a["0"], a["1"], a["2"]] end)
    assert workflow(p).ordering == "array_order"
    assert Enum.at(workflow(p).actions, 2).description.intent.target.status == "fully_supported"
    assert_source(p, workflow(p))
    p = update_in(fixture(), ["pages", @page, "properties"], &Map.delete(&1, "page_item_type"))
    assert Enum.at(workflow(p).actions, 1).description.intent.target.status == "unavailable"
  end

  defp compact(map) when is_map(map) do
    aliases = %{
      "pages" => "%p3",
      "workflows" => "%wf",
      "properties" => "%p",
      "type" => "%x",
      "condition" => "%c",
      "next" => "%n",
      "args" => "%a",
      "name" => "%nm",
      "display" => "%d",
      "fields" => "%f3",
      "key" => "%k",
      "value" => "%v",
      "initial_values" => "%i2",
      "thing_type" => "%tt",
      "changes" => "%cs",
      "to_change" => "%tc",
      "element_id" => "%ei",
      "action_id" => "%ai"
    }

    Map.new(map, fn {key, value} -> {Map.get(aliases, key, key), compact(value)} end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value

  defp assert_source(_, %BubbleEx.Diagnostic{}), do: :ok

  defp assert_source(payload, node) when is_map(node) do
    if Map.has_key?(node, :path) and Map.has_key?(node, :raw) do
      assert BubbleEx.Workflows.ExplanationContext.at_pointer(payload, node.path) === node.raw
    end

    Enum.each(node, fn {key, value} -> if key != :raw, do: assert_source(payload, value) end)
  end

  defp assert_source(payload, list) when is_list(list),
    do: Enum.each(list, &assert_source(payload, &1))

  defp assert_source(_, _), do: :ok
end
