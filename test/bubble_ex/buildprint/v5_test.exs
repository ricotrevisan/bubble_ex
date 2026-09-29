defmodule BubbleEx.Buildprint.V5Test do
  # Synthetic Buildprint v5 workspaces: each test writes a tiny
  # `.buildprint/index.sqlite` (and `state.json`) under its ExUnit tmp_dir.
  use ExUnit.Case, async: true

  alias BubbleEx.{Diagnostic, Error, Model}
  alias BubbleEx.Buildprint.V5
  alias BubbleEx.Test.SplitExport
  alias Exqlite.Sqlite3

  @moduletag :tmp_dir

  @handle ~s|secret("$bpSfixturehandle")|

  # A preamble in Buildprint's shape: whole app object, pages and reusable
  # elements as stubs (`condition: true` placeholders, no actions), plus
  # Buildprint's own members.
  defp preamble do
    %{
      "_id" => "fixture-app",
      "user_types" => %{
        "user" => %{"display" => "User", "fields" => %{}},
        "task" => %{"display" => "Task (stub)", "fields" => %{}}
      },
      "option_sets" => %{"status" => %{"display" => "Status", "values" => %{}}},
      "pages" => %{
        "pg1" => %{
          "id" => "pg1id",
          "name" => "index",
          "elements" => %{"e1" => %{"id" => "e1", "type" => "Text"}},
          "workflows" => %{"w1" => %{"condition" => true}}
        }
      },
      "element_definitions" => %{
        "r1" => %{"id" => "r1", "name" => "header", "type" => "CustomDefinition"}
      },
      "api" => %{
        "b1" => %{"id" => "b1", "type" => "APIEvent", "properties" => %{"wf_name" => "ping"}}
      },
      "styles" => %{},
      "settings" => %{"client_safe" => %{"apiconnector2" => %{}, "text" => "keep"}},
      "_index" => %{"id_to_path" => %{"pg1id" => "pages.pg1"}},
      "__bp_plugins__" => %{"plugin-1" => %{"human" => "Toolbox"}},
      "__bp_secure_presence__" => %{"version" => 1, "groups" => %{}},
      "__bp_secure_presence_verified__" => true
    }
  end

  defp fragments do
    [
      {"data-types/task.ts",
       %{
         "user_types" => %{
           "task" => %{
             "display" => "Task",
             "fields" => %{
               "title_text" => %{"display" => "Title", "value" => "text"},
               "owner_user" => %{"display" => "Owner", "value" => "user"}
             },
             "privacy_role" => %{
               "everyone" => %{"display" => "Everyone else", "permissions" => %{}}
             }
           }
         }
       }},
      {"data-types/user.ts",
       %{
         "user_types" => %{
           "user" => %{
             "display" => "User",
             "fields" => %{"name_text" => %{"display" => "Name", "value" => "text"}}
           }
         }
       }},
      {"option-sets/status.ts",
       %{
         "option_sets" => %{
           "status" => %{
             "display" => "Status",
             "values" => %{"open" => %{"display" => "Open", "sort_factor" => 1}}
           }
         }
       }},
      {"pages/index.ts",
       %{
         "pages" => %{
           "pg1" => %{
             "id" => "pg1id",
             "name" => "index",
             "type" => "Page",
             "elements" => %{"e1" => %{"id" => "e1", "type" => "Text"}},
             "workflows" => %{
               "w1" => %{
                 "type" => "ButtonClicked",
                 "condition" => %{"type" => "CurrentUser"},
                 "actions" => %{}
               }
             }
           }
         }
       }},
      {"reusable-elements/header.ts",
       %{
         "element_definitions" => %{
           "r1" => %{
             "id" => "r1",
             "name" => "header",
             "type" => "CustomDefinition",
             "workflows" => %{"rw1" => %{"type" => "CustomEvent", "actions" => %{}}}
           }
         },
         "comments" => %{"c1" => %{"type" => "comment", "content" => "note"}}
       }},
      {"backend-workflows/ping.ts",
       %{
         "api" => %{
           "b1" => %{
             "id" => "b1",
             "type" => "APIEvent",
             "properties" => %{"wf_name" => "ping"},
             "actions" => %{}
           }
         }
       }},
      {"api-connector/Service.ts",
       %{
         "settings" => %{
           "client_safe" => %{
             "apiconnector2" => %{
               "g1" => %{
                 "human" => "Service",
                 "calls" => %{
                   "c1" => %{"name" => "Get", "method" => "get", "url" => "https://example.com/x"}
                 }
               }
             }
           }
         }
       }}
    ]
  end

  # Symbol counts for `preamble/0` + `fragments/0`.
  @symbols %{
    "dataType" => 2,
    "field" => 3,
    "optionSet" => 1,
    "page" => 1,
    "apiCall" => 1,
    "workflow" => 3,
    "element" => 1
  }

  defp write_workspace(dir, opts \\ []) do
    ws = Path.join(dir, Keyword.get(opts, :name, "workspace"))
    bp = Path.join(ws, ".buildprint")
    File.mkdir_p!(bp)

    metadata =
      Map.merge(
        %{
          "formatVersion" => "bubblescript-31",
          "schemaVersion" => "16",
          "snapshotJsonSha256" => String.duplicate("0", 64)
        },
        Keyword.get(opts, :metadata, %{})
      )

    rows =
      [
        {"__preamble__", Keyword.get(opts, :preamble, preamble())}
        | Keyword.get(opts, :fragments, fragments())
      ]
      |> Enum.map(fn {key, doc} ->
        json = if is_binary(doc), do: doc, else: Jason.encode!(doc)
        {key, json, sha256(json)}
      end)

    manifest =
      Keyword.get_lazy(opts, :manifest, fn ->
        %{
          "version" => 5,
          "snapshotJsonSha256" => metadata["snapshotJsonSha256"],
          "roots" =>
            for(
              {key, _, sha} <- rows,
              do: %{"rootKey" => key, "identityKey" => key, "contentSha256" => sha}
            )
        }
      end)

    manifest_json = Jason.encode!(manifest)
    rows = rows ++ [{"__manifest__", manifest_json, sha256(manifest_json)}]
    rows = Keyword.get(opts, :tamper, & &1).(rows)

    {:ok, conn} = Sqlite3.open(Path.join(bp, "index.sqlite"))

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE metadata (key text PRIMARY KEY NOT NULL, value text NOT NULL);
      CREATE TABLE snapshot_roots (root_key text PRIMARY KEY NOT NULL, identity_key text NOT NULL,
        json text NOT NULL, content_sha256 text NOT NULL);
      """)

    unless Keyword.get(opts, :drop_symbols, false) do
      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE symbols (symbol_key text PRIMARY KEY NOT NULL, kind text NOT NULL,
          namespace text NOT NULL, owner_key text, display text, bubble_key text NOT NULL,
          module_path text NOT NULL, raw_path text NOT NULL, deleted integer NOT NULL);
        """)

      for {kind, n} <- Keyword.get(opts, :symbols, @symbols), i <- 1..n//1 do
        insert(conn, "INSERT INTO symbols VALUES (?, ?, '', NULL, NULL, '', '', '[]', 0)", [
          "#{kind}-#{i}",
          kind
        ])
      end
    end

    for {k, v} <- metadata, do: insert(conn, "INSERT INTO metadata VALUES (?, ?)", [k, v])

    for {key, json, sha} <- rows,
        do: insert(conn, "INSERT INTO snapshot_roots VALUES (?, ?, ?, ?)", [key, key, json, sha])

    :ok = Sqlite3.close(conn)

    case Keyword.get(opts, :state, %{"formatVersion" => "bubblescript-31", "kind" => "app"}) do
      nil -> :ok
      state -> File.write!(Path.join(bp, "state.json"), Jason.encode!(state))
    end

    ws
  end

  defp insert(conn, sql, args) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(statement, args)
    :done = Sqlite3.step(conn, statement)
    :ok = Sqlite3.release(conn, statement)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp codes(%V5{diagnostics: diagnostics}), do: Enum.map(diagnostics, & &1.code)

  describe "load/2" do
    test "merges fragments onto the preamble, fragments winning", %{tmp_dir: dir} do
      assert {:ok, %V5{app: app} = result} = dir |> write_workspace() |> V5.load()

      assert result.format_version == "bubblescript-31"
      assert result.schema_version == "16"

      # Stubs replaced by the fragments' full definitions.
      assert app["user_types"]["task"]["display"] == "Task"
      assert map_size(app["user_types"]["task"]["fields"]) == 2
      assert app["pages"]["pg1"]["workflows"]["w1"]["condition"] == %{"type" => "CurrentUser"}
      assert app["element_definitions"]["r1"]["workflows"]["rw1"]["type"] == "CustomEvent"
      assert app["settings"]["client_safe"]["apiconnector2"]["g1"]["calls"]["c1"]["name"] == "Get"
      # Preamble members no fragment touches are kept.
      assert app["settings"]["client_safe"]["text"] == "keep"
      assert app["comments"]["c1"]["content"] == "note"
      assert app["_id"] == "fixture-app"

      # Buildprint's own members are dropped.
      refute Enum.any?(Map.keys(app), &(&1 == "_index" or String.starts_with?(&1, "__bp")))

      assert result.counts == %{
               "data_types" => 2,
               "fields" => 3,
               "option_sets" => 1,
               "pages" => 1,
               "api_calls" => 1,
               "workflows" => 3
             }

      assert result.counts == result.symbol_counts
      assert codes(result) == [:buildprint_snapshot_unverified]
      assert result.snapshot == %{expected: String.duplicate("0", 64), reproduced: false}

      summary = Model.summary(result.model)
      assert summary["data_types"] == 2
      assert summary["fields"] == 3
      assert summary["privacy_rules"] == 1
      assert summary["api_calls"] == 1
    end

    test "a snapshot hash equal to the merged app's canonical JSON is reproduced",
         %{tmp_dir: dir} do
      {:ok, first} = dir |> write_workspace(name: "a") |> V5.load()
      sha = BubbleEx.CanonicalJson.sha256(first.app)

      {:ok, again} =
        dir |> write_workspace(name: "b", metadata: %{"snapshotJsonSha256" => sha}) |> V5.load()

      assert again.snapshot.reproduced
      refute :buildprint_snapshot_unverified in codes(again)
    end

    test "a fragment replaces its definition whole: deleted flags come from the fragment",
         %{tmp_dir: dir} do
      preamble =
        preamble()
        |> put_in(["user_types", "gone"], %{
          "display" => "Gone",
          "fields" => %{},
          "deleted" => true
        })
        |> put_in(["option_sets", "old"], %{"display" => "Old", "values" => %{}})

      fragments =
        fragments() ++
          [
            # Restored in the editor: the fragment has no deleted flag.
            {"data-types/gone.ts",
             %{"user_types" => %{"gone" => %{"display" => "Gone", "fields" => %{}}}}},
            # Deleted since: the flag survives, as in a `.bubble` export.
            {"option-sets/old.ts",
             %{
               "option_sets" => %{
                 "old" => %{
                   "display" => "Old",
                   "deleted" => true,
                   "values" => %{"v" => %{"display" => "V", "deleted" => true}}
                 }
               }
             }}
          ]

      symbols = Map.merge(@symbols, %{"dataType" => 3, "optionSet" => 2})

      {:ok, %V5{app: app} = result} =
        dir
        |> write_workspace(preamble: preamble, fragments: fragments, symbols: symbols)
        |> V5.load()

      refute Map.has_key?(app["user_types"]["gone"], "deleted")
      assert app["option_sets"]["old"]["deleted"] == true
      assert result.counts["option_sets"] == 2
      refute :buildprint_count_mismatch in codes(result)

      summary = Model.summary(result.model)
      assert summary["deleted_data_types"] == 0
      assert summary["deleted_option_sets"] == 1
      assert summary["deleted_option_values"] == 1
    end

    test "reports preamble stubs no fragment completes", %{tmp_dir: dir} do
      preamble =
        preamble()
        |> put_in(["pages", "pg2"], %{
          "id" => "pg2id",
          "name" => "orphan",
          "workflows" => %{"w" => %{"condition" => true}}
        })
        |> put_in(["element_definitions", "r2"], %{"id" => "r2", "name" => "orphan"})
        # Bubble's own non-object member of element_definitions.
        |> put_in(["element_definitions", "length"], 3)

      {:ok, %V5{app: app} = result} =
        dir |> write_workspace(preamble: preamble) |> V5.load()

      assert app["pages"]["pg2"]["name"] == "orphan"

      stubs = Enum.filter(result.diagnostics, &(&1.code == :buildprint_stub_unresolved))

      assert Enum.map(stubs, &{&1.path, &1.details}) == [
               {"/element_definitions", %{section: "element_definitions", count: 1}},
               {"/pages", %{section: "pages", count: 1}}
             ]

      assert %{"pages" => 2, "workflows" => 4} = result.counts
      assert :buildprint_count_mismatch in codes(result)
    end

    test "reports each count that differs from the symbols index", %{tmp_dir: dir} do
      symbols = Map.merge(@symbols, %{"field" => 5, "apiCall" => 0})
      {:ok, result} = dir |> write_workspace(symbols: symbols) |> V5.load()

      mismatches =
        for %Diagnostic{code: :buildprint_count_mismatch} = d <- result.diagnostics,
            do: {d.path, d.details}

      assert mismatches == [
               {"/symbols/api_calls", %{kind: "api_calls", loaded: 1, symbols: 0}},
               {"/symbols/fields", %{kind: "fields", loaded: 3, symbols: 5}}
             ]
    end

    test "opens the index read-only and leaves the workspace unchanged", %{tmp_dir: dir} do
      ws = write_workspace(dir)
      bp = Path.join(ws, ".buildprint")
      index = Path.join(bp, "index.sqlite")
      before = {File.read!(index), File.stat!(index).mtime, File.ls!(bp) |> Enum.sort()}

      File.chmod!(index, 0o444)
      File.chmod!(bp, 0o555)
      on_exit(fn -> File.chmod(bp, 0o755) end)

      assert {:ok, _} = V5.load(ws)
      assert {:ok, _} = V5.load(bp)

      assert {File.read!(index), File.stat!(index).mtime, File.ls!(bp) |> Enum.sort()} == before
    end

    test "reads paths holding URI syntax", %{tmp_dir: dir} do
      ws = write_workspace(dir, name: "odd ?name#x%20&mode=rw")
      assert {:ok, %V5{counts: %{"data_types" => 2}}} = V5.load(ws)
    end
  end

  describe "versions" do
    test "an unknown formatVersion fails loudly", %{tmp_dir: dir} do
      ws = write_workspace(dir, metadata: %{"formatVersion" => "bubblescript-32"})

      assert {:error, %Error{kind: :unknown_format, context: context}} = V5.load(ws)
      assert context.value == "bubblescript-32"
      assert context.supported == ["bubblescript-31"]
    end

    test "an unknown schemaVersion fails loudly", %{tmp_dir: dir} do
      ws = write_workspace(dir, metadata: %{"schemaVersion" => "17"})

      assert {:error, %Error{kind: :unknown_format, context: %{field: "schemaVersion"}}} =
               V5.load(ws)
    end

    test "state.json must agree with the index", %{tmp_dir: dir} do
      ws = write_workspace(dir, state: %{"formatVersion" => "bubblescript-30"})
      assert {:error, %Error{kind: :unknown_format}} = V5.load(ws)
    end

    test "state.json is optional", %{tmp_dir: dir} do
      assert {:ok, _} = dir |> write_workspace(state: nil) |> V5.load()
    end

    test "an unknown manifest version fails loudly", %{tmp_dir: dir} do
      ws = write_workspace(dir, manifest: %{"version" => 6, "roots" => []})
      assert {:error, %Error{kind: :unknown_format, context: %{value: "6"}}} = V5.load(ws)
    end

    test "a hostile version value is not echoed", %{tmp_dir: dir} do
      ws = write_workspace(dir, metadata: %{"formatVersion" => @handle})
      assert {:error, %Error{kind: :unknown_format} = error} = V5.load(ws)
      refute inspect(error) =~ "$bp"
    end
  end

  describe "integrity" do
    test "a row whose JSON does not match its content hash fails", %{tmp_dir: dir} do
      tamper = fn rows ->
        Enum.map(rows, fn
          {"__preamble__", json, sha} ->
            {"__preamble__", String.replace(json, "Task (stub)", "Task!"), sha}

          row ->
            row
        end)
      end

      assert {:error, %Error{kind: :parse_failed}} =
               dir |> write_workspace(tamper: tamper) |> V5.load()
    end

    test "a row the manifest does not list fails", %{tmp_dir: dir} do
      extra = ~s({"user_types":{"x":{"display":"X","fields":{}}}})
      tamper = &(&1 ++ [{"data-types/x.ts", extra, sha256(extra)}])

      assert {:error, %Error{kind: :parse_failed}} =
               dir |> write_workspace(tamper: tamper) |> V5.load()
    end

    test "a missing manifest, preamble or symbols table fails", %{tmp_dir: dir} do
      no_manifest = &Enum.reject(&1, fn {key, _, _} -> key == "__manifest__" end)
      no_preamble = &Enum.reject(&1, fn {key, _, _} -> key == "__preamble__" end)

      for {name, opts} <- [
            a: [tamper: no_manifest],
            b: [tamper: no_preamble],
            c: [drop_symbols: true]
          ] do
        assert {:error, %Error{kind: :parse_failed}} =
                 dir |> write_workspace([name: to_string(name)] ++ opts) |> V5.load()
      end
    end

    test "invalid JSON in a fragment fails", %{tmp_dir: dir} do
      fragments = fragments() ++ [{"data-types/bad.ts", "{not json"}]

      assert {:error, %Error{kind: :parse_failed}} =
               dir |> write_workspace(fragments: fragments) |> V5.load()
    end
  end

  describe "hostile input" do
    test "ignores foreign sections, drops secrets and never echoes keys or values",
         %{tmp_dir: dir} do
      preamble =
        preamble()
        |> Map.put("pages", "not an object")
        |> put_in(["settings", "secure"], %{"api_key" => "sk-live-preamble-value"})

      fragments =
        fragments() ++
          [
            {"weird/array.ts", [1, 2, 3]},
            {"weird/scalar.ts", "\"just a string\""},
            {"weird/foreign.ts",
             %{
               "_index" => %{"id_to_path" => %{}},
               "__bp_plugins__" => %{"p" => %{}},
               "history" => %{"entry" => %{"secret" => "sk-live-history"}},
               "user_types" => "not an object",
               "settings" => %{
                 "secure" => %{"token" => "sk-live-fragment-value"},
                 "client_safe" => %{
                   "apiconnector2" => %{
                     "g2" => %{
                       "human" => "Other",
                       "calls" => %{
                         "c2" => %{
                           "name" => "Call",
                           "headers" => %{"h" => %{"key" => "Authorization", "value" => @handle}}
                         }
                       },
                       "shared_headers" => %{@handle => %{"value" => "x"}}
                     }
                   }
                 }
               }
             }},
            {"weird/keys.ts",
             %{
               "option_sets" => %{
                 "../../etc/passwd" => %{"display" => "Traversal", "values" => %{}},
                 "" => %{"display" => "Empty", "values" => %{}},
                 "~1/%2F\u0000" => %{"display" => "Pointer", "values" => %{}},
                 "status" => %{"display" => "Status again", "values" => %{}}
               }
             }}
          ]

      symbols = Map.merge(@symbols, %{"optionSet" => 4, "apiCall" => 2})

      {:ok, %V5{app: app} = result} =
        dir
        |> write_workspace(preamble: preamble, fragments: fragments, symbols: symbols)
        |> V5.load()

      # Only app sections are written, only client_safe settings kept.
      refute Map.has_key?(app, "history")
      refute Map.has_key?(app, "_index")
      assert Map.keys(app["settings"]) == ["client_safe"]
      assert is_map(app["user_types"]["task"])
      # A fragment's page replaces a malformed preamble section.
      assert is_map(app["pages"]["pg1"])
      # Hostile keys are data: kept as keys, never interpreted as paths.
      assert Map.has_key?(app["option_sets"], "../../etc/passwd")
      assert app["option_sets"]["status"]["display"] == "Status again"

      call = app["settings"]["client_safe"]["apiconnector2"]["g2"]["calls"]["c2"]
      assert call["headers"]["h"]["value"] == ""
      assert app["settings"]["client_safe"]["apiconnector2"]["g2"]["shared_headers"] == %{}

      by_code = Map.new(result.diagnostics, &{&1.code, &1.details})
      assert by_code[:buildprint_fragment_ignored] == %{count: 6}
      assert by_code[:buildprint_fragment_overlap] == %{count: 1}
      assert by_code[:buildprint_settings_dropped] == %{count: 2}
      assert by_code[:buildprint_secret_handle] == %{count: 2}

      assert {:ok, _model} = Model.build(app)

      text = inspect(result.diagnostics) <> Jason.encode!(result.diagnostics)

      for leaked <- ["$bp", "sk-live", "etc/passwd", "Traversal", "Other", "Authorization"],
          do: refute(text =~ leaked, "diagnostics echo #{leaked}")

      refute inspect(app) =~ "$bp"
      refute inspect(app) =~ "sk-live"
    end
  end

  describe "entry points" do
    test "workspace? detects a workspace or its .buildprint directory", %{tmp_dir: dir} do
      ws = write_workspace(dir)
      assert V5.workspace?(ws)
      assert V5.workspace?(Path.join(ws, ".buildprint"))
      refute V5.workspace?(dir)
      refute V5.workspace?(Path.join(dir, "missing"))
    end

    test "a directory that is not a workspace is invalid input", %{tmp_dir: dir} do
      assert {:error, %Error{kind: :invalid_input}} = V5.load(dir)
    end

    test "the private-export loader auto-detects v5 workspaces", %{tmp_dir: dir} do
      ws = write_workspace(dir)
      assert SplitExport.format(ws) == :buildprint_v5
      assert SplitExport.load(ws) == elem(V5.load(ws), 1).app

      split = Path.join(dir, "split")
      File.mkdir_p!(Path.join(split, "data_types/t"))
      File.write!(Path.join(split, "data_types/t/type.json"), ~s({"display":"T","fields":{}}))
      assert SplitExport.format(split) == :split_export
      assert %{"user_types" => %{"t" => _}} = SplitExport.load(split)
    end

    test "the SQLite dependency is available in this project" do
      assert V5.available?()
    end
  end

  describe "merge/2" do
    test "is pure and needs no SQLite" do
      {app, diagnostics} = V5.merge(preamble(), Enum.map(fragments(), &elem(&1, 1)))
      assert app["user_types"]["task"]["display"] == "Task"
      assert diagnostics == []
    end
  end
end
