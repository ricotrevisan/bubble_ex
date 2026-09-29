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

    # --- :read — BubbleEx.Buildprint.V5 (Buildprint v5 workspaces) ----------
    # Counts and section names only: never a key, value or name read from
    # the workspace.
    {:buildprint_stub_unresolved, :warning, :degraded, :read,
     "pages, reusable elements or mobile views that are only stubs in the Buildprint preamble and that no fragment completes; kept as stubs"},
    {:buildprint_fragment_ignored, :warning, :unresolved, :read,
     "Buildprint fragment rows or members that are not JSON objects under a known app section; ignored"},
    {:buildprint_fragment_overlap, :warning, :degraded, :read,
     "definitions held by more than one Buildprint fragment; the last by root key is kept"},
    {:buildprint_settings_dropped, :info, :degraded, :read,
     "app settings other than `client_safe` in a Buildprint snapshot; dropped unread (they may hold secrets)"},
    {:buildprint_secret_handle, :warning, :degraded, :read,
     "strings (or keys) holding a Buildprint secret handle (`$bp…`); replaced by an empty string (the key's member dropped)"},
    {:buildprint_count_mismatch, :warning, :preserved, :read,
     "a count of loaded definitions (data types, fields, option sets, pages, API calls, workflows) that differs from the Buildprint `symbols` index"},
    {:buildprint_snapshot_unverified, :info, :preserved, :read,
     "the Buildprint manifest's `snapshotJsonSha256` is not reproducible from the stored rows; each row's content hash is verified instead"},

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

    # --- :model — BubbleEx.Workflows.Backend (WTF-373) ------------------------
    {:workflow_residue, :warning, :unresolved, :model,
     "a backend workflow event or step with no mechanical lowering (residue for agent work)"},
    {:workflow_privacy_bypass, :warning, :degraded, :model,
     "a backend workflow set to ignore privacy rules: lowered with authorization bypassed (`authorize?: false`)"},
    {:workflow_action_privacy_option, :info, :preserved, :model,
     "a scheduling action's ignore-privacy option; not a bypass (the scheduled workflow's own setting decides)"},
    {:workflow_endpoint_not_served, :warning, :degraded, :target,
     "a workflow Bubble exposes as an API endpoint; not served by the Phoenix target while the project has no authorization (`privacy: :omit`) until the owner sets `serve_workflow_api: true`"},
    {:workflow_trigger_sensitive_field, :warning, :degraded, :target,
     "a database-trigger workflow reads a record's email or authentication data, which its job snapshot then stores in the job arguments"},
    {:workflow_endpoint_duplicate, :warning, :degraded, :target,
     "two exposed workflows share an endpoint name; the one with the lower Bubble ID serves it"},

    # --- :model — BubbleEx.Workflows.Frontend (WTF-372) -----------------------
    {:frontend_workflow_residue, :warning, :unresolved, :model,
     "a page or reusable-element workflow event or step with no mechanical lowering (residue for agent work)"},
    {:frontend_workflow_disabled, :info, :preserved, :model,
     "a page or reusable-element workflow disabled in the Bubble editor: generated, never triggered"},

    # --- :model — BubbleEx.PageData (WTF-420) --------------------------------
    {:page_data_residue, :warning, :unresolved, :model,
     "a page's type of content or an element's data source with no mechanical lowering (residue for agent work); the generated page does not load it"},

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
    {:ash_dropped_omitted, :info, :degraded, :target,
     "a data type, field or option set an owner's drop decision removes (WTF-422); omitted from the Ash project, with every relationship to it"},
    {:ash_drop_dangling_reference, :error, :unresolved, :target,
     "a kept field referencing a data type or option set an owner dropped, not accepted in the drop's `dangling`: the drop blocks publication until the field is dropped too or the reference accepted; its Bubble IDs are kept as `:string` meanwhile"},
    {:ash_drop_reference_accepted, :warning, :degraded, :target,
     "a kept field referencing a data type or option set an owner dropped, accepted in the drop's `dangling`: its Bubble IDs are kept as `:string`, with no relationship"},
    {:ash_policy_reads_dropped, :warning, :degraded, :target,
     "a privacy rule whose condition reads a field, data type or option set an owner dropped: it compiles to deny (grants nothing); dropping never widens access"},
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

    # --- target:ash — BubbleEx.Target.Ash owner decisions (WTF-352, WTF-401) ---
    {:ash_decision_applied, :info, :degraded, :target,
     "an owner decision (or a hint applied by default) changed the mapping: a number stored as an integer or decimal, a copied field or count derived as a calculation or aggregate, a text of IDs made a reference, a reverse list derived as a has_many, a list of things normalized to a join resource (a many_to_many), indexes added; the project departs from the source-faithful mapping on purpose"},
    {:ash_decision_deferred, :warning, :unresolved, :target,
     "what applies by default but Target.Ash does not create: indexes with no Ash rendering (a geographic access, a field no longer stored), or a hint whose transform is not applied yet; listed in `project.deferred`"},
    {:ash_name_overridden, :info, :preserved, :target,
     "an owner rename decision set a generated name; after the name lock only Elixir names change, and a renamed attribute keeps its column (`source:`)"},

    # --- target:ash — BubbleEx.Target.Ash privacy policies (WTF-356) ----------
    {:ash_policy_auto_binding_dropped, :warning, :degraded, :target,
     "a field privacy rules let users auto-bind that an owner decision no longer stores (a derived field, or a list normalized to a join); the `:auto_bind` action does not accept it, so the binding needs rewriting"},
    {:ash_privacy_omitted, :info, :degraded, :target,
     "privacy rules the source has (or may have) that were not compiled (`privacy: :omit`, the default); the generated resources have no authorization"},
    {:ash_policies_unverified, :warning, :degraded, :target,
     "the generated Ash policies rest on Bubble semantics not yet verified against Bubble (WTF-384/385); not to be shipped to users until they are"},
    {:ash_policy_stricter_than_bubble, :info, :degraded, :target,
     "a privacy rule whose condition reads the current user: where the user is logged out or lacks a value it reads, Bubble compares the empty value like any other (and may grant) while the generated policy denies; stricter than Bubble by the owner's decision (`BubbleEx.Verify.Difference`, WTF-426)"},
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
    {:ash_policy_aggregates_unguarded, :warning, :degraded, :target,
     "a data type with fields some users may not view; Ash field policies do not apply to aggregates (count, min, max, sum, ...) over them, so generated code must not aggregate them for those users"},
    {:ash_policy_bypass_required, :info, :degraded, :target,
     "a workflow that runs ignoring privacy rules; lowered, its reads need an explicit authorization bypass (`authorize?: false`)"},

    # --- :load — BubbleEx.Load, the data loader (WTF-357) ----------------------
    # Aggregated per data type and field: `details` carries the count and at
    # most a few sample record IDs, never a stored value.
    {:load_export_partial, :error, :unresolved, :load,
     "the export is incomplete (a data type failed to export or was not exported); the loader refuses it unless `allow_partial: true`"},
    {:load_schema_mismatch, :error, :unresolved, :load,
     "the target database lacks a table or column the load plan writes, or its column type differs; nothing is written"},
    {:load_column_extra, :info, :preserved, :load,
     "a target column the load plan does not write (e.g. added by owned code); left untouched"},
    {:load_type_unmapped, :warning, :unresolved, :load,
     "exported rows of a data type the target does not map (deleted or unknown); not loaded, kept in the export"},
    {:load_type_dropped, :info, :preserved, :load,
     "exported rows of a data type an owner dropped (WTF-422); not loaded, kept in the export; counts only"},
    {:load_dropped_field_data, :info, :preserved, :load,
     "rows holding values of a field an owner dropped (WTF-422); not loaded, kept in the export; counts only"},
    {:load_type_not_exported, :warning, :unresolved, :load,
     "a data type the target maps but the export has no rows object for; nothing loaded for it"},
    {:load_invalid_record_id, :error, :unresolved, :load,
     "a row without a string `_id`; it cannot be keyed and is not loaded"},
    {:load_unexpected_id_format, :warning, :preserved, :load,
     "a `_id` not shaped like a Bubble unique ID (`<digits>x<digits>`); loaded as given"},
    {:load_duplicate_record, :warning, :degraded, :load,
     "a `_id` exported more than once (e.g. the data changed while paging); the copy with the latest Modified Date is loaded"},
    {:load_unmapped_key, :error, :unresolved, :load,
     "a row key that is no field of the data type in the Model (a wrong key format loads whole columns empty); blocks a real run unless `allow_unmapped_keys: true` or mapped with `:keys`"},
    {:load_ambiguous_key, :error, :unresolved, :load,
     "a row key naming more than one field (two fields share a display name, or a display name is another field's ID); blocks a real run until `:keys` maps it"},
    {:load_nul_stripped, :warning, :degraded, :load,
     "a stored text holding NUL characters, which PostgreSQL text and jsonb cannot hold; loaded without them"},
    {:load_email_conflict, :error, :unresolved, :load,
     "an exported user's email held in the target by a record the export does not hold (e.g. a user deleted in Bubble whose email was reused); the unique email identity would refuse it, so nothing is written"},
    {:load_deleted_field_data, :info, :preserved, :load,
     "rows holding values of a field deleted in the editor; not loaded, kept in the export"},
    {:load_type_mismatch, :warning, :degraded, :load,
     "a stored value that does not fit the field's type (or the target column's, e.g. a fraction in an integer column); loaded as empty, or the list item dropped"},
    {:load_unknown_option, :warning, :degraded, :load,
     "a stored option value that is no live option of the set; loaded as empty"},
    {:load_option_by_label, :info, :degraded, :load,
     "a stored option value matched by its display text rather than its key"},
    {:load_invalid_reference, :warning, :degraded, :load,
     "a text converted to a reference (`text_to_reference`) that is not shaped like a Bubble unique ID; loaded as empty"},
    {:load_dangling_reference, :info, :preserved, :load,
     "a reference to a record the export does not hold (deleted, or not exported); loaded as stored (no foreign key rejects it), so it reads as nil through the relationship"},
    {:load_deleted_ids_dropped, :info, :degraded, :load,
     "IDs of records the export does not hold, dropped from a list whose count is derived as its length (`derive_count`), as Bubble's `:count` does not count them"},
    {:load_derived_drift, :warning, :degraded, :load,
     "a stored value of a field derived by an owner decision (not loaded) that differs from the value derived from the loaded data"},
    {:load_reverse_list_drift, :warning, :degraded, :load,
     "a stored list replaced by a `has_many` (`derive_reverse_relationship`) that differs from the records pointing back; the `has_many` reads the latter"},
    {:load_join_duplicate, :info, :degraded, :load,
     "a list normalized to a join (`normalize_list_to_join`, `membership_policy`) that holds a member more than once; the join has one row per member, at its first position"},
    {:load_join_stale_member, :error, :unresolved, :load,
     "a member a list normalized to a join held at an earlier load and no longer holds in the export: its row stays and keeps any access a privacy rule grants through the list; blocks a real load before writes, unless the run prunes it (the loader wrote it, WTF-414) or acknowledges it (`acknowledge_unowned`)"},
    {:load_prune_record, :info, :preserved, :load,
     "a record the loader wrote at an earlier load that the complete export no longer holds (deleted in Bubble); `prune: true` deletes it after the upserts"},
    {:load_prune_join_member, :info, :preserved, :load,
     "a member of a list normalized to a join that the loader wrote and the list no longer holds; `prune: true` clears the list's column, deleting the row when no other list holds it"},
    {:load_prune_mass_delete, :error, :unresolved, :load,
     "pruning would delete all, or more than half, of the rows of a data type or join list the loader wrote (a wrong, filtered or empty export looks like this); blocks unless named in `prune: [allow_mass_delete: [...]]`"},
    {:load_prune_unowned, :warning, :unresolved, :load,
     "a row the complete export does not hold that the loader did not write (e.g. created in the app after go-live, or loaded before WTF-414 recorded what the loader writes); pruning never deletes it (a join row of this kind blocks unless acknowledged in `prune: [acknowledge_unowned: ...]`)"},
    {:load_join_asymmetric, :info, :preserved, :load,
     "a member of a list normalized to a join whose table the mirrored list shares, and whose own (exported) list does not list the owner back; each list keeps its own membership column, so nothing is added to the other list"},
    {:load_duplicate_email, :error, :unresolved, :load,
     "users whose trimmed emails are equal ignoring case; the target's unique email identity refuses them, so nothing is written"},
    {:load_invalid_email, :warning, :degraded, :load,
     "a user email without an `@`; loaded as empty"},
    {:load_auth_status_unmapped, :warning, :unresolved, :load,
     "users' email-confirmed status, which the target has no column for; kept in the export"},
    {:load_confirmed_at_migrated, :info, :degraded, :load,
     "confirmed users: Bubble keeps a confirmed flag, not when the email was confirmed, so their `confirmed_at` is their Created Date (a migrated value, not a confirmation time)"},
    {:load_confirmed_at_undated, :warning, :degraded, :load,
     "users Bubble has confirmed but without a readable Created Date; loaded unconfirmed (`confirmed_at` nil) until they sign in with a magic link"},
    {:load_auth_provider_unmigrated, :warning, :unresolved, :load,
     "users with a sign-in method other than email (a social login); v1 signs users in by magic link to their email only"},
    {:load_file_failed, :warning, :unresolved, :load,
     "a Bubble file the export could not fetch, or whose copy to the target storage failed its checksum; the field keeps the Bubble URL"},
    {:load_file_not_bubble, :info, :preserved, :load,
     "a file field holding a URL outside Bubble's storage; loaded as given, not copied"},
    {:load_file_url_in_text, :info, :preserved, :load,
     "a text value containing a Bubble file URL; not rewritten (only file and image fields are)"},
    {:load_file_public_on_restricted_type, :info, :preserved, :load,
     "public Bubble file URLs on a data type whose privacy rules do not let everyone view attached files; copied public, as Bubble served them"}
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
          stage: :read | :parse | :model | :load | :target,
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
