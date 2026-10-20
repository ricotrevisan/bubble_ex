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
    * `:known` - listed by the owner in `:known` (e.g. stricter privacy)
    * `:marked` - ours marks the element or an ancestor as not migrated
    * `:unexplained` - none of the above: a candidate bug

  The first three are grouped as known differences. Nothing here reads
  Bubble or the network; the captures are files the caller made.
  """

  alias BubbleEx.Expression

  @kinds [:only_bubble, :only_ours, :count_differs, :text_differs, :box_off]
  @fold_kinds [:only_bubble, :only_ours]
  @known_categories [:export_drift, :known, :marked]

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
  Compares a Bubble capture with ours for the same page and width.

  Options:

    * `:box_tolerance` - pixels (default 32)
    * `:generated_from` - the index (`index/2`) of the export the app was
      generated from, when it differs from the one Bubble served
    * `:known` - `%{id => reason}` the owner accepts as intended
    * `:notes` - `%{id => [note]}` from the generated code
      (`project_notes/1`)
  """
  @spec diff(capture(), capture(), %{String.t() => element_info()}, keyword()) :: map()
  def diff(bubble, ours, index, opts \\ []) when is_map(bubble) and is_map(ours) do
    tolerance = Keyword.get(opts, :box_tolerance, 32)
    b = bubble |> normalize_ids(index) |> aggregate()
    o = ours |> normalize_ids(index) |> aggregate()

    raw =
      (Map.keys(b.by_id) ++ Map.keys(o.by_id))
      |> Enum.uniq()
      |> Enum.flat_map(&compare(&1, b, o, tolerance))

    flagged = Map.new(raw, &{{&1.id, &1.kind}, &1})

    {roots, nested} =
      Enum.split_with(raw, fn d ->
        d.kind not in @fold_kinds or folded_into(d, flagged, b, o) == nil
      end)

    roots =
      Enum.reduce(nested, Map.new(roots, &{{&1.id, &1.kind}, &1}), fn d, acc ->
        key = {folded_into(d, flagged, b, o), d.kind}

        Map.update!(acc, key, fn root ->
          %{root | nested: root.nested + 1, chars: root.chars + d.chars}
        end)
      end)
      |> Map.values()
      |> Enum.map(&explain(&1, b, o, index, opts))
      |> Enum.sort_by(&{-&1.chars, -&1.area, &1.id})

    {known, unexplained} = Enum.split_with(roots, &(&1.category in @known_categories))

    %{
      path: bubble["path"],
      width: bubble["width"],
      ours_path: ours["path"],
      ours_width: ours["width"],
      matched: %{
        bubble_elements: length(bubble["elements"] || []),
        bubble_with_id: b.with_id,
        ours_elements: length(ours["elements"] || []),
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
      unexplained: unexplained
    }
  end

  # Bubble names some generated children `<element id>_<suffix>` (e.g. a
  # group per option: `bUsfV0_group_item_<option>_0`); they count as their
  # element when the export has it.
  defp normalize_ids(capture, index) do
    elements =
      Enum.map(capture["elements"] || [], fn e ->
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
    bt = texts(bv)
    ot = texts(ov)

    count =
      if length(bv) != length(ov),
        do: [
          Map.merge(base, %{
            kind: :count_differs,
            chars: abs(chars(bv) - chars(ov)),
            area: abs(area(bv) - area(ov))
          })
        ],
        else: []

    text =
      if bt != ot,
        do: [Map.merge(base, %{kind: :text_differs, chars: max(chars(bv), chars(ov)), area: 0})],
        else: []

    box =
      case {relative_box(hd(bv), b), relative_box(hd(ov), o)} do
        {[bx, by, bw, bh], [ox, oy, ow, oh]} ->
          off = Enum.max([abs(bx - ox), abs(by - oy), abs(bw - ow), abs(bh - oh)])

          if off > tolerance,
            do: [
              Map.merge(base, %{kind: :box_off, chars: 0, area: abs(bw * bh - ow * oh), off: off})
            ],
            else: []

        _ ->
          []
      end

    count ++ text ++ box
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
        [_, _, w, h] when is_number(w) and is_number(h) -> w * h
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp relative_box(%{"box" => [x, y, w, h]} = element, side) do
    case side.by_index[element["parent"]] do
      %{"box" => [px, py, _, _]} -> [x - px, y - py, w, h]
      _ -> [x, y, w, h]
    end
  end

  defp relative_box(_element, _side), do: nil

  # The nearest ancestor (on the side that shows the element) flagged with
  # the same kind.
  defp folded_into(d, flagged, b, o) do
    side = if d.kind == :only_bubble, do: b, else: o
    instance = side.by_id |> Map.get(d.id, []) |> Enum.find(& &1["visible"])
    target = instance && ancestor_flagged(instance["parent"], d.kind, flagged, side)
    if target == d.id, do: nil, else: target
  end

  defp ancestor_flagged(nil, _kind, _flagged, _side), do: nil

  defp ancestor_flagged(index, kind, flagged, side) do
    case side.by_index[index] do
      nil ->
        nil

      parent ->
        id = parent["id"]

        if is_binary(id) and Map.has_key?(flagged, {id, kind}),
          do: ancestor_flagged(parent["parent"], kind, flagged, side) || id,
          else: ancestor_flagged(parent["parent"], kind, flagged, side)
    end
  end

  defp explain(d, b, o, index, opts) do
    info = Map.get(index, d.id)
    known = Keyword.get(opts, :known, %{})
    # An ancestor's marker can explain why an element is not shown, not
    # why its own text or box differs.
    chain =
      if d.kind in [:only_bubble, :only_ours, :count_differs], do: ancestors(d.id, b, o), else: []

    ours = ours_reasons(d.id, chain, o, Keyword.get(opts, :notes, %{}))
    category = category(d.id, Keyword.get(opts, :generated_from), known, ours)

    reasons =
      [
        if(info == nil, do: "not in the export"),
        if(category == :export_drift, do: "not in the export the app was generated from"),
        if(category == :known, do: "owner: #{known[d.id]}"),
        export_reasons(info, d.kind),
        visibility_reason(d),
        ours
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    d
    |> Map.merge(%{reasons: reasons, category: category})
    |> Map.put(:element, info && Map.take(info, [:type, :name, :owner]))
  end

  defp category(id, generated, known, ours) do
    cond do
      is_map(generated) and not Map.has_key?(generated, id) -> :export_drift
      Map.has_key?(known, id) -> :known
      ours != [] -> :marked
      true -> :unexplained
    end
  end

  # Ours: the element's (or nearest ancestor's) dev marker, and the
  # generated code's notes for the nearest element that has some.
  defp ours_reasons(id, chain, o, notes) do
    marker = marker_reason(id, chain, o)

    note =
      case Enum.find_value([id | chain], &(notes[&1] && {&1, notes[&1]})) do
        {nid, list} -> Enum.map(list, &"ours (#{nid}): #{&1}")
        nil -> []
      end

    if(marker, do: [marker], else: []) ++ note
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

  # The element's own marker in ours, else its nearest marked ancestor's.
  defp marker_reason(id, chain, o) do
    Enum.find_value([id | chain], fn aid ->
      text = o.by_id |> Map.get(aid, []) |> Enum.find_value(&marker_note(&1["marker"]))
      text && "#{marker_prefix(aid, id)}: #{text}"
    end)
  end

  defp marker_prefix(id, id), do: "ours"
  defp marker_prefix(aid, _id), do: "ours (ancestor #{aid})"

  defp marker_note(%{"title" => t}) when is_binary(t) and t != "", do: t
  defp marker_note(%{"placeholder" => p}) when is_binary(p), do: "placeholder (#{p})"
  defp marker_note(_), do: nil

  # Ancestor IDs from either side's capture, nearest first.
  defp ancestors(id, b, o) do
    from = fn side ->
      case Map.get(side.by_id, id) do
        [first | _] -> up(first["parent"], side, [])
        _ -> []
      end
    end

    (from.(b) ++ from.(o)) |> Enum.uniq()
  end

  defp up(nil, _side, acc), do: Enum.reverse(acc)

  defp up(index, side, acc) do
    case side.by_index[index] do
      nil -> Enum.reverse(acc)
      %{"id" => id, "parent" => p} when is_binary(id) -> up(p, side, [id | acc])
      %{"parent" => p} -> up(p, side, acc)
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
            Regex.scan(~r/TODO\(bubble:([A-Za-z0-9]+)\)\s*([^\n]*?)\s*(?:--%>|$)/m, source),
          do: {id, String.trim(note)}

    markers =
      for [_, id, note] <-
            Regex.scan(
              ~r/data-bubble-id="([A-Za-z0-9]+)"[^>]*?Bubble\.dev_marker\(\s*"((?:[^"\\]|\\.)*)"/s,
              source
            ),
          do: {id, note}

    todos ++ markers
  end

  @doc "A plain-text summary of a `diff/4` report, the top `n` of each group."
  @spec summary(map(), pos_integer()) :: String.t()
  def summary(report, n \\ 20) do
    m = report.matched

    header = [
      "#{report.path} at #{report.width}px (ours: #{report.ours_path} at #{report.ours_width}px)",
      "matched: bubble #{m.bubble_with_id}/#{m.bubble_elements} elements with an ID, ours #{m.ours_with_id}/#{m.ours_elements}; " <>
        "IDs on both sides #{m.ids_both}, only Bubble #{m.ids_only_bubble}, only ours #{m.ids_only_ours}, not in export #{m.not_in_export}",
      "visible characters: bubble #{report.visible_chars.bubble}, ours #{report.visible_chars.ours}",
      "differences: " <> Enum.map_join(@kinds, ", ", &"#{&1} #{report.counts[&1]}")
    ]

    group = fn title, list ->
      ["", "#{title} (#{length(list)})" | list |> Enum.take(n) |> Enum.map(&line/1)]
    end

    (header ++
       group.("Unexplained (candidate bugs)", report.unexplained) ++
       group.("Known (drift, owner-listed, marked)", report.known))
    |> Enum.join("\n")
  end

  defp line(d) do
    el = d.element || %{}
    shown = if d.kind == :only_ours, do: d.ours, else: d.bubble

    texts =
      case d.kind do
        :text_differs -> " bubble=#{inspect(d.bubble.text)} ours=#{inspect(d.ours.text)}"
        _ -> if shown.text != "", do: " text=#{inspect(truncate(shown.text, 80))}", else: ""
      end

    "- #{d.kind} #{d.id} #{el[:type]} #{inspect(el[:name])} [#{d.category}] chars=#{d.chars} area=#{d.area}" <>
      if(d.nested > 0, do: " nested=#{d.nested}", else: "") <>
      texts <>
      Enum.map_join(d.reasons, "", &"\n    #{&1}")
  end

  defp norm(nil), do: ""
  defp norm(text), do: text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp truncate(nil, _), do: nil

  defp truncate(text, n) do
    if String.length(text) > n, do: String.slice(text, 0, n) <> "…", else: text
  end

  defp map(m) when is_map(m), do: m
  defp map(_), do: %{}
end
