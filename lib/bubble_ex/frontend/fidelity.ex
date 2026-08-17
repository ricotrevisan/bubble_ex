defmodule BubbleEx.Frontend.Fidelity do
  @moduledoc """
  Frozen-case visual fidelity gate (#30).

  A frozen case is the only thing BubbleEx calls visually correct. The suite
  contains only frozen cases. PR CI renders a candidate against committed
  references — it never talks to live Bubble.
  """

  alias BubbleEx.Error

  @cases_dir Path.expand("../../../test/support/fidelity/cases", __DIR__)

  @type case_id :: String.t()

  @spec cases() :: [case_id()]
  def cases do
    cases_dir()
    |> File.ls()
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          dir = Path.join(cases_dir(), name)
          File.dir?(dir) and File.exists?(Path.join(dir, "case.json"))
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @spec load_case(case_id()) :: {:ok, map()} | {:error, Error.t()}
  def load_case(id) when is_binary(id) do
    path = Path.join([cases_dir(), id, "case.json"])

    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw) do
      {:ok, atomize_case(json)}
    else
      {:error, :enoent} ->
        {:error, Error.new(:not_found, "unknown frozen case", %{case: id})}

      {:error, %Jason.DecodeError{}} ->
        {:error, Error.new(:parse_failed, "frozen case manifest is not valid JSON", %{case: id})}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_input, "cannot read frozen case", %{reason: reason, case: id})}
    end
  end

  @spec structure(String.t(), map()) :: :ok | {:error, Error.t()}
  def structure(html, snapshot \\ %{}) when is_binary(html) and is_map(snapshot) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        with :ok <- refute_scripts(document),
             :ok <- refute_handlers(document),
             :ok <- require_exporter_ids(document, snapshot) do
          check_declared_semantics(document, snapshot)
        end

      _ ->
        {:error, Error.new(:parse_failed, "candidate HTML could not be parsed", %{})}
    end
  end

  @spec run(case_id(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(id, opts \\ []) when is_binary(id) do
    with {:ok, case_} <- load_case(id),
         {:ok, export} <- export_case(case_, opts),
         :ok <- pin_font(case_, export.out_dir),
         :ok <- check_structure_and_a11y(case_, export),
         {:ok, report} <- compare(case_, export) do
      {:ok, Map.put(report, :out_dir, export.out_dir)}
    end
  end

  defp export_case(case_, opts) do
    payload_path = Path.join([case_dir(case_.id), "source", "payload.json"])
    out_dir = Keyword.get(opts, :out_dir) || default_out_dir(case_.id)

    with {:ok, raw} <- File.read(payload_path),
         {:ok, payload} <- Jason.decode(raw) do
      BubbleEx.Frontend.export_payload(
        payload,
        out_dir,
        force: true,
        secret_scan_adapter: BubbleEx.Frontend.Fidelity.NoSecrets,
        asset_files: local_asset_files(case_)
      )
    else
      {:error, :enoent} ->
        {:error, Error.new(:not_found, "frozen case has no source payload", %{case: case_.id})}

      {:error, %Jason.DecodeError{}} ->
        {:error, Error.new(:parse_failed, "frozen case payload is not valid JSON", %{})}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp local_asset_files(case_) do
    assets = get_in(case_.raw, ["public_assets"]) || []

    Map.new(assets, fn asset ->
      {asset["url"], Path.join(case_dir(case_.id), asset["path"])}
    end)
  end

  defp pin_font(case_, out_dir) do
    src = Path.join(case_dir(case_.id), case_.font.path)
    dest = Path.join(out_dir, "assets/inter-latin.woff2")
    shared = Path.join(out_dir, "styles/shared.css")

    with true <- File.exists?(src),
         :ok <- verify_font_sha(src, case_.font.sha256),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- File.cp(src, dest),
         {:ok, css} <- File.read(shared) do
      File.write(shared, font_face_css() <> css)
    else
      false ->
        {:error, Error.new(:not_found, "frozen case font is missing", %{})}

      {:error, reason} ->
        {:error, Error.new(:invalid_input, "failed pinning font", %{reason: reason})}
    end
  end

  defp verify_font_sha(path, expected) do
    case File.read(path) do
      {:ok, bytes} ->
        actual = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

        if actual == expected do
          :ok
        else
          {:error, Error.new(:invalid_input, "frozen font SHA-256 does not match the pin", %{})}
        end

      {:error, reason} ->
        {:error, Error.new(:not_found, "cannot read frozen font", %{reason: reason})}
    end
  end

  defp font_face_css do
    """
    @font-face {
      font-family: "Inter";
      font-style: normal;
      font-weight: 400 800;
      font-display: block;
      src: url("../assets/inter-latin.woff2") format("woff2");
    }

    :root {
      color-scheme: light;
      font-family: Helvetica, Arial, sans-serif;
    }

    html { scroll-behavior: smooth; }
    body { min-width: 320px; }
    button, a { cursor: pointer; }

    """
  end

  defp check_structure_and_a11y(case_, export) do
    html_path = page_html_path(export.out_dir, case_)

    with {:ok, html} <- File.read(html_path),
         :ok <- structure(html, Map.put(case_.semantics, "nodes", case_.node_ids)) do
      a11y(html)
    else
      {:error, :enoent} ->
        {:error, Error.new(:not_found, "exported page HTML is missing", %{path: html_path})}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp page_html_path(out_dir, case_) do
    slug = case_.source.page_path || case_.id
    Path.join(out_dir, "pages/#{slug}/index.html")
  end

  defp compare(case_, export) do
    runner = Path.expand("../../../test/support/fidelity/run.mjs", __DIR__)
    html = page_html_path(export.out_dir, case_)
    report = Path.join(export.out_dir, "fidelity-report.json")

    args = [
      runner,
      "--case",
      case_dir(case_.id),
      "--html",
      html,
      "--report",
      report
    ]

    {output, status} =
      System.cmd("node", args, stderr_to_stdout: true, cd: Path.dirname(runner))

    if status == 0 do
      decode_report(report, output)
    else
      failed_compare(report, output, status)
    end
  end

  defp failed_compare(report, output, status) do
    case decode_report(report, output) do
      {:ok, %{"error" => "playwright_missing"} = decoded} ->
        {:error,
         Error.new(:cli_missing, "playwright 1.55.0 is not installed", %{report: decoded})}

      {:ok, decoded} ->
        {:error,
         Error.new(:invalid_input, "frozen case failed the fidelity gate", %{
           report: decoded,
           output: output
         })}

      {:error, _} ->
        {:error,
         Error.new(:cli_failed, "fidelity runner failed", %{status: status, output: output})}
    end
  end

  defp decode_report(path, _output) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, json} ->
            {:ok, json}

          {:error, _} ->
            {:error, Error.new(:parse_failed, "fidelity report is not valid JSON", %{})}
        end

      {:error, _} ->
        {:error, Error.new(:not_found, "fidelity report was not written", %{path: path})}
    end
  end

  defp default_out_dir(id) do
    Path.join([System.tmp_dir!(), "bubble_ex_fidelity", id])
  end

  @spec a11y(String.t()) :: :ok | {:error, Error.t()}
  def a11y(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        violations =
          unlabeled_buttons(document) ++
            unlabeled_inputs(document) ++
            unlabeled_links(document) ++
            missing_alts(document)

        if violations == [] do
          :ok
        else
          {:error,
           Error.new(:invalid_input, "emitted controls failed the accessibility gate", %{
             violations: violations
           })}
        end

      {:error, _} ->
        {:error, Error.new(:parse_failed, "candidate HTML could not be parsed", %{})}
    end
  end

  @spec cases_dir() :: String.t()
  def cases_dir, do: @cases_dir

  @spec case_dir(case_id()) :: String.t()
  def case_dir(id), do: Path.join(cases_dir(), id)

  defp atomize_case(json) do
    %{
      id: json["id"],
      browser: %{
        playwright: get_in(json, ["browser", "playwright"]),
        chromium: get_in(json, ["browser", "chromium"]),
        dpr: get_in(json, ["browser", "dpr"]),
        locale: get_in(json, ["browser", "locale"]),
        reduced_motion: get_in(json, ["browser", "reduced_motion"]),
        viewport_height: get_in(json, ["browser", "viewport_height"])
      },
      font: %{
        sha256: get_in(json, ["font", "sha256"]),
        path: get_in(json, ["font", "path"])
      },
      source: %{
        bubble_id: get_in(json, ["source", "bubble_id"]),
        app_version: get_in(json, ["source", "app_version"]),
        page_id: get_in(json, ["source", "page_id"]),
        page_path: get_in(json, ["source", "page_path"]),
        page_payload_sha256: get_in(json, ["source", "page_payload_sha256"])
      },
      viewports: json["viewports"] || [],
      node_ids: json["node_ids"] || [],
      text_node_ids: json["text_node_ids"] || [],
      semantics: json["semantics"] || %{},
      raw: json
    }
  end

  defp refute_scripts(document) do
    if Floki.find(document, "script") == [] do
      :ok
    else
      {:error, Error.new(:invalid_input, "candidate contains script tags", %{})}
    end
  end

  defp refute_handlers(document) do
    handlers =
      document
      |> Floki.find("*")
      |> Enum.flat_map(fn
        {_, attrs, _} ->
          Enum.filter(attrs, fn {name, _} -> String.starts_with?(name, "on") end)

        _ ->
          []
      end)

    if handlers == [] do
      :ok
    else
      {:error, Error.new(:invalid_input, "candidate contains inline event handlers", %{})}
    end
  end

  defp require_exporter_ids(document, snapshot) do
    correlated = correlated_ids(snapshot)

    missing =
      Enum.reject(correlated, fn id ->
        nodes = Floki.find(document, ~s([data-bubble-id="#{id}"]))
        Enum.any?(nodes, &(attr(&1, "data-exporter-id") != nil))
      end)

    if missing == [] do
      :ok
    else
      {:error,
       Error.new(:invalid_input, "correlated nodes are missing data-exporter-id", %{
         missing: missing
       })}
    end
  end

  defp correlated_ids(snapshot) do
    snapshot
    |> Enum.flat_map(fn
      {kind, by_id} when kind in ["link_attributes", "input_attributes"] and is_map(by_id) ->
        Map.keys(by_id)

      {_, ids} when is_list(ids) ->
        ids

      {_, map} when is_map(map) ->
        Enum.flat_map(Map.values(map), &List.wrap/1)

      _ ->
        []
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp check_declared_semantics(_document, snapshot) when snapshot == %{}, do: :ok

  defp check_declared_semantics(document, snapshot) do
    problems =
      Enum.flat_map(snapshot, fn
        {"main", ids} -> expect_tags(document, ids, "main")
        {"headings", levels} -> heading_problems(document, levels)
        {"paragraphs", ids} -> expect_tags(document, ids, "p")
        {"buttons", ids} -> expect_tags(document, ids, "button")
        {"inputs", ids} -> expect_tags(document, ids, "input")
        {"input_attributes", by_id} -> attribute_problems(document, "input", by_id)
        {"images", ids} -> expect_tags(document, ids, "img")
        {"links", ids} -> link_problems(document, ids)
        {"link_attributes", by_id} -> attribute_problems(document, "a", by_id)
        {"decorative", ids} -> expect_aria_hidden(document, ids)
        {"nodes", ids} -> expect_exporter_ids(document, ids)
        _ -> []
      end)

    if problems == [] do
      :ok
    else
      {:error,
       Error.new(:invalid_input, "declared semantic snapshot mismatch", %{problems: problems})}
    end
  end

  defp heading_problems(document, levels) when is_map(levels) do
    Enum.flat_map(levels, fn {tag, ids} -> expect_tags(document, ids, tag) end)
  end

  defp heading_problems(_, _), do: []

  defp expect_tags(document, ids, tag) do
    Enum.flat_map(List.wrap(ids), fn id ->
      case Floki.find(document, ~s([data-bubble-id="#{id}"])) do
        [{^tag, _, _} | _] -> []
        [{other, _, _} | _] -> [%{id: id, expected: tag, actual: other}]
        [] -> [%{id: id, expected: tag, actual: nil}]
      end
    end)
  end

  defp link_problems(document, ids) do
    expect_tags(document, ids, "a") ++
      Enum.flat_map(List.wrap(ids), &link_name_problem(document, &1))
  end

  defp link_name_problem(document, id) do
    case Floki.find(document, ~s([data-bubble-id="#{id}"])) do
      [node | _] -> accessible_link_name_problem(id, node |> Floki.text() |> String.trim())
      [] -> []
    end
  end

  defp accessible_link_name_problem(id, ""),
    do: [%{id: id, expected: "accessible name", actual: nil}]

  defp accessible_link_name_problem(_id, _name), do: []

  defp attribute_problems(document, tag, by_id) when is_map(by_id) do
    Enum.flat_map(by_id, fn {id, expected} ->
      attributes_for(document, tag, id, expected)
    end)
  end

  defp attribute_problems(_document, _tag, _), do: []

  defp attributes_for(document, tag, id, expected) do
    case Floki.find(document, ~s([data-bubble-id="#{id}"])) do
      [{^tag, _, _} = node | _] when is_map(expected) ->
        Enum.flat_map(expected, &attribute_problem(node, id, &1))

      [{other, _, _} | _] ->
        [%{id: id, expected: tag, actual: other}]

      [] ->
        [%{id: id, expected: tag, actual: nil}]
    end
  end

  defp attribute_problem(node, id, {name, expected}) do
    actual = attr(node, name)

    if actual == expected,
      do: [],
      else: [%{id: id, attribute: name, expected: expected, actual: actual}]
  end

  defp expect_exporter_ids(document, ids) do
    Enum.flat_map(List.wrap(ids), &exporter_id_problem(document, &1))
  end

  defp exporter_id_problem(document, id) do
    case Floki.find(document, ~s([data-bubble-id="#{id}"])) do
      [node | _] -> missing_exporter_id(id, attr(node, "data-exporter-id"))
      [] -> [%{id: id, expected: "present", actual: nil}]
    end
  end

  defp missing_exporter_id(_id, value) when is_binary(value), do: []
  defp missing_exporter_id(id, _), do: [%{id: id, expected: "data-exporter-id", actual: nil}]

  defp expect_aria_hidden(document, ids) do
    Enum.flat_map(List.wrap(ids), &aria_hidden_problem(document, &1))
  end

  defp aria_hidden_problem(document, id) do
    case Floki.find(document, ~s([data-bubble-id="#{id}"])) do
      [node | _] ->
        aria_hidden_mismatch(id, attr(node, "aria-hidden"))

      [] ->
        [%{id: id, expected: "aria-hidden", actual: nil}]
    end
  end

  defp aria_hidden_mismatch(_id, "true"), do: []
  defp aria_hidden_mismatch(id, actual), do: [%{id: id, expected: "aria-hidden", actual: actual}]

  defp unlabeled_buttons(document) do
    document
    |> Floki.find("button[data-exporter-id]")
    |> Enum.reject(&named?/1)
    |> Enum.map(&%{role: "button", id: attr(&1, "data-exporter-id")})
  end

  defp unlabeled_inputs(document) do
    document
    |> Floki.find("input[data-exporter-id]")
    |> Enum.reject(&input_named?/1)
    |> Enum.map(&%{role: "input", id: attr(&1, "data-exporter-id")})
  end

  defp unlabeled_links(document) do
    document
    |> Floki.find("a[data-exporter-id]")
    |> Enum.reject(&named?/1)
    |> Enum.map(&%{role: "a", id: attr(&1, "data-exporter-id")})
  end

  defp missing_alts(document) do
    document
    |> Floki.find("img[data-exporter-id][src]")
    |> Enum.reject(&(attr(&1, "alt") != nil))
    |> Enum.map(&%{role: "img", id: attr(&1, "data-exporter-id")})
  end

  defp named?(node) do
    text = node |> Floki.text() |> String.trim()
    text != "" or attr(node, "aria-label") not in [nil, ""]
  end

  defp input_named?(node) do
    attr(node, "aria-label") not in [nil, ""] or attr(node, "placeholder") not in [nil, ""]
  end

  defp attr({_, attrs, _}, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp attr(_, _), do: nil
end
