defmodule BubbleEx.Test.PrivacyCrossCheck do
  @moduledoc false

  # The interpreter (BubbleEx.Verify.Interpreter) against the compiled Ash
  # policies' fixtures (WTF-382). The hand-authored expectation tables
  # (test/support/expression/expectations/privacy.json and
  # test/support/target/ash/expectations/policies.json) hold records as
  # rows of the fixture's Ash attributes; this reads them back into an
  # interpreter Dataset through the mapped Project (attribute -> Bubble field
  # ID), and renders interpreter verdicts in the tables' shape (visible
  # attributes, "all" when every attribute is). Used by
  # BubbleEx.Verify.InterpreterTest and by
  # scripts/ash_compile_check/render.exs, which writes the verdicts for
  # policies.exs to compare with what PostgreSQL reads through the
  # generated policies.

  alias BubbleEx.Model
  alias BubbleEx.Model.Type
  alias BubbleEx.Verify.Interpreter
  alias BubbleEx.Verify.Interpreter.Dataset

  @doc "The Dataset of the table's `records` (type => rows)."
  def dataset(model, project, rows) do
    records =
      for {type, list} <- rows, row <- list do
        resource = resource(project, type)
        attrs = Map.new(resource.attributes, &{&1.name, &1})
        pk = Enum.find(resource.attributes, & &1.primary_key?).name

        fields =
          for {name, value} <- row,
              name != pk,
              %{source: %{field: field}} <- [Map.fetch!(attrs, name)],
              {:ok, %{type: t}} = Model.field(model, type, field),
              v = value(t, value),
              v != nil,
              into: %{},
              do: {field, v}

        {row[pk], type, fields}
      end

    {:ok, ds} = Dataset.new(records)
    ds
  end

  defp value(_type, nil), do: nil

  defp value(%Type{cardinality: :many} = t, list) when is_list(list) do
    case Enum.map(list, &value(%{t | cardinality: :one}, &1)) do
      [] -> nil
      items -> {:list, items}
    end
  end

  defp value(%Type{kind: :ref}, id), do: {:ref, id}
  defp value(%Type{kind: :option}, key), do: {:option, key}
  defp value(%Type{kind: :file_ref, base: base}, url), do: {base, url}
  defp value(%Type{base: :text}, s), do: {:text, s}
  defp value(%Type{base: :number}, n), do: {:number, n / 1}
  defp value(%Type{base: :boolean}, b), do: {:boolean, b}

  defp resource(project, type), do: Enum.find(project.resources, &(&1.source.type == type))

  @doc "Non-key attribute names of type `type`'s resource, by Bubble field ID."
  def attributes(project, type) do
    for a <- resource(project, type).attributes,
        not a.primary_key?,
        a.source[:field],
        into: %{},
        do: {a.source.field, a.name}
  end

  @doc """
  The interpreter's verdicts for `persona` on every record of `type`
  in `ds`, in the policies table's shape: `get` = viewable records with
  their visible attributes ("all" when every attribute is); `search` =
  searchable records likewise. A record whose gate is unknown maps to
  "unknown"; one whose gate holds but some fields are unknown to
  `%{"known" => attrs, "unknown" => attrs}`.
  """
  def reads(interpreter, project, ds, type, action, persona) do
    user = if persona == "logged_out", do: nil, else: persona
    attrs = attributes(project, type)
    all = attrs |> Map.values() |> Enum.sort()

    for key <- Dataset.keys(ds, type),
        {:ok, access} = Interpreter.access(interpreter, ds, user, key),
        entry = entry(access, action, attrs, all),
        entry != :hidden,
        into: %{},
        do: {key, entry}
  end

  defp entry(access, action, attrs, all) do
    gate = if action == "search", do: access.searchable, else: access.visible

    # A record found by search shows the fields the user may view.
    fields = if access.visible == true, do: access.fields, else: []
    names = names(fields, attrs)

    cond do
      gate == :unknown ->
        "unknown"

      gate == false ->
        :hidden

      access.unknown_fields != [] ->
        %{"known" => names, "unknown" => names(access.unknown_fields, attrs)}

      names == all ->
        "all"

      true ->
        names
    end
  end

  defp names(fields, attrs), do: fields |> Enum.flat_map(&List.wrap(attrs[&1])) |> Enum.sort()

  @doc """
  Compares interpreter `reads/6` with a table's `expected` (both `%{record
  => "all" | [attr]}`). Returns `{agree, disagree, unknown}` lists of
  `{record, interpreter, table}`. Where the interpreter cannot decide, the
  table must deny (the policies deny what an unsupported rule would
  decide): an "unknown" record must be hidden, and of a partly known one
  exactly the known fields visible; those count as `unknown`, anything
  else as a disagreement.
  """
  def compare(interpreter_reads, expected) do
    keys = (Map.keys(interpreter_reads) ++ Map.keys(expected)) |> Enum.uniq() |> Enum.sort()

    Enum.reduce(keys, {[], [], []}, fn key, {agree, disagree, unknown} ->
      mine = Map.get(interpreter_reads, key, :hidden)
      theirs = Map.get(expected, key, :hidden)
      entry = {key, mine, theirs}

      cond do
        mine == "unknown" and theirs == :hidden ->
          {agree, disagree, [entry | unknown]}

        is_map(mine) and normalize(theirs) == mine["known"] ->
          {agree, disagree, [entry | unknown]}

        normalize(mine) == normalize(theirs) ->
          {[entry | agree], disagree, unknown}

        true ->
          {agree, [entry | disagree], unknown}
      end
    end)
  end

  defp normalize(list) when is_list(list), do: Enum.sort(list)
  defp normalize(other), do: other

  @conditions "test/support/expression/expectations/privacy.json"
  @policies "test/support/target/ash/expectations/policies.json"

  @doc """
  The interpreter's verdicts on both expectation tables, for the Ash
  harness to compare with what PostgreSQL selects (written by
  scripts/ash_compile_check/render.exs as interpreter_conditions.json and
  interpreter_policies.json):

    * conditions: per table case, per actor, the records the rule's
      condition selects (or "unknown")
    * policies: per `get` / `search` read of the policy table, per
      persona, `reads/6`
  """
  def harness_verdicts do
    %{conditions: condition_verdicts(), policies: policy_verdicts()}
  end

  defp condition_verdicts do
    {model, _project, doc, ds} = load(@conditions)
    {:ok, interpreter} = Interpreter.new(model)

    for %{"type" => type, "rule" => rule, "expected" => expected} <- doc["cases"] do
      verdicts =
        Map.new(expected, fn {actor, _} ->
          {actor, selected(interpreter, ds, user(actor), type, rule)}
        end)

      %{"type" => type, "rule" => rule, "verdicts" => verdicts}
    end
  end

  defp policy_verdicts do
    {model, project, doc, ds} = load(@policies)
    {:ok, interpreter} = Interpreter.new(model)

    for %{"type" => type, "action" => action, "expected" => expected} <- doc["reads"],
        action in ["get", "search"] do
      verdicts =
        Map.new(expected, fn {persona, _} ->
          {persona, interpreter |> reads(project, ds, type, action, persona) |> json()}
        end)

      %{"type" => type, "action" => action, "verdicts" => verdicts}
    end
  end

  defp load(table) do
    {:ok, model} = table |> app_for() |> Model.build()
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :unverified)
    doc = table |> File.read!() |> Jason.decode!()
    {model, project, doc, dataset(model, project, doc["records"])}
  end

  defp user("logged_out"), do: nil
  defp user(id), do: id

  defp app_for(@conditions), do: File.read!("test/support/expression/app.json") |> Jason.decode!()

  defp app_for(@policies),
    do: File.read!("test/support/target/ash/policies.json") |> Jason.decode!()

  defp selected(interpreter, ds, user, type, rule) do
    results =
      for key <- Dataset.keys(ds, type),
          do: {key, Interpreter.condition(interpreter, ds, user, type, rule, key)}

    if Enum.any?(results, &match?({_, {:unknown, _}}, &1)),
      do: "unknown",
      else: for({key, {:ok, true, _}} <- results, do: key)
  end

  defp json(reads), do: Map.reject(reads, fn {_, v} -> v == :hidden end)
end
