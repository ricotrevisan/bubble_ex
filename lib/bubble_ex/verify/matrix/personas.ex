defmodule BubbleEx.Verify.Matrix.Personas do
  @moduledoc """
  The personas of a privacy matrix (WTF-358 §3.2) and the records that
  give their users the values the rule conditions read.

  | persona | user |
  |---------|------|
  | `anonymous` | none (logged out) |
  | `logged_in_empty` | a user with every field empty (no role, no flags) |
  | `w1_member` | world 1, first variant (e.g. the role option most rules compare with) |
  | `w1_other` | world 1, second variant (another option value) |
  | `w2_member` | world 2, first variant |
  | `admin` | world 3, every yes/no the conditions read is yes |

  Every field chain a supported condition reads from `Current User` gets a
  value, walked outward from the user record:

    * a reference on the user record is a record of the persona's own
      (`u.<persona>.<field>`, e.g. its role); a reference read further out
      is the world's *anchor* of that type (`a.<type>.w<N>`, e.g. the
      workspace), shared by the personas of the world, so tenancy
      conditions (`This's workspace = Current User's role's workspace`) can
      hold or fail by world. An anchor user is the world's first persona
    * a list of records is `[anchor]` (the second variant's own lists also
      hold world 2's anchor: a member of another workspace too); a list of
      users is the world's persona users
    * an option is the variant's pick among the options the conditions
      compare that field with (first variant: an option compared with
      `is`/`contains`; second: another), a yes/no is yes only for `admin`
      (and on anchors outside world 2), text and numbers take the literals
      compared with them, dates a fixed day

  Anchors of world 2 take the second variant and no flags, so a condition
  on the workspace's own settings is false there. Persona users have an
  email at the reserved domain `replay.wtf.invalid`. Keys and values are
  deterministic.
  """

  alias BubbleEx.Expression.IR
  alias BubbleEx.Model
  alias BubbleEx.Model.Type
  alias BubbleEx.Verify.Interpreter
  alias BubbleEx.Verify.Interpreter.Dataset

  @specs [
    %{id: "anonymous", user: false, world: nil, variant: 0, admin: false},
    %{id: "logged_in_empty", user: true, world: nil, variant: 0, admin: false},
    %{id: "w1_member", user: true, world: 1, variant: 0, admin: false},
    %{id: "w1_other", user: true, world: 1, variant: 1, admin: false},
    %{id: "w2_member", user: true, world: 2, variant: 0, admin: false},
    %{id: "admin", user: true, world: 3, variant: 0, admin: true}
  ]
  @day 86_400_000
  @base_date 1_759_363_200_000

  @doc "The persona IDs, in synthesis order."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@specs, & &1.id)

  @doc "The user record key of persona `id` (nil for `anonymous`)."
  @spec user_key(String.t()) :: String.t() | nil
  def user_key("anonymous"), do: nil
  def user_key(id), do: "u." <> id

  @doc """
  The personas (`%{id => user key or nil}`) and a dataset holding their
  users and the records those users reference.
  """
  @spec build(Interpreter.t()) :: {%{String.t() => String.t() | nil}, Dataset.t()}
  def build(%Interpreter{} = interpreter) do
    irs = supported_irs(interpreter)
    paths = irs |> Enum.flat_map(&user_paths/1) |> Enum.uniq() |> Enum.sort()
    literals = irs |> Enum.flat_map(&literals/1) |> Enum.uniq()

    st = %{
      model: interpreter.model,
      literals: literals,
      specs: for(%{user: true} = s <- @specs, into: %{}, do: {user_key(s.id), s}),
      ds: %Dataset{}
    }

    st =
      Enum.reduce(@specs, st, fn
        %{user: false}, st ->
          st

        spec, st ->
          key = user_key(spec.id)
          email = {:text, spec.id <> "@replay.wtf.invalid"}
          %{st | ds: Dataset.put(st.ds, key, "user", %{"email" => email})}
      end)

    st =
      for %{user: true, world: w} = spec when w != nil <- @specs,
          path <- paths,
          reduce: st,
          do: (st -> walk(st, user_key(spec.id), :user, path))

    personas = Map.new(@specs, &{&1.id, user_key(&1.id)})
    {personas, st.ds}
  end

  defp supported_irs(interpreter) do
    for {_id, %{status: status, rules: rules}} <- Enum.sort(interpreter.types),
        status in [:rules, :public],
        %{status: :ok, ir: ir} <- rules,
        do: ir
  end

  # --- what the conditions read -------------------------------------------------

  # Field chains read from the current user, as [{type, field}] from the
  # user outward.
  defp user_paths(%IR{op: :field} = ir) do
    own =
      case user_steps(ir) do
        nil -> []
        steps -> [steps]
      end

    own ++ Enum.flat_map(ir.args, &user_paths/1)
  end

  defp user_paths(%IR{args: args}), do: Enum.flat_map(args, &user_paths/1)
  defp user_paths(list) when is_list(list), do: Enum.flat_map(list, &user_paths/1)
  defp user_paths(_), do: []

  defp user_steps(%IR{op: :current_user}), do: []

  defp user_steps(%IR{op: :field, args: [base, type, field]}) do
    case user_steps(base) do
      nil -> nil
      steps -> steps ++ [{type, field}]
    end
  end

  defp user_steps(%IR{op: op, args: [list]}) when op in [:first, :last], do: user_steps(list)
  defp user_steps(_), do: nil

  # {field key or {:set, option set}, op, literal value} for every
  # comparison of a user-side field chain with a literal or an option.
  defp literals(%IR{op: op, args: [l, r]} = ir)
       when op in [:eq, :neq, :member, :gt, :lt, :gte, :lte] do
    found =
      for {side, other} <- [{l, r}, {r, l}],
          lit = literal(other),
          lit != nil,
          key <- keys(side),
          do: {key, op, lit}

    found ++ Enum.flat_map(ir.args, &literals/1)
  end

  defp literals(%IR{op: :option, args: [set, _, key]}) when is_binary(key),
    do: [{{:set, set}, :any, {:option, key}}]

  defp literals(%IR{args: args}), do: Enum.flat_map(args, &literals/1)
  defp literals(list) when is_list(list), do: Enum.flat_map(list, &literals/1)
  defp literals(_), do: []

  defp literal(%IR{op: :literal, args: [v]}) when is_binary(v), do: {:text, v}
  defp literal(%IR{op: :literal, args: [v]}) when is_number(v), do: {:number, v / 1}
  defp literal(%IR{op: :option, args: [_, _, key]}) when is_binary(key), do: {:option, key}
  defp literal(_), do: nil

  defp keys(%IR{op: :field, args: [_, type, field]}), do: [{type, field}]
  defp keys(%IR{op: op, args: [list]}) when op in [:first, :last], do: keys(list)
  defp keys(_), do: []

  # --- assigning ----------------------------------------------------------------

  defp walk(st, _key, _kind, []), do: st

  defp walk(st, key, kind, [{type, field} | rest]) do
    record = Dataset.fetch(st.ds, key)

    {st, value} =
      if Map.has_key?(record.fields, field) do
        {st, record.fields[field]}
      else
        {st, value} = choose(st, key, kind, type, field)
        {%{st | ds: Dataset.set(st.ds, key, field, value)}, value}
      end

    case {next(value), rest} do
      {nil, _} -> st
      {_, []} -> st
      {next, rest} -> walk(st, next, next_kind(st, next), rest)
    end
  end

  defp next({:ref, key}), do: key
  defp next({:list, [{:ref, key} | _]}), do: key
  defp next(_), do: nil

  defp next_kind(st, key) do
    cond do
      Map.has_key?(st.specs, key) -> :user
      String.starts_with?(key, "u.") -> :owned
      true -> :anchor
    end
  end

  defp choose(st, key, kind, type, field) do
    spec = spec(st, key, kind)

    case Model.field(st.model, type, field) do
      {:ok, %{type: t}} -> value(st, key, kind, spec, {type, field}, t)
      :error -> {st, nil}
    end
  end

  # Whose values a record takes: a persona user its persona's; an owned
  # record the persona's that owns it; an anchor its world's.
  defp spec(st, key, :user), do: Map.fetch!(st.specs, key)

  defp spec(st, key, :owned) do
    owner = st.specs |> Map.keys() |> Enum.find(&String.starts_with?(key, &1 <> "."))
    Map.fetch!(st.specs, owner)
  end

  defp spec(_st, key, :anchor) do
    world =
      key |> String.split(".") |> List.last() |> String.trim_leading("w") |> String.to_integer()

    %{world: world, variant: if(world == 2, do: 1, else: 0), admin: world != 2}
  end

  defp value(st, key, kind, spec, {_, field}, %Type{kind: :ref, cardinality: :one, target: target}) do
    if kind == :user do
      owned = key <> "." <> slug(field)
      owned = unique(st.ds, owned)
      {%{st | ds: Dataset.put(st.ds, owned, target, %{})}, {:ref, owned}}
    else
      anchor(st, target, spec.world)
    end
  end

  defp value(st, _key, _kind, spec, _at, %Type{kind: :ref, cardinality: :many, target: "user"}),
    do: {st, {:list, Enum.map(world_users(spec.world), &{:ref, &1})}}

  # A second-variant persona's own lists also hold world 2's anchor: it
  # belongs to another workspace besides its current one.
  defp value(st, _key, kind, spec, _at, %Type{kind: :ref, cardinality: :many, target: target}) do
    worlds =
      if kind != :anchor and spec.variant == 1, do: Enum.uniq([spec.world, 2]), else: [spec.world]

    {st, refs} =
      Enum.reduce(worlds, {st, []}, fn world, {st, refs} ->
        {st, ref} = anchor(st, target, world)
        {st, refs ++ [ref]}
      end)

    {st, {:list, refs}}
  end

  defp value(st, _key, _kind, spec, at, %Type{kind: :option, cardinality: card, target: set}) do
    case pick(st, at, set, spec.variant) do
      nil -> {st, nil}
      key -> {st, many(card, {:option, key})}
    end
  end

  defp value(st, _key, _kind, spec, at, %Type{kind: :scalar, base: base, cardinality: card}) do
    lits = for {^at, _op, {tag, v}} <- st.literals, tag == base, do: v

    v =
      case base do
        :boolean -> {:boolean, spec.admin}
        :text -> {:text, text(lits, spec)}
        :number -> {:number, List.first(Enum.sort(lits)) || spec.world / 1}
        :date -> {:date, @base_date + spec.world * @day}
        _ -> nil
      end

    {st, v && many(card, v)}
  end

  defp value(st, _key, _kind, _spec, _at, _type), do: {st, nil}

  defp many(:many, v), do: {:list, [v]}
  defp many(_, v), do: v

  defp text(lits, spec) do
    case {Enum.sort(lits), spec.variant} do
      {[first | _], 0} -> first
      {_, 1} -> "other"
      {[], 0} -> "w#{spec.world}"
    end
  end

  # The option of `set` for `variant`: first an option the conditions
  # compare this field with by `is` / `contains`, then another.
  defp pick(st, at, set, variant) do
    options =
      case Model.option_set(st.model, set) do
        %{values: values} -> for v <- values, not v.deleted, is_binary(v.key), do: v.key
        nil -> []
      end

    eq = option_literals(st, fn {k, op, _} -> k == at and op in [:eq, :member] end)
    field = option_literals(st, fn {k, _, _} -> k == at end)
    in_set = option_literals(st, fn {k, _, _} -> k == {:set, set} end)

    first = List.first(eq ++ field ++ in_set ++ options)
    second = List.first((field ++ in_set ++ options) -- [first]) || first
    if variant == 0, do: first, else: second
  end

  defp option_literals(st, keep?) do
    for({_, _, {:option, k}} = lit <- st.literals, keep?.(lit), do: k)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp anchor(st, "user", world), do: {st, {:ref, hd(world_users(world))}}

  defp anchor(st, type, world) do
    key = "a.#{slug(type)}.w#{world}"

    if Dataset.fetch(st.ds, key),
      do: {st, {:ref, key}},
      else: {%{st | ds: Dataset.put(st.ds, key, type, %{})}, {:ref, key}}
  end

  defp world_users(1), do: ["u.w1_member", "u.w1_other"]
  defp world_users(2), do: ["u.w2_member"]
  defp world_users(3), do: ["u.admin"]

  defp unique(ds, key) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> key
      n -> "#{key}_#{n}"
    end)
    |> Enum.find(&is_nil(Dataset.fetch(ds, &1)))
  end

  @doc false
  @spec slug(String.t()) :: String.t()
  def slug(text), do: String.replace(text, ~r/[^A-Za-z0-9_\-]/, "_")
end
