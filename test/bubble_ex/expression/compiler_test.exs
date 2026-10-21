defmodule BubbleEx.Expression.CompilerTest do
  # The stack-neutral IR (WTF-368): one case per construct over the
  # synthetic expression fixture, the negative cases with their
  # diagnostics, and determinism.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Expression.{Compiler, IR}

  defp compile(raw, opts \\ []) do
    env = env(opts)
    {:ok, result} = Compiler.compile(parse!(raw, env), env)
    result
  end

  # The IR without source paths (those are tested on their own).
  defp ir(raw, opts \\ []) do
    %{ir: %IR{} = ir, diagnostics: []} = compile(raw, opts)
    IR.strip_paths(ir)
  end

  defp n(op, args, type), do: IR.node(op, args, type)
  defp user, do: n(:current_user, [], "user")
  defp lit(v, t), do: n(:literal, [v], t)

  defp input_value,
    do: n(:input, [:element_state, %{"element" => "bI1", "state" => "get_data"}], "number")

  describe "sources and fields" do
    test "field chains through records, with Bubble IDs" do
      assert ir(
               chain(cu(), [msg("active_membership_custom_membership"), msg("team_custom_team")])
             ) ==
               n(
                 :field,
                 [
                   n(
                     :field,
                     [user(), "user", "active_membership_custom_membership"],
                     "custom.membership"
                   ),
                   "membership",
                   "team_custom_team"
                 ],
                 "custom.team"
               )
    end

    test "This Thing in a privacy rule and built-in fields" do
      env = rule_env("task")
      {:ok, %{ir: ir}} = Compiler.compile(parse!(chain(this(), [msg("Created By")]), env), env)

      assert IR.strip_paths(ir) ==
               n(:field, [n(:this, [:rule_record], "custom.task"), "task", "Created By"], "user")

      assert %IR{path: "/next", args: [%IR{path: ""} | _]} = ir
    end

    test "options carry their stored key; attributes and labels" do
      assert ir(opt("status", "done")) == n(:option, ["status", "done", "done"], "option.status")

      assert %IR{op: :option_attribute, args: [_, "status", "color"], type: "text"} =
               ir(chain(opt("status", "done"), [msg("color")]))

      assert %IR{op: :option_label, args: [_, "status"]} =
               ir(chain(opt("status", "done"), [msg("display")]))
    end

    # WTF-495: the editor's "All <set>" is an option value "all values".
    test "an option value of \"all values\" is every option of the set" do
      assert ir(opt("status", "all values")) == n(:all_options, ["status"], "list.option.status")

      filtered =
        chain(opt("status", "all values"), [
          msg("filtered", nil, %{
            "constraints" => %{
              "0" => %{
                "key" => "_advanced_search_constraint",
                "constraint_type" => %{"type" => "Empty"},
                "value" => chain(this(), [msg("urgent"), msg("is_true")])
              }
            }
          })
        ])

      assert %IR{
               op: :filter,
               args: [%IR{op: :all_options}, %IR{op: :eq, args: [%IR{op: :option_attribute}, _]}],
               type: "list.option.status"
             } = ir(filtered, searches: :page)
    end

    test "context sources become inputs named by Bubble IDs" do
      assert ir(chain(el("bI1"), [msg("get_data")])) ==
               n(:input, [:element_state, %{"element" => "bI1", "state" => "get_data"}], "number")

      assert %IR{
               op: :field,
               args: [%IR{op: :input, args: [:element_state, %{"element" => "bG1"}]} | _]
             } =
               ir(chain(src("ElementParent"), [msg("title_text")]), host: "bT1")

      assert %IR{
               op: :field,
               args: [%IR{op: :input, args: [:cell_thing, %{"element" => "bR1"}]} | _]
             } =
               ir(chain(src("CurrentDataItem"), [msg("title_text")]), host: "bT3")
    end

    test "dynamic text concatenates parts" do
      assert ir(text(["Hi ", chain(cu(), [msg("name_text")])])) ==
               n(
                 :concat,
                 [lit("Hi ", "text"), n(:field, [user(), "user", "name_text"], "text")],
                 "text"
               )

      assert ir(text(["plain"])) == lit("plain", "text")
    end
  end

  describe "operators" do
    test "comparisons, checks and boolean operators" do
      raw =
        chain(cu(), [
          msg("logged_in"),
          msg("and_", chain(cu(), [msg("admin_boolean"), msg("is_true")])),
          msg("or_", chain(cu(), [msg("name_text"), msg("is_not_empty")]))
        ])

      assert %IR{
               op: :or,
               args: [%IR{op: :and, args: [%IR{op: :logged_in}, %IR{op: :eq}]}, %IR{op: :not}]
             } =
               ir(raw)

      assert %IR{op: :gt, type: "boolean"} =
               ir(chain(cu(), [msg("name_text"), msg("greater_than", "a")]))

      assert %IR{op: :neq} = ir(chain(cu(), [msg("name_text"), msg("not_equals", "a")]))
    end

    test "list operators" do
      list = chain(cu(), [msg("teams_list_custom_team")])
      assert %IR{op: :count, type: "number"} = ir(chain(list, [msg("count")]))

      assert %IR{op: :member, args: [%IR{op: :field}, %IR{op: :this}]} =
               ir(chain(list, [msg("contains", this())]))

      assert %IR{op: :not, args: [%IR{op: :member}]} =
               ir(chain(list, [msg("not_contains", this())]))

      assert %IR{op: :first, type: "custom.team"} = ir(chain(list, [msg("first_element")]))
    end

    test "arithmetic, text operators and fallback" do
      assert %IR{op: :add, type: "number"} =
               ir(chain(el("bI1"), [msg("get_data"), msg("plus", 1)]))

      assert %IR{op: :uppercase} = ir(chain(cu(), [msg("name_text"), msg("to_uppercase")]))
      assert %IR{op: :fallback} = ir(chain(cu(), [msg("name_text"), msg("defaulting_to", "x")]))
    end

    test "operators the parser keeps raw" do
      date = chain(src("CurrentPageItem"), [msg("due_date")])
      opts = [host: "bT4"]

      assert %IR{op: :date_add, args: [_, %IR{op: :literal, args: [3]}, :day], type: "date"} =
               ir(chain(date, [msg("plus_days", 3)]), opts)

      assert %IR{op: :format_date, args: [_, "mmm d", nil]} =
               ir(chain(date, [msg("format_date", nil, %{"formatting_type" => "mmm d"})]), opts)

      replace =
        msg("find_replace", nil, %{
          "find" => text(["a"]),
          "replace" => text(["b"]),
          "use_regex" => false
        })

      assert %IR{op: :replace, args: [_, _, _, false]} =
               ir(chain(cu(), [msg("name_text"), replace]))

      yes_no =
        msg("format_boolean", nil, %{
          "formatting_for_true" => text(["Y"]),
          "formatting_for_false" => text(["N"])
        })

      assert %IR{op: :format_boolean} = ir(chain(cu(), [msg("admin_boolean"), yes_no]))
    end
  end

  describe "date intervals, date ranges, typed yes/no formats and option sorts (WTF-594, WTF-597)" do
    setup do
      %{
        date: chain(src("CurrentPageItem"), [msg("due_date")]),
        range: chain(src("CurrentPageItem"), [msg("window_date_range")]),
        opts: [host: "bT4"]
      }
    end

    test "a date minus a date, both rounded down, to days", %{date: date, opts: opts} do
      day = %{"component_to_extract" => "day"}
      now = src("PageData", %{"name" => "Current Date/Time"})

      raw =
        chain(now, [
          msg("rounded_down", nil, day),
          msg("minus", chain(date, [msg("rounded_down", nil, day)])),
          msg("to_days")
        ])

      assert %IR{
               op: :interval_to,
               type: "number",
               args: [
                 %IR{
                   op: :sub,
                   type: "dateinterval",
                   args: [
                     %IR{op: :date_floor, args: [%IR{op: :input}, "day", nil]},
                     %IR{op: :date_floor, args: [%IR{op: :field}, "day", nil]}
                   ]
                 },
                 :day
               ]
             } = ir(raw, opts)

      for {name, unit} <- [
            {"to_hours", :hour},
            {"to_minutes", :minute},
            {"to_seconds", :second}
          ] do
        assert %IR{op: :interval_to, args: [%IR{op: :sub}, ^unit]} =
                 ir(chain(now, [msg("minus", date), msg(name)]), opts)
      end
    end

    test "to days of anything but a date interval is not an interval conversion",
         %{opts: opts} do
      number = chain(el("bI1"), [msg("get_data")])
      assert %{ir: nil} = compile(chain(number, [msg("to_days")]), opts)
    end

    test "a date range's min, max and average", %{range: range, opts: opts} do
      for {name, op} <- [{"min", :range_start}, {"max", :range_end}, {"average", :range_middle}] do
        assert %IR{op: ^op, type: "date", args: [%IR{op: :field, type: "date_range"}]} =
                 ir(chain(range, [msg(name)]), opts)
      end

      custom = %{"formatting_type" => "custom", "custom_format" => "mmm d"}

      assert %IR{op: :format_date, args: [%IR{op: :range_end}, "mmm d", nil]} =
               ir(chain(range, [msg("max"), msg("format_date", nil, custom)]), opts)
    end

    test "a yes/no formatted as a typed value", %{range: range, opts: opts} do
      as_type = fn props, yes, no ->
        msg(
          "format_boolean_as_type",
          nil,
          Map.merge(props, %{"value_for_true" => yes, "value_for_false" => no})
        )
      end

      text =
        chain(range, [
          msg("is_not_empty"),
          as_type.(%{"data_type" => "text", "is_list" => false}, text(["Due"]), text([""]))
        ])

      assert %IR{op: :format_boolean, type: "text", args: [%IR{op: :not}, _, _]} =
               ir(text, opts)

      flipped =
        chain(cu(), [
          msg("admin_boolean"),
          as_type.(%{"data_type" => "boolean", "is_list" => false}, false, true)
        ])

      assert %IR{
               op: :format_boolean,
               type: "boolean",
               args: [_, %IR{op: :literal, args: [false]}, %IR{op: :literal, args: [true]}]
             } = ir(flipped)

      users =
        chain(cu(), [
          msg("admin_boolean"),
          as_type.(%{"data_type" => "user", "is_list" => true}, cu(), cu())
        ])

      assert %IR{op: :format_boolean, type: "list.user"} = ir(users)

      untyped = chain(cu(), [msg("admin_boolean"), as_type.(%{}, text(["a"]), text(["b"]))])
      assert %{ir: nil} = compile(untyped)
    end

    test "options sorted by an attribute" do
      sorted =
        chain(opt("status", "all values"), [
          msg("sorted", nil, %{"sort_field" => "rank", "descending" => true})
        ])

      assert ir(sorted) ==
               n(
                 :sort,
                 [n(:all_options, ["status"], "list.option.status"), "rank", true],
                 "list.option.status"
               )
    end
  end

  describe "date and number formats (WTF-456)" do
    setup do
      %{date: chain(src("CurrentPageItem"), [msg("due_date")]), opts: [host: "bT4"]}
    end

    test "a custom format reads custom_format; a named one is its own pattern",
         %{date: date, opts: opts} do
      custom = %{"formatting_type" => "custom", "custom_format" => "ddd, mmm d"}

      assert %IR{op: :format_date, args: [_, "ddd, mmm d", nil], type: "text"} =
               ir(chain(date, [msg("format_date", nil, custom)]), opts)

      # A named format keeps its pattern even with a stale custom_format.
      iso = %{"formatting_type" => "iso_date", "custom_format" => "yyyy"}

      assert %IR{op: :format_date, args: [_, "iso_date", nil]} =
               ir(chain(date, [msg("format_date", nil, iso)]), opts)

      # The live payload's compact key.
      compact = %{"%ft" => "custom", "custom_format" => "yyyy"}

      assert %IR{op: :format_date, args: [_, "yyyy", nil]} =
               ir(chain(date, [msg("format_date", nil, compact)]), opts)
    end

    test "time zones: the user's, a static zone, or an expression",
         %{date: date, opts: opts} do
      browser = %{"formatting_type" => "h:MM tt", "tz_type" => "browser", "tz_static" => "UTC"}

      assert %IR{args: [_, "h:MM tt", nil]} =
               ir(chain(date, [msg("format_date", nil, browser)]), opts)

      static = %{"formatting_type" => "h:MM tt", "tz_type" => "static", "tz_static" => "UTC"}

      assert %IR{args: [_, "h:MM tt", "UTC"]} =
               ir(chain(date, [msg("format_date", nil, static)]), opts)

      dynamic = %{
        "formatting_type" => "h:MM tt",
        "tz_type" => "dynamic",
        "tz_dynamic" => chain(cu(), [msg("name_text")])
      }

      assert %IR{args: [_, "h:MM tt", %IR{op: :field, type: "text"}]} =
               ir(chain(date, [msg("format_date", nil, dynamic)]), opts)

      floor = %{
        "component_to_extract" => "day",
        "tz_type_overridden" => "static",
        "tz_static_overridden" => "UTC"
      }

      assert %IR{op: :date_floor, args: [_, "day", "UTC"], type: "date"} =
               ir(chain(date, [msg("rounded_down", nil, floor)]), opts)

      assert %IR{op: :date_part, args: [_, "UNIX", nil], type: "number"} =
               ir(
                 chain(date, [msg("extract_from_date", nil, %{"component_to_extract" => "UNIX"})]),
                 opts
               )
    end

    test "an unknown time zone setting is not compiled", %{date: date, opts: opts} do
      odd = %{"formatting_type" => "h:MM tt", "tz_type" => "lunar"}
      env = env(opts)

      {:ok, %{ir: nil}} =
        Compiler.compile(parse!(chain(date, [msg("format_date", nil, odd)]), env), env)
    end

    test "number options keep Bubble's settings with readable keys" do
      number = chain(el("bI1"), [msg("get_data")])

      currency = %{
        "formatting_type" => "currency",
        "decimal_place" => 0,
        "thousand_separator" => "comma",
        "currency_symbol" => "$"
      }

      assert %IR{op: :format_number, args: [_, ^currency], type: "text"} =
               ir(chain(number, [msg("format_number", nil, currency)]))

      assert %IR{op: :format_number, args: [_, %{}]} =
               ir(chain(number, [msg("format_number", nil, nil)]))
    end
  end

  describe "searches" do
    test "constraints become a predicate over the item, sort is kept" do
      raw =
        search("custom.task", [con("status_option_status", "equals", opt("status", "done"))], %{
          "sort_field" => "title_text",
          "descending" => true
        })

      assert %IR{
               op: :sort,
               args: [
                 %IR{op: :search, args: ["task", %IR{op: :eq, args: [lhs, _]}]},
                 "title_text",
                 true
               ]
             } =
               ir(raw)

      assert lhs ==
               n(
                 :field,
                 [n(:this, [:filter_item], "custom.task"), "task", "status_option_status"],
                 "option.status"
               )
    end

    test "a constraint whose value may be empty, where searches run is not known" do
      value = chain(el("bI1"), [msg("get_data")])
      raw = search("custom.task", [con("estimate_number", "greater than", value)])

      assert %{ir: nil, diagnostics: [diag]} = compile(raw)
      assert diag.code == :expr_uncompiled
      assert diag.details == %{construct: :ignore_empty_constraints}
      assert diag.path == "/properties/constraints/0"

      assert %IR{op: :search, args: [_, %IR{op: :or, args: [%IR{op: :is_empty}, %IR{op: :gt}]}]} =
               ir(raw, ignore_empty_constraints: true)

      assert %IR{op: :search, args: [_, %IR{op: :gt}]} = ir(raw, ignore_empty_constraints: false)

      stated =
        search("custom.task", [con("estimate_number", "greater than", value)], %{
          "ignore_empty_constraints" => true
        })

      assert %IR{op: :search, args: [_, %IR{op: :or}]} = ir(stated)
    end

    # WTF-478, replayed on Bubble (2026-10-01): a page search drops a
    # constraint whose value is empty only when it states
    # `ignore_empty_constraints: true`, else the constraint matches nothing
    # (even a record whose field is empty); a backend workflow's search
    # matches nothing whatever it states. The caller's default
    # (`ignore_empty_constraints:`) does not change either.
    test "an empty constraint value on a page and in a backend workflow" do
      value = chain(el("bI1"), [msg("get_data")])

      gt = fn ->
        n(
          :gt,
          [
            n(
              :field,
              [n(:this, [:filter_item], "custom.task"), "task", "estimate_number"],
              "number"
            ),
            input_value()
          ],
          "boolean"
        )
      end

      empty = n(:is_empty, [input_value()], "boolean")
      dropped = n(:or, [empty, gt.()], "boolean")
      nothing = n(:and, [n(:not, [empty], "boolean"), gt.()], "boolean")

      raw = fn options ->
        search("custom.task", [con("estimate_number", "greater than", value)], options)
      end

      cases = [
        {:page, %{}, nothing},
        {:page, %{"ignore_empty_constraints" => false}, nothing},
        {:page, %{"ignore_empty_constraints" => true}, dropped},
        {:backend, %{}, nothing},
        {:backend, %{"ignore_empty_constraints" => false}, nothing},
        {:backend, %{"ignore_empty_constraints" => true}, nothing}
      ]

      for {searches, options, pred} <- cases, default <- [nil, true, false] do
        assert ir(raw.(options), searches: searches, ignore_empty_constraints: default) ==
                 n(:search, ["task", pred], "list.custom.task"),
               inspect({searches, options, default})
      end
    end

    test "a constraint whose value cannot be empty is not guarded" do
      literal = search("custom.task", [con("estimate_number", "greater than", 3)])
      # An `is empty` constraint has no value to be empty, even when its
      # JSON carries a null one.
      none = search("custom.task", [con("estimate_number", "is_not_empty", nil)])

      for searches <- [:page, :backend, nil],
          options <- [%{}, %{"ignore_empty_constraints" => true}] do
        assert %IR{op: :search, args: [_, %IR{op: :gt}]} =
                 ir(Map.update!(literal, "properties", &Map.merge(&1, options)),
                   searches: searches
                 )

        assert %IR{op: :search, args: [_, %IR{op: :not, args: [%IR{op: :is_empty}]}]} =
                 ir(Map.update!(none, "properties", &Map.merge(&1, options)), searches: searches)
      end
    end

    # A logged-out visitor's Current User is Bubble's temporary user, never
    # empty (`logged_out_user_is_empty` is refuted): `X = Current User` is
    # never dropped, so it matches no record for them rather than every one.
    test "the Current User is never an empty constraint value" do
      raw =
        search("custom.task", [con("assignee_user", "equals", cu())], %{
          "ignore_empty_constraints" => true
        })

      for searches <- [:page, :backend, nil] do
        assert %IR{op: :search, args: [_, %IR{op: :eq, args: [_, %IR{op: :current_user}]}]} =
                 ir(raw, searches: searches)
      end

      # Its fields can be empty: dropped on a page that says so.
      field = chain(cu(), [msg("name_text")])

      raw =
        search("custom.task", [con("title_text", "equals", field)], %{
          "ignore_empty_constraints" => true
        })

      assert %IR{op: :search, args: [_, %IR{op: :or, args: [%IR{op: :is_empty}, %IR{op: :eq}]}]} =
               ir(raw, searches: :page)
    end

    # A page's `:filtered` takes the page search's rule (replay 2026-10-07):
    # unstated or false, an empty value matches nothing; true drops it.
    # Elsewhere a stated option, or the caller's default, decides; on the
    # backend with neither it is still residue.
    test "a :filtered list follows its own option; on a page, as a page search" do
      raw = fn options ->
        chain(el("bR1"), [
          msg("get_list_data"),
          msg(
            "filtered",
            nil,
            Map.merge(options, %{
              "constraints" => %{
                "0" => con("estimate_number", "greater than", chain(el("bI1"), [msg("get_data")]))
              }
            })
          )
        ])
      end

      assert %{ir: nil, diagnostics: diags} = compile(raw.(%{}), searches: :backend)
      assert Enum.any?(diags, &(&1.details == %{construct: :ignore_empty_constraints}))

      # On a page (replay 2026-10-07): unstated or false matches nothing,
      # whatever the caller's default; true drops the constraint.
      for options <- [%{}, %{"ignore_empty_constraints" => false}],
          default <- [nil, true, false] do
        assert %IR{op: :filter, args: [_, %IR{op: :and, args: [%IR{op: :not}, %IR{op: :gt}]}]} =
                 ir(raw.(options), searches: :page, ignore_empty_constraints: default)
      end

      assert %IR{op: :filter, args: [_, %IR{op: :or}]} =
               ir(raw.(%{"ignore_empty_constraints" => true}), searches: :page)

      # Elsewhere the option decides.
      assert %IR{op: :filter, args: [_, %IR{op: :or}]} =
               ir(raw.(%{"ignore_empty_constraints" => true}), searches: :backend)

      assert %IR{op: :filter, args: [_, %IR{op: :gt}]} =
               ir(raw.(%{"ignore_empty_constraints" => false}), searches: :backend)
    end

    test "unmodeled search options are diagnosed" do
      raw = search("custom.task", [], %{"dynamic_sort_field" => "x"})

      assert %{
               ir: nil,
               diagnostics: [%{code: :expr_uncompiled, details: %{construct: :search_option}}]
             } = compile(raw)
    end

    # WTF-495: Bubble's further sort keys are nested sorts, the primary one
    # outermost (a sort keeps the order of what it sorts among equal keys);
    # the editor's display names and unset settings say nothing.
    test "a search's further sort keys are nested sorts, the primary one outermost" do
      empty = %{"type" => "Empty"}
      key = fn field, desc -> %{"sort_field" => field, "descending" => desc} end

      options = %{
        "sort_field" => "title_text",
        "descending" => true,
        "dynamic_sort_field" => empty,
        "sort_field_friendly" => "Title",
        "type_to_find_friendly" => "Task",
        "additional_sort_fields" => %{
          "1" => key.("estimate_number", true),
          "0" =>
            Map.merge(key.("public_boolean", false), %{
              "dynamic_sort_field" => empty,
              "geo_reference" => empty
            })
        }
      }

      assert %IR{
               op: :sort,
               args: [
                 %IR{
                   op: :sort,
                   args: [
                     %IR{op: :sort, args: [%IR{op: :search}, "estimate_number", true]},
                     "public_boolean",
                     false
                   ]
                 },
                 "title_text",
                 true
               ]
             } = ir(search("custom.task", [], options))

      # `:sorted` reads them too.
      sorted = chain(search("custom.task", []), [msg("sorted", nil, options)])
      assert %IR{op: :sort, args: [%IR{op: :sort}, "title_text", true]} = ir(sorted)

      # A list of texts sorts by value: no sort field (replay 2026-10-07).
      titles = fn props ->
        chain(search("custom.task", []), [msg("title_text"), msg("sorted", nil, props)])
      end

      assert %IR{op: :sort, args: [%IR{type: "list.text"}, nil, false], type: "list.text"} =
               ir(titles.(%{}))

      assert %IR{op: :sort, args: [_, nil, true]} = ir(titles.(%{"descending" => true}))

      assert %{ir: nil, diagnostics: [%{details: %{construct: :search_option}}]} =
               compile(titles.(%{"descending" => text(["x"])}))

      # A list of things with no sort field keeps its order.
      assert %IR{op: :search} = ir(chain(search("custom.task", []), [msg("sorted", nil, %{})]))

      # A dynamic sort field cleared in the editor (an empty text, with
      # its entries or without) names no field: the static one sorts
      # (WTF-520).
      for cleared <- [
            %{"type" => "TextExpression", "entries" => %{"1" => ""}},
            %{"type" => "TextExpression"},
            text(["", ""]),
            ""
          ] do
        assert %IR{op: :sort, args: [_, "title_text", true]} =
                 ir(search("custom.task", [], Map.put(options, "dynamic_sort_field", cleared)))
      end

      # Set to Dynamic with the field cleared: no field sorts.
      dynamic_cleared =
        Map.merge(options, %{
          "sort_field" => "_dynamic_sort_field",
          "dynamic_sort_field" => %{"type" => "TextExpression", "entries" => %{"1" => ""}},
          "additional_sort_fields" => %{}
        })

      assert %IR{op: :search} = ir(search("custom.task", [], dynamic_cleared))

      # Only the dynamic sort field reads an empty text as unset: a
      # geographic reference that is one is still not compiled.
      assert %{ir: nil, diagnostics: [%{details: %{construct: :search_option}}]} =
               compile(
                 search(
                   "custom.task",
                   [],
                   Map.put(options, "geo_reference", %{"type" => "TextExpression"})
                 )
               )

      # A dynamic or geographic sort key is not compiled.
      for extra <- [
            %{"dynamic_sort_field" => text(["x"])},
            %{
              "additional_sort_fields" => %{
                "0" => Map.put(key.("title_text", false), "geo_reference", cu())
              }
            },
            %{"additional_sort_fields" => %{"0" => key.("_dynamic_sort_field", false)}}
          ] do
        assert %{ir: nil, diagnostics: [%{details: %{construct: :search_option}}]} =
                 compile(search("custom.task", [], Map.merge(options, extra)))
      end
    end
  end

  describe "breakpoints" do
    # The app's breakpoint settings, built-in and custom alike.
    defp breakpoint_tree do
      settings = %{
        "client_safe" => %{
          "responsive_breakpoints" => %{
            "built-in-tablet" => %{"builtin" => true, "name" => "Tablet", "size" => 992},
            "custom_bpA" => %{"builtin" => false, "name" => "Custom", "size" => 640},
            "no_size" => %{"builtin" => false, "name" => "Custom"}
          }
        }
      }

      app() |> Map.put("settings", settings) |> BubbleEx.Expression.Tree.build()
    end

    defp width_vs(op, id) do
      chain(src("PageData", %{"name" => "Current Page Width"}), [
        msg(op, src("Breakpoint", %{"breakpoint_id" => id}))
      ])
    end

    defp width, do: n(:input, [:page_data, %{"name" => "Current Page Width"}], "number")

    test "a breakpoint is its width in the app's settings, a number" do
      tree = breakpoint_tree()

      assert ir(width_vs("less_than", "built-in-tablet"), tree: tree) ==
               n(:lt, [width(), lit(992, "number")], "boolean")

      assert ir(width_vs("greater_or_equal_than", "custom_bpA"), tree: tree) ==
               n(:gte, [width(), lit(640, "number")], "boolean")
    end

    test "a breakpoint the settings do not define, or define without a width, does not compile" do
      tree = breakpoint_tree()

      for id <- ["built-in-mobile", "no_size"] do
        assert %{ir: nil, diagnostics: [diag]} = compile(width_vs("less_than", id), tree: tree)
        assert diag.code == :expr_untyped_scope
        assert diag.details.reason == :breakpoint_not_in_settings
        assert diag.message =~ ~s(breakpoint "#{id}")
        assert diag.message =~ "default widths are not assumed"
      end

      # An app without breakpoint settings: none is known.
      assert %{ir: nil, diagnostics: [%{details: %{reason: :breakpoint_not_in_settings}}]} =
               compile(width_vs("less_than", "built-in-tablet"))
    end
  end

  # Replay 2026-10-19: a repeating group's "is loading" is no while a
  # search runs, yes only for a few milliseconds as rows render.
  describe "a repeating group's is loading" do
    test "is a constant no where a page shows it" do
      opts = [loading_status: :constant]
      assert ir(chain(el("bR1"), [msg("get_loading_status")]), opts) == lit(false, "boolean")

      assert ir(chain(el("bR1"), [msg("get_loading_status"), msg("is_true")]), opts) ==
               n(:eq, [lit(false, "boolean"), lit(true, "boolean")], "boolean")
    end

    # A workflow's trigger may fire on Bubble's flash of yes.
    test "is not compiled elsewhere, with why" do
      assert %{ir: nil, diagnostics: diags} =
               compile(chain(el("bR1"), [msg("get_loading_status")]))

      assert Enum.any?(diags, &(&1.details == %{construct: :loading_status}))
    end

    test "of an element that is not a repeating group does not compile" do
      assert %{ir: nil} = compile(chain(el("bI1"), [msg("get_loading_status")]))
    end
  end

  describe "not compiled" do
    test "a raw operator, with its pointer" do
      raw = chain(cu(), [msg("name_text"), msg("mystery", "x")])
      assert %{ir: nil, diagnostics: diags} = compile(raw, path: ["pages", "p", "text"])

      assert [
               %{
                 code: :expr_uncompiled,
                 path: "/pages/p/text/next/next",
                 details: %{construct: :raw}
               }
             ] =
               Enum.filter(diags, &(&1.code == :expr_uncompiled))
    end

    test "an element used as a value" do
      assert %{ir: nil, diagnostics: [%{details: %{construct: :element}}]} = compile(el("bI1"))
    end

    test "an untyped part is reported once, by typing" do
      assert %{ir: nil, diagnostics: [%{code: :expr_untyped_scope}]} =
               compile(chain(src("ElementParent"), [msg("title_text")]), host: "bP1")
    end

    test "subjects are stamped on every diagnostic" do
      %{diagnostics: [diag]} = compile(el("bI1"), subject: %{workflow: "bW1"})
      assert diag.subject == %{workflow: "bW1"}
    end
  end

  test "an option named by its Bubble ID compiles, with a diagnostic" do
    assert %{ir: %IR{op: :option, args: ["status", "bSb", "done"]}, diagnostics: [diag]} =
             compile(opt("status", "bSb"))

    assert diag.code == :expr_option_by_id
    assert diag.subject == %{option_set: "status"}
  end

  test "a plugin's data call: ipify's IP is a context input, others do not compile (WTF-569)" do
    ip = %{"type" => "GetDataFromAPI", "properties" => %{"provider" => "ipify.GetIP"}}
    text = %{"type" => "TextExpression", "entries" => %{"0" => ip}}

    assert ir(ip) == n(:input, [:client_ip, %{"plugin" => "ipify"}], "text")

    assert ir(text) ==
             n(:concat, [n(:input, [:client_ip, %{"plugin" => "ipify"}], "text")], "text")

    other = %{"type" => "GetDataFromAPI", "properties" => %{"provider" => "zapier.Hook"}}

    assert %{
             ir: nil,
             diagnostics: [%{code: :expr_uncompiled, details: %{construct: :plugin_data}}]
           } =
             compile(other)

    # Source re-emission keeps the plugin's provider.
    env = env([])
    assert ip |> parse!(env) |> BubbleEx.Expression.Encoder.encode() == ip
  end

  test "IR is deterministic and JSON-encodable" do
    raw = text(["Hi ", chain(src("ElementParent"), [msg("title_text")])])
    a = ir(raw, host: "bT1")
    assert a == ir(raw, host: "bT1")
    assert a |> IR.to_map() |> Jason.encode!() |> Jason.decode!() == IR.to_map(a)
    assert IR.ops(a) == [:concat, :literal, :field, :input]
  end
end
