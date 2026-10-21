defmodule BubbleEx.Frontend.RenderDiff do
  @moduledoc """
  Compares a page as Bubble rendered it with the same page as the generated
  Phoenix app rendered it, element by element, and explains each difference
  from the export.

  Both sides are captures in the shape `scripts/vertical_slice/render_capture.js`
  writes (one page at one width):

      %{"source" => "bubble" | "bubble_ex", "path" => ..., "width" => ...,
        "elements" => [%{"i" => 0, "id" => "bTGYf", "type" => "Text",
                         "parent" => nil | index, "visible" => true,
                         "box" => [x, y, w, h], "text" => "own text",
                         "imgs" => [...], "marker" => %{...}}]}

  On the Bubble side the capture reads each element's export ID from the
  runtime (`node.bubble_data.bubble_instance.element.id()`); on ours it reads
  `data-bubble-id`, so both sides join on the export element ID. A repeated
  element (a repeating group's cell) has one entry per instance.

  `diff/4` reports, per element ID:

    * `:only_bubble` - visible in Bubble, not in ours (absent or hidden)
    * `:only_ours` - visible in ours, not in Bubble
    * `:count_differs` - visible on both sides, a different number of times
    * `:text_differs` - visible on both sides with different own text
    * `:box_off` - visible on both sides, its size or its offset in its
      parent off by more than `:box_tolerance` pixels

  An element whose nearest flagged ancestor has the same kind
  (`:only_bubble`/`:only_ours`) is folded into it, so a hidden group is one
  difference that accounts for its whole subtree. Each difference carries
  the content it accounts for (visible characters and area on the side that
  shows it), the export's reasons (type, default visibility, the conditions
  that change visibility, data source, text expression, owner reusable) and
  ours (dev marker titles, placeholders, `data-bubble-visible`, the
  generated code's `TODO(bubble:ID)` notes when a project is given), and a
  category:

    * `:export_drift` - the element is not in the export the app was
      generated from (`:generated_from`), so the difference is the branch's
    * `:known` - listed by the owner in `:known` (see `parse_known/1`:
      stricter privacy, server-side counts, branch drift...)
    * `:marked` - ours marks the element or an ancestor as not migrated
    * `:unexplained` - none of the above: a candidate bug

  The first three are grouped as known differences, apart from the
  candidate bugs. Nothing here reads Bubble or the network; the captures
  are files the caller made.
  """

  alias BubbleEx.Expression

  @kinds [:only_bubble, :only_ours, :count_differs, :text_differs, :box_off]
  @fold_kinds [:only_bubble, :only_ours]
  @known_categories [:export_drift, :known, :marked]
  @known_classes ~w(privacy server_data drift capture_gap other)

  @typedoc "An owner-listed difference: why, its class, and the kinds it covers."
  @type known_entry :: %{reason: String.t(), class: String.t(), kinds: :all | [atom()]}

  @type capture :: map()
  @type element_info :: map()
  @type difference :: map()

  @doc """
  Indexes the elements of an app (Bubble editor JSON: `pages` and
  `element_definitions`) by export ID.

  Each entry has `:type`, `:name`, `:owner` (`"page:<name>"` or
  `"reusable:<name>"`), `:parent`, `:hidden_by_default`,
  `:visibility_conditions` and `:other_conditions` (rendered, with the
  properties they set), `:condition_count`, `:data_source`
  and `:text` (rendered expressions, `nil` when absent).
  """
  @spec index(map(), keyword()) :: %{String.t() => element_info()}
  def index(app, opts \\ []) when is_map(app) do
    schema = Keyword.get_lazy(opts, :schema, fn -> schema(app) end)
    render = &render_expression(&1, schema)

    pages =
      for {_key, page} <- map(app["pages"]), is_map(page), reduce: %{} do
        acc ->
          owner = "page:" <> to_string(page["name"] || page["id"])
          acc = put_root(acc, page, owner)
          walk(acc, page["elements"], owner, page["id"], render)
      end

    for {key, definition} <- map(app["element_definitions"]), is_map(definition), reduce: pages do
      acc ->
        owner = "reusable:" <> to_string(definition["name"] || definition["id"] || key)
        definition = Map.put_new(definition, "id", key)
        acc = put_root(acc, definition, owner)
        walk(acc, definition["elements"], owner, definition["id"], render)
    end
  end

  defp schema(app) do
    case BubbleEx.Model.build(app) do
      {:ok, model} -> BubbleEx.Model.schema(model)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp put_root(acc, element, owner) do
    Map.put(acc, to_string(element["id"]), %{
      type: element["type"],
      name: element["name"],
      owner: owner,
      parent: nil,
      hidden_by_default: false,
      visibility_conditions: [],
      condition_count: 0,
      other_conditions: [],
      data_source: nil,
      text: nil
    })
  end

  defp walk(acc, elements, owner, parent, render) do
    for {key, element} <- map(elements), is_map(element), reduce: acc do
      acc ->
        id = to_string(element["id"] || key)
        props = map(element["properties"])

        states =
          element["states"] |> map() |> Enum.sort_by(&state_order/1) |> Enum.map(&elem(&1, 1))

        info = %{
          type: element["type"],
          name: element["name"],
          owner: owner,
          parent: parent,
          hidden_by_default: props["is_visible"] == false,
          visibility_conditions:
            for(
              state <- states,
              is_map(state),
              Map.has_key?(map(state["properties"]), "is_visible"),
              do: %{
                when: render.(state["condition"]),
                visible: map(state["properties"])["is_visible"] != false
              }
            ),
          condition_count: length(states),
          other_conditions:
            Enum.flat_map(states, fn state ->
              keys =
                (is_map(state) && map(state["properties"]))
                |> map()
                |> Map.keys()
                |> Enum.reject(&(&1 == "is_visible"))

              if keys == [],
                do: [],
                else: [%{when: render.(state["condition"]), sets: Enum.sort(keys)}]
            end),
          data_source: if(props["data_source"], do: render.(props["data_source"])),
          text: if(is_map(props["text"]), do: render.(props["text"]))
        }

        acc
        |> Map.put(id, info)
        |> walk(element["elements"], owner, id, render)
    end
  end

  defp state_order({key, _}) do
    case Integer.parse(to_string(key)) do
      {n, ""} -> n
      _ -> key
    end
  end

  defp render_expression(nil, _schema), do: nil

  defp render_expression(raw, schema) do
    opts = if schema, do: [schema: schema], else: []

    with {:ok, parsed} <- Expression.parse(raw, opts),
         {:ok, text} <- Expression.render(parsed.ast) do
      truncate(text, 300)
    else
      _ -> "(expression not parsed)"
    end
  rescue
    _ -> "(expression not parsed)"
  end

  @doc """
  Reads a known-differences file's JSON (decoded): an object keyed by
  export element ID, each value a reason, or an entry:

      {
        "bA1": "stricter privacy: ours shows the comments to their author only",
        "bB2": {"reason": "the tally counts records Bubble counts on the server",
                "class": "server_data", "kinds": ["count_differs"]}
      }

    * `reason` - required, shown with the difference
    * `class` - one of #{Enum.map_join(@known_classes, ", ", &"`#{&1}`")}
      (default `other`): `privacy` (ours is stricter on purpose),
      `server_data` (a count or list Bubble computes on the server and never
      sends to the browser, so a capture cannot seed it), `drift` (the
      branch Bubble served differs from the export the app was generated
      from), `capture_gap` (the captured records miss what the element
      reads, e.g. a reference to a record the page never held)
    * `kinds` - the difference kinds it covers (default all):
      #{Enum.map_join(@kinds, ", ", &"`#{&1}`")}

  Keys starting with `$` are comments and skipped. Returns
  `%{id => known_entry}`.
  """
  @spec parse_known(term()) :: {:ok, %{String.t() => known_entry()}} | {:error, String.t()}
  def parse_known(json) when is_map(json) do
    json
    |> Enum.reject(fn {id, _} -> is_binary(id) and String.starts_with?(id, "$") end)
    |> Enum.reduce_while({:ok, %{}}, fn {id, value}, {:ok, acc} ->
      case known_entry(value) do
        {:ok, entry} -> {:cont, {:ok, Map.put(acc, id, entry)}}
        {:error, why} -> {:halt, {:error, "#{id}: #{why}"}}
      end
    end)
  end

  def parse_known(_json),
    do: {:error, ~s(expected a JSON object {"<element id>": "<reason>" or {"reason": ...}})}

  defp known_entry(reason) when is_binary(reason),
    do: {:ok, %{reason: reason, class: "other", kinds: :all}}

  defp known_entry(%{"reason" => reason} = entry) when is_binary(reason) do
    class = Map.get(entry, "class", "other")
    kinds = Map.get(entry, "kinds", :all)
    names = Enum.map(@kinds, &Atom.to_string/1)
    extra = Map.keys(entry) -- ["reason", "class", "kinds"]

    cond do
      extra != [] ->
        {:error, "unknown keys #{inspect(Enum.sort(extra))}"}

      class not in @known_classes ->
        {:error, "class must be one of #{Enum.join(@known_classes, ", ")}"}

      kinds == :all ->
        {:ok, %{reason: reason, class: class, kinds: :all}}

      is_list(kinds) and kinds != [] and Enum.all?(kinds, &(&1 in names)) ->
        {:ok, %{reason: reason, class: class, kinds: Enum.map(kinds, &String.to_existing_atom/1)}}

      true ->
        {:error, "kinds must be a non-empty list of #{Enum.join(names, ", ")}"}
    end
  end

  defp known_entry(_value), do: {:error, "every value must be a reason or an entry with a reason"}

  @doc """
  Compares a Bubble capture with ours for the same page and width.

  Options:

    * `:box_tolerance` - pixels (default 32)
    * `:generated_from` - the index (`index/2`) of the export the app was
      generated from, when it differs from the one Bubble served
    * `:known` - the differences the owner accepts as intended:
      `parse_known/1`'s `%{id => entry}`, or `%{id => reason}`
    * `:notes` - `%{id => [note]}` from the generated code
      (`project_notes/1`)
  """
  @spec diff(capture(), capture(), %{String.t() => element_info()}, keyword()) :: map()
  def diff(bubble, ours, index, opts \\ []) when is_map(bubble) and is_map(ours) do
    tolerance = Keyword.get(opts, :box_tolerance, 32)
    opts = Keyword.put(opts, :known, opts |> Keyword.get(:known, %{}) |> normalize_known())
    b = bubble |> normalize_ids(index) |> aggregate()
    o = ours |> normalize_ids(index) |> aggregate()

    raw =
      (Map.keys(b.by_id) ++ Map.keys(o.by_id))
      |> Enum.uniq()
      |> Enum.flat_map(&compare(&1, b, o, tolerance))

    flagged = Map.new(raw, &{{&1.id, &1.kind}, &1})

    root = Map.new(raw, &{{&1.id, &1.kind}, fold_root(&1.id, &1.kind, flagged, b, o)})
    {roots, nested} = Enum.split_with(raw, &(root[{&1.id, &1.kind}] == &1.id))

    roots =
      Enum.reduce(nested, Map.new(roots, &{{&1.id, &1.kind}, &1}), fn d, acc ->
        Map.update(acc, {root[{d.id, d.kind}], d.kind}, d, fn r ->
          %{r | nested: r.nested + 1, chars: r.chars + d.chars}
        end)
      end)
      |> Map.values()
      |> Enum.map(&explain(&1, b, o, index, opts))
      |> Enum.sort_by(&{-&1.chars, -&1.area, &1.id})

    {known, unexplained} = Enum.split_with(roots, &(&1.category in @known_categories))
    listed = Keyword.fetch!(opts, :known)
    # Every difference an entry covers, folded or not: an entry on an
    # element folded into an ancestor's difference still matches, but only
    # the root is categorized, so the owner should list the root.
    used = for d <- raw, known_for(listed, d), into: MapSet.new(), do: d.id

    folded =
      for(d <- nested, known_for(listed, d), do: {d.id, root[{d.id, d.kind}]})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {id, roots} -> {id, roots |> Enum.uniq() |> Enum.sort()} end)

    %{
      path: bubble["path"],
      width: bubble["width"],
      ours_path: ours["path"],
      ours_width: ours["width"],
      matched: %{
        bubble_elements: b.count,
        bubble_with_id: b.with_id,
        ours_elements: o.count,
        ours_with_id: o.with_id,
        ids_both: b.by_id |> Map.keys() |> Enum.count(&Map.has_key?(o.by_id, &1)),
        ids_only_bubble: b.by_id |> Map.keys() |> Enum.count(&(not Map.has_key?(o.by_id, &1))),
        ids_only_ours: o.by_id |> Map.keys() |> Enum.count(&(not Map.has_key?(b.by_id, &1))),
        not_in_export:
          (Map.keys(b.by_id) ++ Map.keys(o.by_id))
          |> Enum.uniq()
          |> Enum.count(&(not Map.has_key?(index, &1)))
      },
      visible_chars: %{bubble: b.visible_chars, ours: o.visible_chars},
      counts: Map.new(@kinds, fn k -> {k, Enum.count(roots, &(&1.kind == k))} end),
      known: known,
      unexplained: unexplained,
      # Owner-listed elements on this page that no difference matched: fixed,
      # or the entry is stale (entries for elements not captured here are
      # for other pages).
      known_unused:
        listed
        |> Map.keys()
        |> Enum.filter(&(Map.has_key?(b.by_id, &1) or Map.has_key?(o.by_id, &1)))
        |> Enum.reject(&MapSet.member?(used, &1))
        |> Enum.sort(),
      # Owner-listed elements whose difference folds into an ancestor's
      # (`%{id => [root id]}`): the root's category is what counts.
      known_folded: folded
    }
  end

  # Bubble names some generated children `<element id>_<suffix>` (e.g. a
  # group per option: `bUsfV0_group_item_<option>_0`); they count as their
  # element when the export has it.
  defp normalize_ids(capture, index) do
    elements =
      capture["elements"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn e ->
        with id when is_binary(id) <- e["id"],
             false <- Map.has_key?(index, id),
             [prefix | _] <- String.split(id, "_", parts: 2),
             true <- prefix != id and Map.has_key?(index, prefix) do
          Map.merge(e, %{"id" => prefix, "variant" => id})
        else
          _ -> e
        end
      end)

    Map.put(capture, "elements", elements)
  end

  # Per side: the instances of each ID, and for each instance index its
  # nearest captured ancestor's ID.
  defp aggregate(capture) do
    elements = capture["elements"] || []
    by_index = Map.new(elements, &{&1["i"], &1})

    by_id =
      elements
      |> Enum.filter(&is_binary(&1["id"]))
      |> Enum.group_by(& &1["id"])

    %{
      count: length(elements),
      by_index: by_index,
      by_id: by_id,
      with_id: Enum.count(elements, &is_binary(&1["id"])),
      visible_chars:
        elements
        |> Enum.filter(& &1["visible"])
        |> Enum.map(&String.length(norm(&1["text"])))
        |> Enum.sum()
    }
  end

  defp compare(id, b, o, tolerance) do
    bi = Map.get(b.by_id, id, [])
    oi = Map.get(o.by_id, id, [])
    bv = Enum.filter(bi, & &1["visible"])
    ov = Enum.filter(oi, & &1["visible"])

    base = %{
      id: id,
      bubble: side(bi, bv),
      ours: side(oi, ov),
      nested: 0,
      reasons: [],
      category: :unexplained
    }

    cond do
      bv != [] and ov == [] ->
        [Map.merge(base, %{kind: :only_bubble, chars: chars(bv), area: area(bv)})]

      ov != [] and bv == [] ->
        [Map.merge(base, %{kind: :only_ours, chars: chars(ov), area: area(ov)})]

      bv == [] ->
        []

      true ->
        both_visible(base, bv, ov, b, o, tolerance)
    end
  end

  defp both_visible(base, bv, ov, b, o, tolerance) do
    # Bubble's generated children (variants) show with their element but
    # are not instances of it: counts and texts compare the elements only.
    {own, variants} = Enum.split_with(bv, &is_nil(&1["variant"]))
    bv = if own == [], do: variants, else: own

    contents =
      if own != [] or variants == [], do: contents_differ(base, bv, ov), else: []

    contents ++ box_off(base, hd(bv), hd(ov), b, o, tolerance)
  end

  # A count difference, else a text one (a count difference changes the
  # texts too). Texts compare as sorted lists: a reordering is no difference.
  defp contents_differ(base, bv, ov) do
    cond do
      length(bv) != length(ov) ->
        [
          Map.merge(base, %{
            kind: :count_differs,
            chars: abs(chars(bv) - chars(ov)),
            area: abs(area(bv) - area(ov))
          })
        ]

      Enum.sort(texts(bv)) != Enum.sort(texts(ov)) ->
        [Map.merge(base, %{kind: :text_differs, chars: max(chars(bv), chars(ov)), area: 0})]

      true ->
        []
    end
  end

  defp box_off(base, be, oe, b, o, tolerance) do
    with {bp, [bx, by, bw, bh]} <- relative_box(be, b),
         {op, [ox, oy, ow, oh]} <- relative_box(oe, o) do
      # Offsets compare only from the same (known) parent element.
      moved = if bp == op and bp != nil, do: [abs(bx - ox), abs(by - oy)], else: []
      off = Enum.max(moved ++ [abs(bw - ow), abs(bh - oh)])
      area = abs(bw * bh - ow * oh)

      if off > tolerance,
        do: [Map.merge(base, %{kind: :box_off, chars: 0, area: area, off: off})],
        else: []
    else
      _ -> []
    end
  end

  defp side(instances, visible) do
    first = List.first(visible) || List.first(instances)

    %{
      instances: length(instances),
      visible: length(visible),
      text: visible |> texts() |> Enum.join(" | ") |> truncate(200),
      box: first && first["box"],
      imgs: visible |> Enum.flat_map(&(&1["imgs"] || [])) |> Enum.uniq() |> Enum.take(3),
      marker: Enum.find_value(instances, & &1["marker"])
    }
  end

  defp texts(instances), do: instances |> Enum.map(&norm(&1["text"])) |> Enum.reject(&(&1 == ""))
  defp chars(instances), do: instances |> texts() |> Enum.map(&String.length/1) |> Enum.sum()

  defp area(instances) do
    instances
    |> Enum.map(fn e ->
      case e["box"] do
        [_, _, w, h] when is_number(w) and is_number(h) -> abs(w * h)
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp relative_box(%{"box" => [x, y, w, h] = box} = element, side) do
    if Enum.all?(box, &is_number/1) do
      case side.by_index[element["parent"]] do
        %{"box" => [px, py, _, _]} = p when is_number(px) and is_number(py) ->
          {p["id"], [x - px, y - py, w, h]}

        _ ->
          {nil, [x, y, w, h]}
      end
    end
  end

  defp relative_box(_element, _side), do: nil

  # The ID a difference folds into: the outermost ancestor (on the side
  # that shows it) flagged with the same kind, followed until it stops
  # (an ancestor may itself fold elsewhere through another instance).
  defp fold_root(id, kind, flagged, b, o) when kind in @fold_kinds,
    do: fold_root(id, kind, flagged, b, o, MapSet.new())

  defp fold_root(id, _kind, _flagged, _b, _o), do: id

  defp fold_root(id, kind, flagged, b, o, seen) do
    side = if kind == :only_bubble, do: b, else: o
    instance = side.by_id |> Map.get(id, []) |> Enum.find(& &1["visible"])
    target = instance && outermost_flagged(instance["parent"], kind, flagged, side, MapSet.new())

    if target in [nil, id] or MapSet.member?(seen, target),
      do: id,
      else: fold_root(target, kind, flagged, b, o, MapSet.put(seen, id))
  end

  defp outermost_flagged(index, kind, flagged, side, visited) do
    parent = side.by_index[index]

    if index == nil or parent == nil or MapSet.member?(visited, index) do
      nil
    else
      above = outermost_flagged(parent["parent"], kind, flagged, side, MapSet.put(visited, index))
      id = parent["id"]
      above || if(is_binary(id) and Map.has_key?(flagged, {id, kind}), do: id)
    end
  end

  defp explain(d, b, o, index, opts) do
    info = Map.get(index, d.id)
    entry = opts |> Keyword.get(:known, %{}) |> known_for(d)
    # An ancestor's marker can explain why an element is not shown, not
    # why its own text or box differs.
    chain =
      if d.kind in [:only_bubble, :only_ours, :count_differs], do: ancestors(d.id, b, o), else: []

    {own, inherited} = ours_reasons(d.id, chain, o, Keyword.get(opts, :notes, %{}))
    category = category(d.id, index, Keyword.get(opts, :generated_from), entry, own)

    reasons =
      [
        if(info == nil, do: "not in the export"),
        if(category == :export_drift, do: drift_reason(info)),
        if(category == :known, do: "owner (#{entry.class}): #{entry.reason}"),
        export_reasons(info, d.kind),
        visibility_reason(d),
        own,
        inherited
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    d
    |> Map.merge(%{reasons: reasons, category: category})
    |> Map.put(:known_class, if(category == :known, do: entry.class))
    |> Map.put(:element, info && Map.take(info, [:type, :name, :owner]))
  end

  # `%{id => reason}` (the older form) or parsed entries.
  defp normalize_known(known) do
    Map.new(known, fn
      {id, reason} when is_binary(reason) ->
        {id, %{reason: reason, class: "other", kinds: :all}}

      {id, %{reason: r} = entry} when is_binary(r) ->
        {id, Map.merge(%{class: "other", kinds: :all}, entry)}

      {id, other} ->
        raise ArgumentError,
              "known entry #{inspect(id)}: expected a reason or an entry from parse_known/1, " <>
                "got #{inspect(other)}"
    end)
  end

  defp known_for(listed, d) do
    case Map.get(listed, d.id) do
      %{kinds: :all} = entry -> entry
      %{kinds: kinds} = entry -> if d.kind in kinds, do: entry
      nil -> nil
    end
  end

  defp category(id, index, generated, entry, own) do
    cond do
      is_map(generated) and Map.has_key?(generated, id) != Map.has_key?(index, id) ->
        :export_drift

      entry != nil ->
        :known

      own != [] ->
        :marked

      true ->
        :unexplained
    end
  end

  defp drift_reason(nil), do: "only in the export the app was generated from"
  defp drift_reason(_info), do: "not in the export the app was generated from"

  # Ours: `{own, inherited}` reasons. Own: the element's dev marker and the
  # generated code's notes for it, or a not-migrated placeholder above it
  # (they make the difference known). Inherited: the nearest marked
  # ancestor's marker and notes, shown but not explaining it.
  defp ours_reasons(id, chain, o, notes) do
    own_marker = o.by_id |> Map.get(id, []) |> Enum.find_value(&marker_note(&1["marker"]))
    own_notes = Enum.map(Map.get(notes, id, []), &"ours (#{id}): #{&1}")
    placeholder = Enum.find_value(chain, &placeholder_above(&1, o))
    own = Enum.reject([own_marker && "ours: #{own_marker}", placeholder], &is_nil/1) ++ own_notes
    {own, Enum.find_value(chain, [], &ancestor_marker(&1, o, notes))}
  end

  defp placeholder_above(aid, o) do
    o.by_id |> Map.get(aid, []) |> Enum.find_value(&placeholder_note(&1["marker"], aid))
  end

  defp placeholder_note(%{"placeholder" => p}, aid) when is_binary(p),
    do: "ours (inside #{aid}): placeholder (#{p})"

  defp placeholder_note(_marker, _aid), do: nil

  defp ancestor_marker(aid, o, notes) do
    marker = o.by_id |> Map.get(aid, []) |> Enum.find_value(&marker_note(&1["marker"]))
    list = Enum.map(Map.get(notes, aid, []), &"ours (ancestor #{aid}): #{&1}")
    list = if marker, do: ["ours (ancestor #{aid}): #{marker}" | list], else: list
    if list == [], do: nil, else: list
  end

  defp export_reasons(nil, _kind), do: []

  defp export_reasons(info, kind) do
    # The other conditionals explain a text or box; an element shown on one
    # side only may also be empty (zero-sized) on the other.
    others =
      if kind == :only_ours,
        do: [],
        else: Enum.map(info.other_conditions, &"sets #{Enum.join(&1.sets, ", ")} when #{&1.when}")

    [
      if(info.hidden_by_default, do: "hidden by default"),
      Enum.map(info.visibility_conditions, fn c ->
        "#{if c.visible, do: "shown", else: "hidden"} when #{c.when}"
      end),
      if(info.data_source, do: "data source: #{info.data_source}"),
      if(info.text, do: "text: #{info.text}"),
      Enum.take(others, 6),
      if(String.starts_with?(info.owner, "reusable:"), do: "in #{info.owner}")
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp visibility_reason(%{ours: %{marker: %{"visible" => v}}}) when is_binary(v),
    do: ["ours: data-bubble-visible=#{v}"]

  defp visibility_reason(_), do: []

  defp marker_note(%{"title" => t}) when is_binary(t) and t != "", do: t
  defp marker_note(%{"dev-note" => _}), do: "dev note (capture with the markers on for its text)"
  defp marker_note(%{"placeholder" => p}) when is_binary(p), do: "placeholder (#{p})"
  defp marker_note(_), do: nil

  # Ancestor IDs from either side's capture, nearest first.
  defp ancestors(id, b, o) do
    from = fn side ->
      case Map.get(side.by_id, id) do
        [first | _] -> up(first["parent"], side, [], MapSet.new())
        _ -> []
      end
    end

    (from.(b) ++ from.(o)) |> Enum.uniq()
  end

  defp up(index, side, acc, visited) do
    case not MapSet.member?(visited, index) and side.by_index[index] do
      %{"id" => id, "parent" => p} when is_binary(id) ->
        up(p, side, [id | acc], MapSet.put(visited, index))

      %{"parent" => p} ->
        up(p, side, acc, MapSet.put(visited, index))

      _ ->
        Enum.reverse(acc)
    end
  end

  @doc """
  Reads the generated project's notes per element: every
  `TODO(bubble:ID) <note>` comment and `Bubble.dev_marker("<note>")` call in
  its `.heex`/`.ex` files under `lib/`.
  """
  @spec project_notes(Path.t()) :: %{String.t() => [String.t()]}
  def project_notes(dir) do
    Path.wildcard(Path.join(dir, "lib/**/*.{heex,ex}"))
    |> Enum.flat_map(fn file -> file |> File.read!() |> notes_in() end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, list} -> {id, Enum.uniq(list)} end)
  end

  @doc false
  def notes_in(source) do
    todos =
      for [_, id, note] <-
            Regex.scan(~r/TODO\(bubble:([A-Za-z0-9]+)\)[ \t]*([^\n]*?)[ \t]*(?:--%>|$)/m, source),
          do: {id, String.trim(note)}

    markers =
      for [_, id, note] <-
            Regex.scan(
              ~r/data-bubble-id="([A-Za-z0-9]+)"[^>]*?Bubble\.dev_marker\(\s*"((?:[^"\\]|\\.)*)"/s,
              source
            ),
          do: {id, unescape(note)}

    Enum.reject(todos ++ markers, &(elem(&1, 1) == ""))
  end

  defp unescape(literal) do
    case Code.string_to_quoted(~s(") <> literal <> ~s(")) do
      {:ok, text} when is_binary(text) -> text
      _ -> literal
    end
  end

  @doc """
  A plain-text summary of a `diff/4` report, the top `n` of each group.
  With `text: false` it leaves the pages' texts out (they are app data).
  """
  @spec summary(map(), pos_integer(), keyword()) :: String.t()
  def summary(report, n \\ 20, opts \\ []) do
    text? = Keyword.get(opts, :text, true)
    m = report.matched

    header = [
      "#{report.path} at #{report.width}px (ours: #{report.ours_path} at #{report.ours_width}px)",
      "matched: bubble #{m.bubble_with_id}/#{m.bubble_elements} elements with an ID, ours #{m.ours_with_id}/#{m.ours_elements}; " <>
        "IDs on both sides #{m.ids_both}, only Bubble #{m.ids_only_bubble}, only ours #{m.ids_only_ours}, not in export #{m.not_in_export}",
      "visible characters: bubble #{report.visible_chars.bubble}, ours #{report.visible_chars.ours}",
      "differences: " <> Enum.map_join(@kinds, ", ", &"#{&1} #{report.counts[&1]}")
    ]

    group = fn title, list ->
      ["", "#{title} (#{length(list)})" | list |> Enum.take(n) |> Enum.map(&line(&1, text?))]
    end

    known = fn category -> Enum.filter(report.known, &(&1.category == category)) end
    unused = Map.get(report, :known_unused, [])
    folded = Map.get(report, :known_folded, %{})

    (header ++
       group.("Unexplained (candidate bugs)", report.unexplained) ++
       group.("Known: owner-listed", known.(:known)) ++
       group.("Known: export drift", known.(:export_drift)) ++
       group.("Known: marked as not migrated in ours", known.(:marked)) ++
       if(unused == [],
         do: [],
         else: [
           "",
           "Owner-listed but no difference here (fixed or stale): " <> Enum.join(unused, ", ")
         ]
       ) ++
       if(folded == %{},
         do: [],
         else: [
           "",
           "Owner-listed but folded into another difference (list that one): " <>
             (folded
              |> Enum.sort()
              |> Enum.map_join(", ", fn {id, roots} -> "#{id} in #{Enum.join(roots, "/")}" end))
         ]
       ))
    |> Enum.join("\n")
  end

  defp line(d, text?) do
    el = d.element || %{}
    shown = if d.kind == :only_ours, do: d.ours, else: d.bubble

    texts =
      case text? && d.kind do
        false -> ""
        :text_differs -> " bubble=#{inspect(d.bubble.text)} ours=#{inspect(d.ours.text)}"
        _ -> if shown.text != "", do: " text=#{inspect(truncate(shown.text, 80))}", else: ""
      end

    "- #{d.kind} #{d.id} #{el[:type]} #{inspect(el[:name])} [#{category_label(d)}] chars=#{d.chars} area=#{d.area}" <>
      if(d.nested > 0, do: " nested=#{d.nested}", else: "") <>
      texts <>
      Enum.map_join(d.reasons, "", &"\n    #{&1}")
  end

  defp category_label(%{known_class: class} = d) when is_binary(class),
    do: "#{d.category}/#{class}"

  defp category_label(d), do: to_string(d.category)

  defp norm(text) when is_binary(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp norm(_), do: ""

  defp truncate(nil, _), do: nil

  defp truncate(text, n) do
    if String.length(text) > n, do: String.slice(text, 0, n) <> "…", else: text
  end

  defp map(m) when is_map(m), do: m
  defp map(_), do: %{}
end
