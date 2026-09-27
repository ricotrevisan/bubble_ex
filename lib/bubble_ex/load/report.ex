defmodule BubbleEx.Load.Report do
  @moduledoc """
  What a load (or a dry run) found and did (`BubbleEx.Load.run/4`).

    * `dry_run` - true when nothing was written
    * `blocked` - the codes of the error diagnostics that stop a real run
      (a schema mismatch, duplicate emails, an incomplete export without
      `allow_partial: true`); `[]` when it may run
    * `run` - the ledger's run key (nil for a dry run)
    * `export_sha256`, `plan_sha256`, `target` - what was loaded, by what
      plan, into which database (its credential-free identity)
    * `types` - per data type: `rows` (exported), `records` (distinct valid
      `_id`s: what loads), `duplicates`, `invalid` (rows without an `_id`),
      and for a real run `inserted`, `updated`, `unchanged` (cumulative over
      the run's ledger) and `resumed` (rows this invocation skipped because
      the ledger had them)
    * `joins` - per list of a join table (keyed `<join ID>/<type>/<field>`,
      `BubbleEx.Load.Plan.Join`): `rows` (one per member), and for a real
      run `inserted`, `updated`, `unchanged` and `resumed` (as for types)
    * `files` - `referenced` (distinct Bubble file URLs in file fields),
      `public`, `private`, `copied` (verified in the target storage, or
      would be for a dry run), `failed`
    * `auth` - `users`, `with_email`, `confirmed`, `unconfirmed`, `unknown`
      (no confirmed status), and `confirmed_column` (whether the target
      stores the status)
    * `diagnostics` - the `:load` diagnostics (and the target's schema
      diagnostics), normalized; counts and sample record IDs, never stored
      values

  `to_map/1` is its JSON form.
  """

  alias BubbleEx.Diagnostic

  defstruct dry_run: true,
            blocked: [],
            run: nil,
            export_sha256: nil,
            plan_sha256: nil,
            target: nil,
            types: %{},
            joins: %{},
            files: %{},
            auth: %{},
            diagnostics: []

  @type t :: %__MODULE__{
          dry_run: boolean(),
          blocked: [atom()],
          run: String.t() | nil,
          export_sha256: String.t() | nil,
          plan_sha256: String.t() | nil,
          target: String.t() | nil,
          types: %{String.t() => map()},
          joins: %{String.t() => map()},
          files: map(),
          auth: map(),
          diagnostics: [Diagnostic.t()]
        }

  @doc "JSON form (string keys)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = r) do
    r
    |> Map.from_struct()
    |> Map.update!(:diagnostics, &Enum.map(&1, fn d -> Diagnostic.to_map(d) end))
    |> json()
  end

  defp json(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp json(v), do: v
end
