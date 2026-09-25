defmodule BubbleEx.Diagnostic.Codes do
  # The single registry of diagnostic codes. Severity, outcome and stage are
  # properties of a code, never of a call site: `BubbleEx.Diagnostic.new/4`
  # reads them from here and raises on an unregistered code. A test scans
  # `lib/` for emitted codes and requires this registry to match exactly.

  @codes [
    # --- :read — BubbleEx.Model.External.Resolver (API Connector types) -----
    {:invalid_descriptor, :warning, :degraded, :read,
     "an `api.` type descriptor that is not a valid API Connector type; kept as an opaque external value"},
    {:field_type_unsupported, :warning, :degraded, :read,
     "an external field type outside the known scalars and API Connector types; kept as an opaque external value"},
    {:field_type_malformed, :warning, :degraded, :read,
     "an external field type that is missing or not a string; kept as an opaque external value"},
    {:conflicting_duplicate_definition, :warning, :unresolved, :read,
     "an API Connector type defined differently by more than one call"},
    {:connector_missing, :warning, :unresolved, :read,
     "the API Connector named by an external type is absent"},
    {:call_missing, :warning, :unresolved, :read,
     "the API Connector call named by an external type is absent"},
    {:registry_unavailable, :warning, :unresolved, :read,
     "the API Connector call has no `types` registry"},
    {:registry_malformed, :warning, :unresolved, :read,
     "the API Connector call's `types` registry is not a JSON object"},
    {:exact_type_definition_missing, :warning, :unresolved, :read,
     "the call's `types` registry has no usable definition for the external type"},
    {:empty_definition, :info, :preserved, :read,
     "an external type defined with no fields; modeled as an empty object"},
    {:incomplete_field_metadata, :info, :degraded, :read,
     "an external type field without a caption or path"},
    {:call_metadata_inconsistent, :info, :preserved, :read,
     "the call's `ret_value` names a different type than the one resolved"},

    # --- :parse — BubbleEx.Expression, BubbleEx.Privacy, BubbleEx.Workflows ---
    {:unknown_operator, :error, :preserved, :parse,
     "an operator outside the expression vocabulary; kept verbatim as `Ast.Raw`"},
    {:unknown_source, :error, :preserved, :parse,
     "a source type outside the expression vocabulary; kept verbatim as `Ast.Raw`"},
    {:unexpected_shape, :error, :preserved, :parse,
     "a known operator or source with missing or extra operands; kept verbatim as `Ast.Raw`"},
    {:malformed_node, :error, :preserved, :parse,
     "an expression, privacy rule, data type or `privacy_role` that is not the expected JSON kind; kept verbatim (`Ast.Raw`, `DataType.raw`, `DataType.extra`)"},
    {:alias_collision, :error, :preserved, :parse,
     "the same key spelled both readable and compact; both values kept"},
    {:unresolved_order, :error, :preserved, :parse,
     "text-expression entries whose order cannot be established; kept verbatim as `Ast.Raw`"},
    {:invalid_permission, :error, :preserved, :parse,
     "privacy-rule permissions that are not an object, a boolean or a field list; kept in `extra`"},
    {:uninterpreted_field, :warning, :preserved, :parse,
     "an unexpected expression, data-type or privacy-rule member, kept in `meta`/`extra` for round-trip but not modeled"},
    {:unknown_constraint, :warning, :preserved, :parse,
     "a search or filter constraint operator outside the vocabulary; its source is kept"},
    {:unknown_permission, :warning, :preserved, :parse,
     "an unmodeled privacy-rule permission; kept in `extra`"},
    {:unresolved_field, :warning, :unresolved, :parse,
     "a field name absent from the subject's data type"},
    {:missing_condition, :warning, :unresolved, :parse,
     "a non-default privacy rule without a condition"},
    {:missing_default_rule, :warning, :unresolved, :parse,
     "a privacy rule set without an `everyone` rule"},
    {:unresolved_property, :info, :unresolved, :parse,
     "an accessor on a subject of unknown type (element state, plugin or API field)"},
    {:malformed_owner, :warning, :preserved, :parse,
     "a workflow owner that is not an object; its workflow availability is unknown"},
    {:malformed_collection, :warning, :preserved, :parse,
     "a workflow collection that is not a map or list; value kept"},
    {:malformed_actions, :warning, :preserved, :parse,
     "a workflow `actions` value that is not a map or list; value kept"},
    {:malformed_properties, :warning, :preserved, :parse,
     "event or action properties that are not an object; value kept"},
    {:unsupported_type, :warning, :preserved, :parse,
     "an event or action type outside the explanation vocabulary"},
    {:unresolved_reference, :warning, :unresolved, :parse,
     "a workflow reference (element, page, action, data type, …) that is missing or ambiguous"},
    {:unresolved_condition, :warning, :unresolved, :parse,
     "a workflow condition that is not a proven, fully supported boolean"},
    {:unavailable_data, :info, :unresolved, :parse,
     "a workflow scope whose data was not supplied"},
    {:actions_unavailable, :info, :unresolved, :parse, "a workflow without an `actions` field"},
    {:unclassified_definition, :info, :preserved, :parse,
     "an action-bearing definition outside known workflow collections, kept as a candidate"},
    {:properties_not_evaluated, :info, :preserved, :parse,
     "event or action properties kept verbatim without evaluating their runtime semantics"},
    {:workflow_malformed_node, :warning, :preserved, :parse,
     "a workflow, event or action entry that is not an object; kept in `raw`"},
    {:workflow_alias_collision, :warning, :preserved, :parse,
     "a workflow node spelling a member both readable and compact; the named one is displayed, both are kept in `raw`"},
    {:workflow_unresolved_order, :warning, :degraded, :parse,
     "map-keyed actions whose execution order cannot be established; displayed in lexical key order, source kept"},
    {:workflow_uninterpreted_field, :info, :preserved, :parse,
     "a workflow node member kept in `raw` without semantic interpretation"},

    # --- :model — BubbleEx.Index ---------------------------------------------
    {:index_unresolved_reference, :warning, :unresolved, :model,
     "a symbol-index reference to a definition absent from the supplied data, or a data action whose target data type cannot be resolved (its writes are not indexed)"},
    {:index_duplicate_symbol, :warning, :degraded, :model,
     "two definitions share a Bubble ID; the first by source path is indexed and references by that ID resolve to it"},

    # --- :model — BubbleEx.Model (WTF-361) -----------------------------------
    {:model_malformed_node, :error, :preserved, :model,
     "a field, attribute, option set, option value or collection that is not a JSON object; kept verbatim (`raw`, or `extra` under its key)"},
    {:model_malformed_field_type, :warning, :preserved, :model,
     "a field or attribute whose type descriptor is missing or not a string; kept verbatim in `type.source` (kind `:unknown`)"},
    {:model_unsupported_field_type, :warning, :preserved, :model,
     "a type descriptor outside Bubble's type vocabulary; kept verbatim in `type.source` (kind `:unknown`)"},
    {:model_unresolved_target, :warning, :unresolved, :model,
     "a field or attribute referencing a data type or option set absent from the app; kept as an unresolved reference to its Bubble ID"},
    {:model_uninterpreted_member, :info, :preserved, :model,
     "an unexpected field, attribute or option-set member; kept in `extra` but not modeled"},
    {:model_undeclared_option_attribute_value, :warning, :preserved, :model,
     "an option-value member naming no declared attribute of its set (e.g. left by a deleted attribute); kept in the value's `extra`"},
    {:model_synthesized_user_type, :info, :degraded, :model,
     "the source defines no User type; Bubble's built-in User is modeled with only its built-in fields, its custom fields unknown"},
    {:model_option_key_missing, :warning, :degraded, :model,
     "an option value without a `db_value`; its Bubble ID stands in as the stable key"},
    {:model_duplicate_option_key, :warning, :degraded, :model,
     "an option value (not deleted) repeating the stable key of an earlier value in the same set"},

    # --- WTF-368 expression compiler -----------------------------------------
    # :model — BubbleEx.Expression.Typing / Compiler (stack-neutral IR)
    {:expr_untyped_scope, :warning, :unresolved, :model,
     "a context value (element, parent group, cell, page thing, previous step, …) whose type the element tree and workflow do not determine; it stays untyped"},
    {:expr_unresolved_accessor, :warning, :unresolved, :model,
     "an accessor that is neither a field of its subject's type, an element state nor a known operator; it stays untyped"},
    {:expr_option_by_id, :info, :degraded, :model,
     "an option value named by its Bubble ID rather than its stored key (`db_value`); read as that option, which is not verified against Bubble"},
    {:expr_uncompiled, :warning, :unresolved, :model,
     "an expression construct with no stack-neutral IR (a raw node, an unmodeled operator or constraint, an untyped operand); the expression is not compiled"},
    # target:ash — BubbleEx.Target.Ash.Expressions
    {:ash_expr_unsupported, :warning, :unresolved, :target,
     "an expression IR construct with no `Ash.Expr` mapping (e.g. a path through a list of things, a context input in a privacy rule); the expression is not compiled"},
    {:ash_expr_unmapped_reference, :warning, :unresolved, :target,
     "an expression reading a data type, field or option value the Ash project does not map (deleted, malformed or missing); the expression is not compiled"},
    # target:elixir — BubbleEx.Target.Elixir
    {:elixir_expr_unsupported, :warning, :unresolved, :target,
     "an expression IR construct with no Elixir mapping yet (e.g. a search); the expression is not compiled"},

    # --- {:target, format} — BubbleEx.Db.Encoder ----------------------------
    {:external_type_unresolved_root, :warning, :degraded, :target,
     "an external field whose type did not resolve; rendered as JSON"},
    {:external_type_unresolved_nested, :warning, :degraded, :target,
     "an external type field whose nested type did not resolve; rendered as JSON"},
    {:external_type_target_opaque, :info, :degraded, :target,
     "the target cannot express external type shapes; rendered as JSON"},
    {:external_type_cycle_edge, :info, :degraded, :target,
     "a recursive external type edge the target cannot express; rendered as JSON"},
    {:external_type_opaque_mode, :info, :degraded, :target,
     "`external_types: :opaque` was selected; rendered as JSON"},
    {:external_type_legacy_mode, :info, :degraded, :target,
     "`external_types: :legacy` was selected; rendered in the legacy form"},

    # --- {:target, format} — BubbleEx.Db.Reader projection (WTF-365) --------
    # Recorded by the Reader's table projection, emitted by Encoder.render/3.
    {:db_name_suffixed, :info, :degraded, :target,
     "a table or column whose display name repeats an earlier one's (case-insensitively, key columns included); rendered with a `_2`, `_3`, ... suffix assigned in Bubble ID order"},
    {:db_duplicate_option_value_dropped, :warning, :degraded, :target,
     "an option value repeating an earlier value's stable key; left out of the option table's values so `db_value` stays a key"},
    {:db_reference_to_omitted, :warning, :degraded, :target,
     "a reference to a deleted or malformed data type or option set; its column is kept but it has no relationship or foreign key"},

    # --- {:target, format} — BubbleEx.Db.Encoder.Names (WTF-391) -------------
    # Emitted by Encoder.render/3 for the encoders that convert names (Ecto,
    # Convex, Xano, Zod).
    {:db_converted_name_suffixed, :info, :degraded, :target,
     "a table or column whose name, converted to the target's case convention, repeats an earlier one's (a built-in field's, or a foreign key's); rendered with the next free suffix, assigned in Bubble ID order"},
    {:db_converted_name_truncated, :info, :degraded, :target,
     "a table or column whose converted name is longer than the target allows (Ecto: 63 characters, PostgreSQL's identifier limit); cut, keeping any suffix that makes it unique"},

    # --- target:ash — BubbleEx.Target.Ash (WTF-362) ---------------------------
    # Also emits the shared external_type_unresolved_root/_nested and
    # external_type_cycle_edge codes above, with target :ash.
    {:ash_deleted_omitted, :info, :degraded, :target,
     "a deleted data type, field, option set, option value or option-set attribute; omitted from the Ash project"},
    {:ash_malformed_omitted, :warning, :unresolved, :target,
     "a data type, field, option set, option value or attribute that is malformed in the source (`raw`); not mapped"},
    {:ash_unresolved_reference, :warning, :degraded, :target,
     "a reference to a data type or option set that is missing or omitted; its Bubble IDs are kept as `:string` (or an array of them)"},
    {:ash_opaque_value, :warning, :preserved, :target,
     "a value with no usable type (opaque, unknown, or of unknown list-ness); kept verbatim as any JSON value (the generated `Types.JsonValue`, jsonb) but not modeled"},
    {:ash_date_interval_as_number, :info, :degraded, :target,
     "a date interval (Bubble: the difference between two dates in milliseconds); mapped to `:float` milliseconds, not a duration type"},
    {:ash_default_unmapped, :warning, :degraded, :target,
     "a field default with no Ash equivalent (e.g. a list, a reference, or a value of the wrong type); omitted"},
    {:ash_duplicate_enum_value, :warning, :degraded, :target,
     "an option value repeating an earlier value's stable key; omitted from the enum"},

    # --- target:ash — BubbleEx.Target.Ash privacy policies (WTF-356) ----------
    {:ash_policies_unverified, :warning, :degraded, :target,
     "the generated Ash policies rest on Bubble semantics not yet verified against Bubble (WTF-384/385); not to be shipped to users until they are"},
    {:ash_policy_rule_denied, :warning, :degraded, :target,
     "a privacy rule whose condition does not compile (or is missing); it grants nothing"},
    {:ash_policy_default_grant_denied, :warning, :degraded, :target,
     "grants of the `everyone` rule that apply only when a rule whose condition does not compile fails to hold; denied"},
    {:ash_policy_default_rule_negated, :info, :degraded, :target,
     "grants of the `everyone` rule compiled as the negation of the rules lacking them; the negation denies when the actor lacks a value a condition reads (e.g. logged out) or a record value it reads is empty"},
    {:ash_policy_field_unmapped, :info, :degraded, :target,
     "a privacy rule's visible or auto-binding field list names a field the Ash project does not map; ignored"},
    {:ash_privacy_rules_unavailable, :warning, :degraded, :target,
     "a data type whose privacy rules the source does not include (e.g. a live payload); every read is denied"},
    {:ash_policy_attachments_unenforced, :warning, :degraded, :target,
     "Bubble's \"view attached files\" permission, not granted to everyone on a type with file fields; Ash cannot enforce it (the file store must)"},
    {:ash_policy_data_api_unmapped, :info, :degraded, :target,
     "a data type exposed through Bubble's Data API; no API actions or policies are generated (out of scope unless requested)"},
    {:ash_policy_bypass_required, :info, :degraded, :target,
     "a workflow that runs ignoring privacy rules; lowered, its reads need an explicit authorization bypass (`authorize?: false`)"}
  ]

  @registry Map.new(@codes, fn {code, severity, outcome, stage, doc} ->
              {code, %{severity: severity, outcome: outcome, stage: stage, doc: doc}}
            end)

  if map_size(@registry) != length(@codes), do: raise("duplicate diagnostic code")

  @table Enum.map_join(@codes, "\n", fn {code, severity, outcome, stage, doc} ->
           stage = if stage == :target, do: "`{:target, format}`", else: "`#{inspect(stage)}`"

           "| `#{inspect(code)}` | `#{inspect(severity)}` | `#{inspect(outcome)}` | #{stage} | #{doc} |"
         end)

  @moduledoc """
  The single diagnostic code registry. Each code fixes the severity, outcome
  and stage of every `BubbleEx.Diagnostic` that carries it.

  | Code | Severity | Outcome | Stage | Meaning |
  |------|----------|---------|-------|---------|
  #{@table}
  """

  @type entry :: %{
          severity: BubbleEx.Diagnostic.severity(),
          outcome: BubbleEx.Diagnostic.outcome(),
          stage: :read | :parse | :model | :target,
          doc: String.t()
        }

  @doc "Every registered code, in registry order."
  @spec all() :: [atom()]
  def all, do: Enum.map(@codes, &elem(&1, 0))

  @doc "The registry entry for `code`, or `:error`."
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(code), do: Map.fetch(@registry, code)

  @doc "Whether `code` is registered."
  @spec registered?(atom()) :: boolean()
  def registered?(code), do: is_map_key(@registry, code)
end
