defmodule BubbleEx.Load.Issues do
  @moduledoc false

  # Aggregates the loader's issues per code, data type and field (a count,
  # the reasons and a few sample record IDs; never a stored value) and
  # turns them into `:load` diagnostics.

  alias BubbleEx.Diagnostic

  @samples 5

  @type t :: %{optional({atom(), String.t() | nil, String.t() | nil}) => map()}

  @spec new() :: t()
  def new, do: %{}

  @doc false
  # Adds one issue of record `id` (nil for a type-level issue).
  @spec add(t(), atom(), String.t() | nil, String.t() | nil, String.t() | nil, term()) :: t()
  def add(acc, code, type, field, id, detail) do
    Map.update(acc, {code, type, field}, entry(id, detail), fn e ->
      %{
        e
        | count: e.count + 1,
          samples: sample(e.samples, id),
          reasons: reason(e.reasons, detail)
      }
    end)
  end

  @doc false
  # Adds `n` occurrences of a type-level issue at once.
  @spec add_count(t(), atom(), String.t(), String.t() | nil, integer()) :: t()
  def add_count(acc, _code, _type, _field, n) when n < 1, do: acc

  def add_count(acc, code, type, field, n) do
    Map.update(
      acc,
      {code, type, field},
      %{count: n, samples: [], reasons: %{}},
      &%{&1 | count: &1.count + n}
    )
  end

  defp entry(id, detail),
    do: %{count: 1, samples: sample([], id), reasons: reason(%{}, detail)}

  defp sample(samples, nil), do: samples

  defp sample(samples, id) do
    if length(samples) < @samples and id not in samples, do: samples ++ [id], else: samples
  end

  # An integer detail adds up (e.g. IDs dropped from a list); an atom
  # counts occurrences; other terms are ignored.
  defp reason(reasons, n) when is_integer(n), do: Map.update(reasons, :items, n, &(&1 + n))
  defp reason(reasons, nil), do: reasons
  defp reason(reasons, r) when is_atom(r), do: Map.update(reasons, r, 1, &(&1 + 1))

  # `{tag, name}` counts names (schema names, e.g. a row key) under `tag`.
  defp reason(reasons, {tag, name}) when is_atom(tag) and is_binary(name),
    do: Map.update(reasons, tag, %{name => 1}, &Map.update(&1, name, 1, fn n -> n + 1 end))

  defp reason(reasons, _), do: reasons

  @doc false
  @spec merge(t(), t()) :: t()
  def merge(a, b) do
    Map.merge(a, b, fn _k, x, y ->
      %{
        count: x.count + y.count,
        samples: Enum.take(Enum.uniq(x.samples ++ y.samples), @samples),
        reasons: Map.merge(x.reasons, y.reasons, fn _, m, n -> add(m, n) end)
      }
    end)
  end

  defp add(m, n) when is_map(m), do: Map.merge(m, n, fn _, a, b -> a + b end)
  defp add(m, n), do: m + n

  @doc false
  @spec diagnostics(t()) :: [Diagnostic.t()]
  def diagnostics(acc) do
    acc
    |> Enum.map(fn {{code, type, field}, e} -> build(code, subject(type, field), details(e)) end)
    |> Diagnostic.normalize()
  end

  defp subject(nil, _), do: %{}
  defp subject(type, nil), do: %{type: type}
  defp subject(type, field), do: %{type: type, field: field}

  defp details(e) do
    Map.merge(%{count: e.count, sample_ids: e.samples}, e.reasons)
  end

  defp where(%{type: t, field: f}), do: "#{t}.#{f}"
  defp where(%{type: t}), do: t
  defp where(_), do: "the export"

  # One clause per code, so every code reaches Diagnostic.new/4 as a literal.
  defp build(:load_export_partial, s, d),
    do:
      Diagnostic.new(:load_export_partial, "", "#{where(s)} did not export completely",
        subject: s,
        details: d
      )

  defp build(:load_type_unmapped, s, d),
    do:
      Diagnostic.new(
        :load_type_unmapped,
        "",
        "#{d.count} exported rows of #{where(s)} are not loaded: the target does not map the type",
        subject: s,
        details: d
      )

  defp build(:load_type_not_exported, s, d),
    do:
      Diagnostic.new(:load_type_not_exported, "", "#{where(s)} has no rows in the export",
        subject: s,
        details: d
      )

  defp build(:load_invalid_record_id, s, d),
    do:
      Diagnostic.new(
        :load_invalid_record_id,
        "",
        "#{d.count} rows of #{where(s)} have no usable _id and are not loaded",
        subject: s,
        details: d
      )

  defp build(:load_unexpected_id_format, s, d),
    do:
      Diagnostic.new(
        :load_unexpected_id_format,
        "",
        "#{d.count} rows of #{where(s)} have an _id not shaped like a Bubble unique ID",
        subject: s,
        details: d
      )

  defp build(:load_duplicate_record, s, d),
    do:
      Diagnostic.new(
        :load_duplicate_record,
        "",
        "#{d.count} rows of #{where(s)} repeat an exported _id; one copy is loaded",
        subject: s,
        details: d
      )

  defp build(:load_unmapped_key, s, d),
    do:
      Diagnostic.new(
        :load_unmapped_key,
        "",
        "rows of #{where(s)} hold keys that are no field of the type",
        subject: s,
        details: d
      )

  defp build(:load_ambiguous_key, s, d),
    do:
      Diagnostic.new(
        :load_ambiguous_key,
        "",
        "rows of #{where(s)} hold keys naming more than one field; map them with :keys",
        subject: s,
        details: d
      )

  defp build(:load_nul_stripped, s, d),
    do:
      Diagnostic.new(
        :load_nul_stripped,
        "",
        "#{d.count} values of #{where(s)} held NUL characters, stripped",
        subject: s,
        details: d
      )

  defp build(:load_email_conflict, s, d),
    do:
      Diagnostic.new(
        :load_email_conflict,
        "",
        "#{d.count} users of #{where(s)} have an email the target gives a record the export does not hold",
        subject: s,
        details: d
      )

  defp build(:load_deleted_field_data, s, d),
    do:
      Diagnostic.new(
        :load_deleted_field_data,
        "",
        "#{d.count} rows hold values of the deleted field #{where(s)}",
        subject: s,
        details: d
      )

  defp build(:load_type_mismatch, s, d),
    do:
      Diagnostic.new(
        :load_type_mismatch,
        "",
        "#{d.count} values of #{where(s)} do not fit its type",
        subject: s,
        details: d
      )

  defp build(:load_unknown_option, s, d),
    do:
      Diagnostic.new(
        :load_unknown_option,
        "",
        "#{d.count} values of #{where(s)} are no live option",
        subject: s,
        details: d
      )

  defp build(:load_option_by_label, s, d),
    do:
      Diagnostic.new(
        :load_option_by_label,
        "",
        "#{d.count} values of #{where(s)} were matched by display text",
        subject: s,
        details: d
      )

  defp build(:load_invalid_reference, s, d),
    do:
      Diagnostic.new(
        :load_invalid_reference,
        "",
        "#{d.count} values of #{where(s)} are not Bubble unique IDs and load empty",
        subject: s,
        details: d
      )

  defp build(:load_dangling_reference, s, d),
    do:
      Diagnostic.new(
        :load_dangling_reference,
        "",
        "#{d.count} references of #{where(s)} name records the export does not hold",
        subject: s,
        details: d
      )

  defp build(:load_deleted_ids_dropped, s, d),
    do:
      Diagnostic.new(
        :load_deleted_ids_dropped,
        "",
        "IDs of missing records were dropped from #{d.count} lists of #{where(s)}",
        subject: s,
        details: d
      )

  defp build(:load_derived_drift, s, d),
    do:
      Diagnostic.new(
        :load_derived_drift,
        "",
        "#{d.count} stored values of #{where(s)} differ from the derived value",
        subject: s,
        details: d
      )

  defp build(:load_reverse_list_drift, s, d),
    do:
      Diagnostic.new(
        :load_reverse_list_drift,
        "",
        "#{d.count} stored lists of #{where(s)} differ from the records pointing back",
        subject: s,
        details: d
      )

  defp build(:load_duplicate_email, s, d),
    do:
      Diagnostic.new(
        :load_duplicate_email,
        "",
        "#{d.count} users of #{where(s)} share an email with another user (ignoring case)",
        subject: s,
        details: d
      )

  defp build(:load_invalid_email, s, d),
    do:
      Diagnostic.new(
        :load_invalid_email,
        "",
        "#{d.count} emails of #{where(s)} have no @ and load empty",
        subject: s,
        details: d
      )

  defp build(:load_auth_status_unmapped, s, d),
    do:
      Diagnostic.new(
        :load_auth_status_unmapped,
        "",
        "the target has no column for users' email-confirmed status (#{d.count} users)",
        subject: s,
        details: d
      )

  defp build(:load_confirmed_at_migrated, s, d),
    do:
      Diagnostic.new(
        :load_confirmed_at_migrated,
        "",
        "#{d.count} confirmed users of #{where(s)} get their Created Date as confirmed_at " <>
          "(Bubble records no confirmation time)",
        subject: s,
        details: d
      )

  defp build(:load_confirmed_at_undated, s, d),
    do:
      Diagnostic.new(
        :load_confirmed_at_undated,
        "",
        "#{d.count} confirmed users of #{where(s)} have no readable Created Date; " <>
          "they load unconfirmed (confirmed_at nil) until they sign in with a magic link",
        subject: s,
        details: d
      )

  defp build(:load_auth_provider_unmigrated, s, d),
    do:
      Diagnostic.new(
        :load_auth_provider_unmigrated,
        "",
        "#{d.count} users of #{where(s)} have a sign-in method other than email",
        subject: s,
        details: d
      )

  defp build(:load_file_failed, s, d),
    do:
      Diagnostic.new(
        :load_file_failed,
        "",
        "#{d.count} files of #{where(s)} were not copied; they keep the Bubble URL",
        subject: s,
        details: d
      )

  defp build(:load_file_not_bubble, s, d),
    do:
      Diagnostic.new(
        :load_file_not_bubble,
        "",
        "#{d.count} values of #{where(s)} are URLs outside Bubble's storage",
        subject: s,
        details: d
      )

  defp build(:load_file_url_in_text, s, d),
    do:
      Diagnostic.new(
        :load_file_url_in_text,
        "",
        "#{d.count} texts of #{where(s)} contain Bubble file URLs",
        subject: s,
        details: d
      )

  defp build(:load_file_public_on_restricted_type, s, d),
    do:
      Diagnostic.new(
        :load_file_public_on_restricted_type,
        "",
        "#{d.count} public files of #{where(s)} are on a type whose rules restrict attached files",
        subject: s,
        details: d
      )
end
