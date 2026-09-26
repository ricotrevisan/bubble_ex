defmodule BubbleEx.Db.OneInterpretationTest do
  # WTF-365: `BubbleEx.Model` (with `BubbleEx.Privacy`, which it builds on) is
  # the one interpretation of data types, fields, option sets and API
  # Connector types. Outside them nothing in lib/ may read the app JSON's
  # data-model members or pattern-match a Bubble type descriptor, except the
  # files listed in @allowed, each with its reason. The Model never depends on
  # `BubbleEx.Db`, so there is no cycle.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @interpreters ["lib/bubble_ex/model", "lib/bubble_ex/privacy"]

  # Data-model members in both key forms: as string literals, in ~w() lists or
  # as atoms (`Map.get(x, :db_value)` on decoded-with-atoms JSON). API
  # Connector parameter collections hold credentials: only the Model reads
  # them (WTF-396).
  @keys ~w(%f3 %v %d %del default_val sort_factor attributes values user_types option_sets
           fields display value deleted db_value apiconnector2 client_safe
           url_params body_params shared_headers shared_params)

  # file (or directory) => why it may use those members or descriptors.
  @allowed %{
    "lib/bubble_ex/expression/" =>
      "expression value types (`list.` wrapping of expression results) and the expression key aliases, not definitions",
    "lib/bubble_ex/db/reader.ex" =>
      "emits its own `db_value` / `display` key columns; reads nothing from the app JSON",
    "lib/bubble_ex/db/encoder.ex" => "builds JSON pointers for diagnostics on hand-built db maps",
    "lib/bubble_ex/db/encoder/names.ex" =>
      "builds JSON pointers for name diagnostics on tables and hand-built db maps",
    "lib/bubble_ex/db/convex.ex" => "a comment naming the `db_value` key column",
    "lib/bubble_ex/target/ash.ex" =>
      "the Ash name map's own JSON members (`attributes`, `fields`)",
    "lib/bubble_ex/target/ash/project.ex" => "the Ash name map's own JSON members",
    "lib/bubble_ex/target/ash/decisions.ex" =>
      "rename overrides of the Ash name map's own JSON members (`attributes`)",
    "lib/bubble_ex/app_tree/" =>
      "splits the payload into files by section and counts section entries; CSS `display`",
    "lib/bubble_ex/editor" =>
      "editor write plans address raw app JSON by path; plugin schemas and versions have their own `display`/`value`/`fields`",
    "lib/bubble_ex/frontend/" =>
      "element and CSS properties (`display`, `value`), not the data model",
    "lib/bubble_ex/workflows/node.ex" => "classifies a JSON pointer's section (`user_types`)",
    "lib/bubble_ex/workflows/explanation.ex" =>
      "workflow action parameters' own `key`/`value` members, not fields",
    "lib/bubble_ex/index/plugins.ex" =>
      "installed plugin IDs and versions under `client_safe.plugins`, not API Connector types",
    "lib/bubble_ex/apps/parser.ex" =>
      "app settings under `client_safe` (plugins, meta tags), not API Connector types",
    "lib/bubble_ex/verify/observation.ex" =>
      "the verification observation format's own members (`value`, `values`, `fields`, `deleted`); reads no app JSON",
    "lib/bubble_ex/verify/replay/client.ex" =>
      "the Bubble Data API search constraint's `value` member; reads no app JSON",
    "lib/bubble_ex/verify/recording.ex" =>
      "the recording format's observation members (`value`, `values`); reads no app JSON",
    "lib/bubble_ex/verify/scenario.ex" =>
      "the scenario format's `input` op `value` member; reads no app JSON",
    "lib/bubble_ex/verify/seed.ex" =>
      "the seed format's record `fields` member; reads no app JSON"
  }

  defp sources do
    for file <- Path.wildcard("lib/**/*.ex"),
        not Enum.any?(
          @interpreters,
          &(file in [&1 <> ".ex"] or String.starts_with?(file, &1 <> "/"))
        ),
        do: file
  end

  defp allowed?(file), do: Enum.any?(Map.keys(@allowed), &String.starts_with?(file, &1))

  # Known blind spots (the patterns below miss them): whole literal
  # descriptors (`"list.text"`), `String.replace_prefix(x, "custom.", …)` and
  # descriptors built by interpolation (`"api.apiconnector2.#{g}.#{c}"`). As
  # of WTF-380 they occur in lib/bubble_ex/findings/id_in_text.ex (`"list.text"`),
  # lib/bubble_ex/index/subject.ex (interpolation), lib/bubble_ex/db/dbml.ex
  # and lib/bubble_ex/workflows/node.ex (`replace_prefix`), besides
  # lib/bubble_ex/expression/ (allowlisted) and comments. Widening the check
  # to them means routing those through `BubbleEx.Model.Type` first.
  defp patterns do
    keys = Enum.map_join(@keys, "|", &Regex.escape/1)

    [
      # "user_types", "%f3", ...
      Regex.compile!(~s/"(?:#{keys})"/),
      # ~w(display %d), ~w(fields %f3)
      Regex.compile!(~s/~w[(\\[{<|][^)\\]}>|]*?(?<![\\w%])(?:#{keys})(?![\\w])/),
      # :db_value, :user_types (atom keys)
      ~r/(?<![\w:]):(?:db_value|user_types|option_sets|default_val|sort_factor)\b/,
      # "custom." <> id, "list." <> item in a pattern or match?/2
      ~r/"(?:list|custom|option|api)\.[^"]*"\s*<>\s*[a-z_]/,
      # String.starts_with?(descriptor, "custom.")
      ~r/starts_with\?\([^)]*"(?:list|custom|option|api)\./
    ]
  end

  defp hits(file) do
    source = File.read!(file)
    for pattern <- patterns(), [match] <- Regex.scan(pattern, source), do: match
  end

  test "only the Model and Privacy read data-model members or type descriptors" do
    offenders =
      for file <- sources(), not allowed?(file), (found = hits(file)) != [], do: {file, found}

    assert offenders == []
  end

  test "every allowlist entry is still needed" do
    for prefix <- Map.keys(@allowed) do
      assert Enum.any?(sources(), &(String.starts_with?(&1, prefix) and hits(&1) != [])),
             "#{prefix} no longer reads data-model members; drop it from @allowed"
    end
  end

  test "the check sees the Model's own reading" do
    assert hits("lib/bubble_ex/model/builder.ex") != []
    assert hits("lib/bubble_ex/model/connector_reader.ex") != []
    assert hits("lib/bubble_ex/model/type.ex") != []
  end

  test "the Reader reads through the Model" do
    assert "lib/bubble_ex/model.ex" in dependencies("lib/bubble_ex/db/reader.ex")
  end

  test "the Model does not depend on BubbleEx.Db" do
    for file <- ["lib/bubble_ex/model.ex" | Path.wildcard("lib/bubble_ex/model/**/*.ex")],
        dep <- dependencies(file) do
      refute String.starts_with?(dep, "lib/bubble_ex/db/"), "#{file} depends on #{dep}"
    end
  end

  defp dependencies(file) do
    output =
      capture_io(fn ->
        Mix.Task.rerun("xref", ["graph", "--source", file, "--format", "plain", "--no-compile"])
      end)

    ~r{lib/\S+\.ex}
    |> Regex.scan(output)
    |> List.flatten()
    |> Enum.uniq()
  end
end
