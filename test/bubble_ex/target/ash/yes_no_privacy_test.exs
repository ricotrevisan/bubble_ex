defmodule BubbleEx.Target.Ash.YesNoPrivacyTest do
  # WTF-529 reads an empty yes/no as no in page searches and conditions,
  # as Bubble does. The privacy policies keep the stricter reading (the
  # owner's decision of 2026-09-29: `x is no` needs a stored no,
  # `BubbleEx.Verify.Difference`, `empty_yes_no_is_no`). This golden holds
  # the policy compilation of every yes/no comparison form, recorded
  # before WTF-529, and must stay byte-identical: the compiled rule
  # conditions of a synthetic app, the policy, field-policy and
  # calculation blocks of its rendered resources (privacy: :unverified
  # and :enforced; only those, so unrelated renderer changes leave it
  # alone), the policy path (`Expressions.filter/3`) on IR forms a rule
  # cannot write (an input, a negated bare yes/no), and the compiled
  # conditions of the expression and policy fixtures. All data is
  # invented.
  #
  # Regenerate only for an intended change to the policies:
  #
  #     BUBBLE_EX_UPDATE_GOLDEN=1 mix test test/bubble_ex/target/ash/yes_no_privacy_test.exs
  use ExUnit.Case, async: true

  alias BubbleEx.Expression.IR
  alias BubbleEx.Model
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.{Expressions, Source}

  @golden "test/support/target/ash/golden/yes_no_privacy"
  @fixtures ["test/support/expression/app.json", "test/support/target/ash/policies.json"]

  defp flag(name), do: %{"type" => "Message", "name" => name}

  defp this(next), do: %{"type" => "InjectedValue", "next" => next}

  defp user(next), do: %{"type" => "CurrentUser", "next" => next}

  # `This Thing's <field>` followed by `rest`.
  defp field(name, rest \\ nil),
    do: this(if(rest, do: Map.put(flag(name), "next", rest), else: flag(name)))

  defp op(name, args), do: %{"type" => "Message", "name" => name, "args" => args}

  # Every yes/no comparison form a privacy rule can hold.
  @conditions [
    {"is_yes", &__MODULE__.c_is_yes/0},
    {"is_no", &__MODULE__.c_is_no/0},
    {"is_no_is_no", &__MODULE__.c_is_no_is_no/0},
    {"eq_yes", &__MODULE__.c_eq_yes/0},
    {"eq_no", &__MODULE__.c_eq_no/0},
    {"neq_yes", &__MODULE__.c_neq_yes/0},
    {"neq_no", &__MODULE__.c_neq_no/0},
    {"eq_field", &__MODULE__.c_eq_field/0},
    {"neq_field", &__MODULE__.c_neq_field/0},
    {"bare", &__MODULE__.c_bare/0},
    {"empty", &__MODULE__.c_empty/0},
    {"not_empty", &__MODULE__.c_not_empty/0},
    {"user_is_no", &__MODULE__.c_user_is_no/0},
    {"eq_user", &__MODULE__.c_eq_user/0},
    {"eq_condition", &__MODULE__.c_eq_condition/0},
    {"is_no_or_archived", &__MODULE__.c_is_no_or_archived/0},
    {"parent_is_no", &__MODULE__.c_parent_is_no/0},
    {"parent_eq_no", &__MODULE__.c_parent_eq_no/0},
    {"eq_parent", &__MODULE__.c_eq_parent/0},
    {"default_is_no", &__MODULE__.c_default_is_no/0},
    {"default_neq_yes", &__MODULE__.c_default_neq_yes/0},
    {"user_bare", &__MODULE__.c_user_bare/0},
    {"user_neq_no", &__MODULE__.c_user_neq_no/0}
  ]

  def c_is_yes, do: field("done_boolean", flag("is_true"))
  def c_is_no, do: field("done_boolean", flag("is_false"))

  def c_is_no_is_no,
    do: field("done_boolean", Map.put(flag("is_false"), "next", flag("is_false")))

  def c_eq_yes, do: field("done_boolean", op("equals", true))
  def c_eq_no, do: field("done_boolean", op("equals", false))
  def c_neq_yes, do: field("done_boolean", op("not_equals", true))
  def c_neq_no, do: field("done_boolean", op("not_equals", false))
  def c_eq_field, do: field("done_boolean", op("equals", field("archived_boolean")))
  def c_neq_field, do: field("done_boolean", op("not_equals", field("archived_boolean")))
  def c_bare, do: field("done_boolean")
  def c_empty, do: field("done_boolean", flag("is_empty"))
  def c_not_empty, do: field("done_boolean", flag("is_not_empty"))
  def c_user_is_no, do: user(Map.put(flag("admin_boolean"), "next", flag("is_false")))
  def c_eq_user, do: field("done_boolean", op("equals", user(flag("admin_boolean"))))

  def c_eq_condition,
    do: field("done_boolean", op("equals", field("title_text", flag("is_empty"))))

  def c_is_no_or_archived,
    do:
      field(
        "done_boolean",
        Map.put(flag("is_false"), "next", op("or_", field("archived_boolean")))
      )

  def c_parent_is_no,
    do: field("parent_custom_task", Map.put(flag("done_boolean"), "next", flag("is_false")))

  def c_parent_eq_no,
    do: field("parent_custom_task", Map.put(flag("done_boolean"), "next", op("equals", false)))

  def c_eq_parent,
    do: field("done_boolean", op("equals", field("parent_custom_task", flag("done_boolean"))))

  # `(This Thing's done defaulting to This Thing's archived) is no`
  def c_default_is_no,
    do:
      field(
        "done_boolean",
        Map.put(op("defaulting_to", field("archived_boolean")), "next", flag("is_false"))
      )

  def c_default_neq_yes,
    do:
      field(
        "done_boolean",
        Map.put(op("defaulting_to", field("archived_boolean")), "next", op("not_equals", true))
      )

  def c_user_bare, do: user(flag("admin_boolean"))
  def c_user_neq_no, do: user(Map.put(flag("admin_boolean"), "next", op("not_equals", false)))

  defp app do
    rules =
      Map.new(@conditions, fn {name, fun} ->
        {name <> "_",
         %{
           "display" => name,
           "condition" => fun.(),
           "permissions" => %{
             "auto_binding" => false,
             "search_for" => true,
             "view_all" => true,
             "view_attachments" => false
           }
         }}
      end)

    %{
      "_id" => "yes-no-privacy",
      "option_sets" => %{},
      "pages" => %{},
      "element_definitions" => %{},
      "user_types" => %{
        "user" => %{
          "display" => "User",
          "fields" => %{"admin_boolean" => %{"display" => "Admin", "value" => "boolean"}}
        },
        "task" => %{
          "display" => "Task",
          "fields" => %{
            "title_text" => %{"display" => "Title", "value" => "text"},
            "done_boolean" => %{"display" => "Done", "value" => "boolean"},
            "archived_boolean" => %{"display" => "Archived", "value" => "boolean"},
            "parent_custom_task" => %{"display" => "Parent", "value" => "custom.task"}
          },
          "privacy_role" =>
            Map.put(rules, "everyone", %{
              "display" => "everyone",
              "permissions" => %{
                "auto_binding" => false,
                "search_for" => false,
                "view_all" => false,
                "view_attachments" => false
              }
            })
        }
      }
    }
  end

  defp check_golden(name, actual) do
    path = Path.join(@golden, name)

    if System.get_env("BUBBLE_EX_UPDATE_GOLDEN") do
      File.mkdir_p!(@golden)
      File.write!(path, actual)
    end

    assert File.exists?(path), "missing golden #{path}; set BUBBLE_EX_UPDATE_GOLDEN=1"
    assert actual == File.read!(path)
  end

  # Every rule's compiled condition, printed, one per line.
  defp conditions(app) do
    {:ok, model} = Model.build(app)
    {:ok, project} = Ash.map(model, [], privacy: :unverified)
    {:ok, rules} = Expressions.privacy(model, project)

    Enum.map_join(rules, fn %{type: type, rule: rule, expr: expr} ->
      "#{type}/#{rule}: #{if expr, do: Source.expr(expr), else: "(not compiled)"}\n"
    end)
  end

  test "every yes/no form of the synthetic app compiles to its golden condition" do
    out = conditions(app())
    # Each form compiles (the golden is not vacuous).
    for {name, _} <- @conditions, do: assert(out =~ ~r"task/#{name}_: (?!\(not compiled\))")
    check_golden("conditions.txt", out)
  end

  for privacy <- [:unverified, :enforced] do
    @privacy privacy
    test "the synthetic app renders its golden policies (privacy: #{privacy})" do
      {:ok, model} = Model.build(app())
      {:ok, project} = Ash.map(model, [], privacy: @privacy)
      {:ok, source} = Source.render(project)
      out = blocks(source)
      assert out =~ "policies do"
      check_golden("#{@privacy}.ex.txt", out)
    end
  end

  # The `policies`, `field_policies` and `calculations` blocks of each
  # rendered module, under its name.
  defp blocks(source) do
    {out, _module, _in_block} =
      source
      |> String.split("\n")
      |> Enum.reduce({[], nil, false}, fn line, {out, module, in_block} ->
        cond do
          String.starts_with?(line, "defmodule ") ->
            {out, line, false}

          line in ["  policies do", "  field_policies do", "  calculations do"] ->
            {[line, "# " <> module | out], module, true}

          in_block and line == "  end" ->
            {[line | out], module, false}

          in_block ->
            {[line | out], module, true}

          true ->
            {out, module, false}
        end
      end)

    out |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")
  end

  # The policy path on IR a rule cannot write: `filter/3` (what
  # `Target.Ash.Policies` calls), inputs allowed.
  test "the policy path compiles IR forms to its golden filters" do
    {:ok, model} = Model.build(app())
    {:ok, project} = Ash.map(model, [], privacy: :unverified)
    this = IR.node(:this, [:rule_record], "custom.task")
    done = IR.node(:field, [this, "task", "done_boolean"], "boolean")
    archived = IR.node(:field, [this, "task", "archived_boolean"], "boolean")
    parent = IR.node(:field, [this, "task", "parent_custom_task"], "custom.task")
    parent_done = IR.node(:field, [parent, "task", "done_boolean"], "boolean")
    input = IR.node(:input, [:parameter, %{"key" => "flag"}], "boolean")

    admin =
      IR.node(:field, [IR.node(:current_user, [], "user"), "user", "admin_boolean"], "boolean")

    fallback = IR.node(:fallback, [done, archived], "boolean")
    yes = IR.node(:literal, [true], "boolean")
    no = IR.node(:literal, [false], "boolean")

    cases = [
      {"not_done", IR.node(:not, [done], "boolean")},
      {"not_parent_done", IR.node(:not, [parent_done], "boolean")},
      {"not_admin", IR.node(:not, [admin], "boolean")},
      {"not_fallback", IR.node(:not, [fallback], "boolean")},
      {"parent_done_eq_no", IR.node(:eq, [parent_done, no], "boolean")},
      {"fallback_eq_no", IR.node(:eq, [fallback, no], "boolean")},
      {"fallback_neq_yes", IR.node(:neq, [fallback, yes], "boolean")},
      {"input", input},
      {"input_eq_no", IR.node(:eq, [input, no], "boolean")},
      {"input_neq_yes", IR.node(:neq, [input, yes], "boolean")},
      {"done_eq_input", IR.node(:eq, [done, input], "boolean")},
      {"done_neq_input", IR.node(:neq, [done, input], "boolean")},
      {"admin_eq_no", IR.node(:eq, [admin, no], "boolean")},
      {"done_eq_admin", IR.node(:eq, [done, admin], "boolean")},
      {"done_neq_admin", IR.node(:neq, [done, admin], "boolean")}
    ]

    out =
      Enum.map_join(cases, fn {name, ir} ->
        {:ok, %{expr: expr, diagnostics: diags}} =
          Expressions.filter(ir, project, resource: "task", inputs: :arguments)

        assert diags == [], name
        "#{name}: #{Source.expr(expr)}\n"
      end)

    check_golden("filters.txt", out)
  end

  test "the expression and policy fixtures compile to their golden conditions" do
    out =
      Enum.map_join(@fixtures, fn path ->
        "# #{path}\n" <> (path |> File.read!() |> Jason.decode!() |> conditions())
      end)

    check_golden("fixtures.txt", out)
  end
end
