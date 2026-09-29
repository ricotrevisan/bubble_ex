defmodule BubbleEx.Load.Report do
  @moduledoc """
  What a load (or a dry run) found and did (`BubbleEx.Load.run/4`).

    * `dry_run` - true when nothing was written
    * `blocked` - the codes of diagnostics that stop a real run
      (a schema mismatch, stale join membership, duplicate emails, an
      incomplete export without `allow_partial: true`); `[]` when it may run.
      Stale join membership (`:load_join_stale_member`) blocks a load into
      a database holding join rows the export no longer lists, unless the
      run prunes them (WTF-414: those the loader wrote) or acknowledges
      them by name (`acknowledge_unowned`). A prune that would delete all
      or most of a type or list the loader wrote blocks too
      (`:load_prune_mass_delete`). The diagnostic's
      `details.stale_members` lists them (`table`, `left_column`,
      `right_column`, `membership_column`, `rows` as `[left ID, right
      ID]`). An `allow_partial` run in which an owner type failed blocks
      this way when that type owns join rows (all of them look stale):
      re-export it instead (pruning refuses a partial export)
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
    * `prune` - nil unless the run prunes (`prune:`); else the plan, from
      the target as this invocation found it: `sha256` (what a real run
      confirms with `prune: [expect: sha256]`), `types` per data type,
      `delete` (records the loader wrote that the export no longer holds),
      `owned` (the loader's records the target holds) and `unowned`
      (records the export does not hold that the loader did not write:
      kept, `:load_prune_unowned`); `joins` per list (keyed as `joins`),
      `remove` (members the loader wrote that the list no longer holds),
      `owned` and `unowned` (acknowledged ones). A real run adds `deleted`
      (rows deleted) and `cleared` (join rows kept with the list's column
      cleared, another list holding them), over the run's ledger. Counts
      and a hash only; the diagnostics hold sample IDs
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
            prune: nil,
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
          prune: map() | nil,
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
