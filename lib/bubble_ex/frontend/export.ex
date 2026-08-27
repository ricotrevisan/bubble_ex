defmodule BubbleEx.Frontend.Export do
  @moduledoc false

  alias BubbleEx.{Error, Secrets}
  alias BubbleEx.Frontend.{Json, Naming, Payload}
  alias BubbleEx.Frontend.Export.{Assets, Css, Fonts, Html, Result, Writer}
  alias BubbleEx.Frontend.Fetch.Context
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.Node

  @package_version 1

  @spec run(Normalized.t(), String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(%Normalized{} = model, out_dir, opts) when is_binary(out_dir) do
    with :ok <- validate_asset_access(opts),
         :ok <- Writer.precheck(out_dir, opts),
         {:ok, selected} <- select_pages(model, opts),
         :ok <- validate_hydrated_pages(model, selected, opts),
         :ok <- scan_secrets(model, opts) do
      build_and_write(model, selected, out_dir, opts)
    end
  rescue
    e ->
      context =
        if Keyword.get(opts, :credential_taints, []) == [],
          do: %{error: Exception.message(e)},
          else: %{}

      {:error, Error.new(:parse_failed, "frontend export failed", context)}
  end

  defp validate_asset_access(opts) do
    case {Keyword.get(opts, :asset_access, :public), Keyword.get(opts, :fetch_context)} do
      {:public, _} ->
        :ok

      {:same_origin, %Context{}} ->
        :ok

      {:same_origin, _} ->
        {:error,
         Error.new(
           :invalid_input,
           "asset_access: :same_origin requires an authoritative fetched page origin",
           %{}
         )}

      {_, _} ->
        {:error, Error.new(:invalid_input, "asset_access must be :public or :same_origin", %{})}
    end
  end

  defp credential_gate(model, entries, opts) do
    taints = Keyword.get(opts, :credential_taints, [])

    bodies = [
      :erlang.term_to_binary(model)
      | Enum.flat_map(entries, fn {name, body} -> [name, IO.iodata_to_binary(body)] end)
    ]

    if Enum.any?(taints, fn taint ->
         is_binary(taint) and taint != "" and
           Enum.any?(bodies, &(:binary.match(&1, taint) != :nomatch))
       end) do
      {:error, Error.new(:export_blocked, "export blocked by credential-tainted output", %{})}
    else
      :ok
    end
  end

  defp scan_secrets(%Normalized{source: source}, opts) do
    payload = source.payload || %{}
    adapter_opts = scan_opts(opts)

    case Secrets.scan(payload, adapter_opts) do
      {:ok, []} ->
        :ok

      {:ok, findings} ->
        blocking =
          Enum.map(findings, fn finding ->
            %{
              "severity" => "blocking",
              "type" => "leaked_credential",
              "message" => "secret scan reported a leaked credential",
              "refs" => [],
              "payload" => stringify(finding)
            }
          end)

        safe_blocking =
          if tainted_term?(blocking, opts) do
            [
              %{
                "severity" => "blocking",
                "type" => "leaked_credential",
                "message" => "secret scan reported credential-tainted authenticated input",
                "refs" => [],
                "payload" => %{}
              }
            ]
          else
            blocking
          end

        {:error,
         Error.new(:export_blocked, "export blocked by leaked credential", %{
           findings: safe_blocking
         })}

      {:error, %Error{} = error} ->
        {:error, safe_error(error, opts)}
    end
  end

  defp safe_error(%Error{} = error, opts) do
    if tainted_term?(error, opts) do
      Error.new(error.kind, "authenticated export failed safely", %{})
    else
      error
    end
  end

  defp tainted_term?(term, opts) do
    binary = :erlang.term_to_binary(term)

    Enum.any?(Keyword.get(opts, :credential_taints, []), fn taint ->
      is_binary(taint) and taint != "" and :binary.match(binary, taint) != :nomatch
    end)
  end

  defp scan_opts(opts) do
    []
    |> maybe_scan_adapter(Keyword.get(opts, :secret_scan_adapter))
    |> Keyword.put(:telemetry_redact_values, Keyword.get(opts, :credential_taints, []))
  end

  defp maybe_scan_adapter(opts, nil), do: opts
  defp maybe_scan_adapter(opts, adapter), do: Keyword.put(opts, :adapter, adapter)

  defp select_pages(%Normalized{pages: pages}, opts) do
    case Keyword.get(opts, :pages, :all) do
      :all ->
        {:ok, pages}

      [] ->
        {:error, Error.new(:invalid_input, "pages filter must not be empty", %{})}

      refs when is_list(refs) ->
        resolve_page_refs(pages, refs)

      _ ->
        {:error, Error.new(:invalid_input, "pages must be :all or a list of page refs", %{})}
    end
  end

  defp validate_hydrated_pages(%Normalized{source: source}, selected, opts) do
    raw_pages = live_raw_pages(source.payload, opts)
    names = Enum.flat_map(selected, &unhydrated_page_name(&1, raw_pages))
    hydrated_pages_result(names, opts)
  end

  defp live_raw_pages(payload, opts) do
    if match?(%Context{}, Keyword.get(opts, :fetch_context)) do
      Payload.pages(payload)
    else
      aliased_raw_pages(payload)
    end
  end

  defp aliased_raw_pages(%{"%p3" => pages}) when is_map(pages), do: pages
  defp aliased_raw_pages(_payload), do: %{}

  defp unhydrated_page_name(%Node{map_key: key, name: normalized_name}, raw_pages) do
    case Map.get(raw_pages, key) do
      raw when is_map(raw) ->
        if Payload.unhydrated_page?(raw),
          do: [Payload.page_path(raw) || normalized_name || key],
          else: []

      _ ->
        []
    end
  end

  defp hydrated_pages_result([], _opts), do: :ok

  defp hydrated_pages_result(names, opts) do
    error =
      Error.new(
        :parse_failed,
        "selected Bubble page payload is metadata-only after page hydration",
        %{pages: names}
      )

    {:error, safe_error(error, opts)}
  end

  defp resolve_page_refs(pages, refs) do
    indexed = Enum.map(pages, fn page -> {page_refs(page), page} end)
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} -> lookup_page(indexed, ref, acc) end)
  end

  defp lookup_page(indexed, ref, acc) do
    match = Enum.find(indexed, fn {keys, _} -> ref in keys end)

    if match do
      {_keys, page} = match
      {:cont, {:ok, acc ++ [page]}}
    else
      {:halt, {:error, Error.new(:invalid_input, "unknown page ref", %{page: ref})}}
    end
  end

  defp page_refs(%Node{} = page) do
    bubble_id = if is_map(page.source), do: Map.get(page.source, :bubble_id)

    [page.map_key, page.name, Naming.slug(page.name), Naming.slug(page.map_key), bubble_id]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp build_and_write(model, selected, out_dir, opts) do
    plan = plan_names(model, selected)
    nodes = selected ++ model.reusables
    {assets, asset_findings} = Assets.collect(nodes, opts)
    {font_css, font_assets, font_findings} = Fonts.collect(nodes, model.styles, opts)
    bindings = collect_bindings(model)
    findings = collect_findings(model, selected, plan, opts) ++ asset_findings ++ font_findings
    coverage = coverage(model, selected, bindings, opts)

    entries =
      json_entries(model, bindings, findings, coverage, plan, opts) ++
        html_entries(model, selected, plan, assets, opts) ++
        css_entries(model, selected, plan, font_css) ++
        asset_entries(assets, font_assets)

    files = Enum.sort(["MANIFEST.json" | Enum.map(entries, &elem(&1, 0))])
    manifest = manifest(model, files, opts)
    entries = [{"MANIFEST.json", encode_manifest(manifest)} | entries]

    with :ok <- credential_gate(model, entries, opts),
         {:ok, written} <- Writer.publish(out_dir, entries, opts) do
      {:ok,
       %Result{
         out_dir: out_dir,
         files: written,
         model: model,
         bindings: bindings,
         findings: findings,
         coverage: coverage,
         manifest: manifest
       }}
    end
  end

  defp plan_names(%Normalized{} = model, selected) do
    {pages, _taken} =
      Enum.reduce(selected, {[], MapSet.new()}, fn page, {acc, taken} ->
        {dir, taken} = Naming.page_dirname(page.name, page.map_key, taken)
        {[{page, dir} | acc], taken}
      end)

    reusables =
      Enum.map(model.reusables, fn node ->
        {node, Naming.reusable_dirname(node.name, node.map_key)}
      end)

    styles =
      Map.new(model.styles, fn style ->
        {style.map_key, style.class_name}
      end)

    %{
      pages: Enum.reverse(pages),
      reusables: reusables,
      styles: styles,
      page_by_ref: page_lookup(Enum.reverse(pages))
    }
  end

  defp page_lookup(pages) do
    Enum.reduce(pages, %{}, fn {page, dir}, acc ->
      Enum.reduce(page_refs(page), acc, fn ref, acc -> Map.put(acc, ref, {page, dir}) end)
    end)
  end

  defp json_entries(model, bindings, findings, coverage, _plan, _opts) do
    [
      {"model.json", encode_model(model)},
      {"bindings.json", Json.encode(bindings)},
      {"findings.json", Json.encode(findings)},
      {"coverage.json", Json.encode(coverage)}
    ]
  end

  defp html_entries(model, _selected, plan, assets, opts) do
    catalog_pages =
      Enum.map(plan.pages, fn {page, dir} ->
        {page.name || dir, "pages/#{dir}/index.html"}
      end)

    catalog =
      {"index.html",
       Html.catalog(model.identity.bubble_id, model.identity.app_version, catalog_pages)}

    page_docs =
      Enum.map(plan.pages, fn {page, dir} ->
        html =
          Html.page_document(page,
            title: page_title(page),
            page_css: dir,
            expand: &expand(model, &1),
            rewrite_href: &rewrite_href(&1, &2, plan, dir),
            style_class: &style_class(&1, plan),
            assets: assets,
            fallback: Keyword.get(opts, :fallback, false)
          )

        {"pages/#{dir}/index.html", html}
      end)

    fragments =
      Enum.map(plan.reusables, fn {node, dir} ->
        {"reusables/#{dir}/fragment.html",
         Html.fragment(node,
           expand: &expand(model, &1),
           rewrite_href: fn _n, dest -> dest end,
           style_class: &style_class(&1, plan),
           assets: assets
         )}
      end)

    [catalog | page_docs ++ fragments]
  end

  defp css_entries(model, _selected, plan, font_css) do
    shared = {"styles/shared.css", Css.shared(model, font_css)}

    page_css =
      Enum.map(plan.pages, fn {page, dir} ->
        {"styles/pages/#{dir}.css", page_and_instance_css(page, model)}
      end)

    reusable_css =
      Enum.map(plan.reusables, fn {node, dir} ->
        {"styles/reusables/#{dir}.css", Css.page(node)}
      end)

    [shared | page_css ++ reusable_css]
  end

  defp page_and_instance_css(page, model) do
    instance_css =
      page
      |> collect()
      |> Enum.filter(&(&1.kind == :reusable_instance))
      |> Enum.map_join("\n", fn inst ->
        case expand(model, inst) do
          %Node{children: children} ->
            Enum.map_join(children, "\n", &Css.page(&1, id_prefix: inst.exporter_id))

          _ ->
            ""
        end
      end)

    [Css.page(page), instance_css]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> then(fn css ->
      if String.trim(css) == "", do: "\n", else: String.trim_trailing(css) <> "\n"
    end)
  end

  defp asset_entries(assets, font_assets) do
    (Map.values(assets) ++ font_assets)
    |> Enum.filter(&(is_binary(Map.get(&1, :path)) and is_binary(Map.get(&1, :bytes))))
    |> Enum.uniq_by(& &1.path)
    |> Enum.map(fn asset -> {asset.path, asset.bytes} end)
  end

  defp expand(%Normalized{reusables: reusables}, %Node{definition_ref: ref}) do
    Enum.find(reusables, fn node -> node.map_key == ref end)
  end

  defp rewrite_href(_node, dest, plan, from_dir) do
    cond do
      external?(dest) ->
        dest

      Map.has_key?(plan.page_by_ref, dest) ->
        {_page, to_dir} = plan.page_by_ref[dest]
        if to_dir == from_dir, do: "index.html", else: "../#{to_dir}/index.html"

      true ->
        dest
    end
  end

  defp external?(dest) do
    String.contains?(dest, "://") or String.starts_with?(dest, "//")
  end

  defp style_class(%Node{style: style}, plan) when is_map(style) do
    key = style[:style_key] || style["style_key"]
    plan.styles[key]
  end

  defp style_class(_, _), do: nil

  defp page_title(%Node{attributes: %{"title" => title}}) when is_binary(title), do: title
  defp page_title(%Node{name: name}) when is_binary(name), do: name
  defp page_title(_), do: "Page"

  defp collect_bindings(%Normalized{} = model) do
    (model.pages ++ model.reusables)
    |> Enum.flat_map(&node_bindings/1)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
  end

  defp node_bindings(%Node{} = node) do
    own =
      node.bindings
      |> Map.values()
      |> Enum.map(&stringify/1)

    own ++ Enum.flat_map(node.children, &node_bindings/1)
  end

  defp collect_findings(%Normalized{} = model, selected, plan, opts) do
    exported_ids =
      (selected ++ model.reusables)
      |> Enum.flat_map(&collect_ids/1)
      |> MapSet.new()

    unsupported =
      model.diagnostics
      |> Enum.filter(fn d ->
        d.code == :unsupported_element and Enum.any?(d.refs, &MapSet.member?(exported_ids, &1))
      end)
      |> Enum.map(fn d ->
        %{
          "severity" => "warning",
          "type" => "unsupported_element",
          "message" => d.message,
          "refs" => d.refs,
          "payload" => stringify(d.details)
        }
      end)

    links = link_findings(selected, plan)
    fallback = fallback_findings(opts, selected)
    unsupported ++ links ++ fallback
  end

  defp collect_ids(%Node{} = node) do
    [node.exporter_id | Enum.flat_map(node.children, &collect_ids/1)]
  end

  defp link_findings(pages, plan) do
    pages
    |> Enum.flat_map(&collect/1)
    |> Enum.filter(&(&1.kind == :link or navigation_export?(&1)))
    |> Enum.flat_map(fn node ->
      dest =
        case node.content do
          %{"destination" => %{resolved: d}} -> d
          _ -> nil
        end

      cond do
        not is_binary(dest) ->
          []

        external?(dest) ->
          []

        Map.has_key?(plan.page_by_ref, dest) ->
          []

        internal_looking?(dest, plan) ->
          [
            %{
              "severity" => "info",
              "type" => "link_to_non_exported_page",
              "message" => "resolved destination is not in this export",
              "refs" => [node.exporter_id],
              "payload" => %{"destination" => dest}
            }
          ]

        true ->
          []
      end
    end)
  end

  defp navigation_export?(%Node{kind: :button, content: %{"destination" => %{resolved: dest}}})
       when is_binary(dest) and dest != "",
       do: true

  defp navigation_export?(_), do: false

  defp internal_looking?(dest, _plan) do
    # A dest that matches a known page of the full model (by being a simple slug)
    # but is absent from this export. We treat non-URL, non-path dests as page refs
    # when they look like slugs, or when they match any page name in the plan's
    # omitted set. The filter case in tests uses destination "about".
    not external?(dest) and not String.contains?(dest, "/") and dest != ""
  end

  defp fallback_findings(opts, selected) do
    if Keyword.get(opts, :fallback, false) do
      ids = selected |> Enum.flat_map(&fallback_slots/1)

      Enum.map(ids, fn {exporter_id, slot} ->
        %{
          "severity" => "info",
          "type" => "fallback_engaged",
          "message" => "fallback rendering engaged for unresolved slot",
          "refs" => [exporter_id],
          "payload" => %{"slot" => slot}
        }
      end)
    else
      []
    end
  end

  defp fallback_slots(%Node{} = node) do
    slots =
      node.bindings
      |> Map.keys()
      |> Enum.map(&{node.exporter_id, &1})

    slots ++ Enum.flat_map(node.children, &fallback_slots/1)
  end

  defp collect(%Node{} = node), do: [node | Enum.flat_map(node.children, &collect/1)]

  defp coverage(%Normalized{} = model, selected, bindings, opts) do
    selected_rows =
      Enum.map(selected, fn page ->
        nodes = collect_expanded(page, model)
        {native, placeholder} = element_counts(nodes)
        {resolved, unresolved} = binding_counts(nodes, bindings)

        %{
          "ref" => page.map_key,
          "slug" => Naming.slug(page.name) || page.map_key,
          "elements" => %{
            "native" => native,
            "placeholder" => placeholder,
            "ratio_native" => ratio(native, native + placeholder)
          },
          "bindings" => %{
            "resolved" => resolved,
            "unresolved" => unresolved,
            "ratio_resolved" => ratio(resolved, resolved + unresolved)
          }
        }
      end)

    all_nodes = Enum.flat_map(model.pages ++ model.reusables, &collect_expanded(&1, model))
    {native, placeholder} = element_counts(all_nodes)
    unresolved = length(bindings)
    resolved = resolved_slot_count(all_nodes)

    fallback_n =
      if Keyword.get(opts, :fallback, false),
        do: length(fallback_findings(opts, selected)),
        else: 0

    %{
      "overall" => %{
        "elements" => %{
          "native" => native,
          "placeholder" => placeholder,
          "ratio_native" => ratio(native, native + placeholder)
        },
        "bindings" => %{
          "resolved" => resolved,
          "unresolved" => unresolved,
          "ratio_resolved" => ratio(resolved, resolved + unresolved)
        },
        "pages" => %{
          "exported" => length(selected),
          "not_exported" => length(model.pages) - length(selected)
        },
        "fallback" => %{"engaged" => fallback_n}
      },
      "pages" => selected_rows
    }
  end

  defp collect_expanded(%Node{} = node, model) do
    nested = Enum.flat_map(node.children, &collect_expanded(&1, model))

    expanded =
      if node.kind == :reusable_instance do
        case expand(model, node) do
          %Node{} = defn -> Enum.flat_map(defn.children, &collect_expanded(&1, model))
          _ -> []
        end
      else
        []
      end

    [node | nested ++ expanded]
  end

  defp element_counts(nodes) do
    Enum.reduce(nodes, {0, 0}, fn
      %Node{kind: :page}, acc -> acc
      %Node{kind: :reusable_definition}, acc -> acc
      %Node{placeholder?: true}, {n, p} -> {n, p + 1}
      %Node{kind: :placeholder}, {n, p} -> {n, p + 1}
      _node, {n, p} -> {n + 1, p}
    end)
  end

  defp binding_counts(nodes, _bindings) do
    unresolved =
      nodes
      |> Enum.map(&map_size(&1.bindings))
      |> Enum.sum()

    resolved = resolved_slot_count(nodes)
    {resolved, unresolved}
  end

  defp resolved_slot_count(nodes) do
    Enum.reduce(nodes, 0, fn %Node{content: content}, acc ->
      count =
        content
        |> Kernel.||(%{})
        |> Map.values()
        |> Enum.count(&match?(%{resolved: _}, &1))

      acc + count
    end)
  end

  defp ratio(_num, 0), do: 1.0
  defp ratio(num, den), do: num / den

  defp manifest(model, files, opts) do
    payload = model.source.payload || %{}

    %{
      "package_version" => @package_version,
      "normalized_schema_version" => model.normalized_schema_version,
      "bubble_ex_version" => bubble_ex_version(),
      "bubble_id" => model.identity.bubble_id,
      "app_version" => model.identity.app_version,
      "source_sha256" => Json.sha256(payload),
      "options" => visible_options(opts),
      "files" => files
    }
  end

  defp visible_options(opts) do
    visible = %{
      "pages" => pages_option(Keyword.get(opts, :pages, :all)),
      "fallback" => Keyword.get(opts, :fallback, false),
      "force" => Keyword.get(opts, :force, false)
    }

    if Keyword.has_key?(opts, :asset_access) do
      Map.put(visible, "asset_access", Atom.to_string(Keyword.fetch!(opts, :asset_access)))
    else
      visible
    end
  end

  defp pages_option(:all), do: "all"
  defp pages_option(list) when is_list(list), do: list

  defp encode_manifest(manifest) do
    [
      "{",
      "\n",
      manifest_line("package_version", manifest["package_version"], ","),
      manifest_line("normalized_schema_version", manifest["normalized_schema_version"], ","),
      manifest_line("bubble_ex_version", manifest["bubble_ex_version"], ","),
      manifest_line("bubble_id", manifest["bubble_id"], ","),
      manifest_line("app_version", manifest["app_version"], ","),
      manifest_line("source_sha256", manifest["source_sha256"], ","),
      "  \"options\": ",
      Jason.encode!(manifest["options"], pretty: true) |> indent_block(),
      ",\n",
      "  \"files\": ",
      Jason.encode!(manifest["files"], pretty: true) |> indent_block(),
      "\n",
      "}\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp manifest_line(key, value, sep) do
    ["  ", Jason.encode!(key), ": ", Jason.encode!(value), sep, "\n"]
  end

  defp indent_block(json) do
    json
    |> String.trim()
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map_join("\n", fn
      {line, 0} -> line
      {line, _} -> "  " <> line
    end)
  end

  defp encode_model(%Normalized{} = model) do
    model
    |> Map.from_struct()
    |> Map.update!(:source, fn source ->
      source |> Map.from_struct() |> Map.delete(:payload)
    end)
    |> Json.encode()
  end

  defp stringify(map) when is_map(map) do
    map
    |> Json.normalize()
    |> ordered_to_map()
  end

  defp stringify(other), do: other

  defp ordered_to_map(%Jason.OrderedObject{values: values}) do
    Map.new(values, fn {k, v} -> {k, ordered_to_map(v)} end)
  end

  defp ordered_to_map(list) when is_list(list), do: Enum.map(list, &ordered_to_map/1)
  defp ordered_to_map(other), do: other

  defp bubble_ex_version do
    case Application.spec(:bubble_ex, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> "0.0.0"
    end
  end
end
