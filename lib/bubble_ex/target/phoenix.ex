defmodule BubbleEx.Target.Phoenix do
  @moduledoc """
  The Phoenix target (WTF-369): renders a `BubbleEx.Target.Ash.Project` as
  the file map of a complete Phoenix 1.8 + Ash 3 application.

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, files} = BubbleEx.Target.Phoenix.render(project, name: "Acme Import")
      files["mix.exs"]

  Like `BubbleEx.Target.Ash.Source`, it only prints: every Bubble decision is
  already in the Project (a `mix xref` test keeps it off the Model and the
  mapper). It chooses the names, the file layout and the framework around
  the resources. Output is deterministic: the same Project and options
  give the same bytes.

  ## The application

    * `mix.exs` pinning `deps/1`: the Ash pins of
      `BubbleEx.Target.Ash.versions/1`, then Phoenix, LiveView, AshPhoenix,
      AshAuthentication (+ Phoenix), Oban and AshOban, Tailwind v4 and
      esbuild
    * config (`config`, `dev`, `test`, `prod`, `runtime`): production
      reads `DATABASE_URL`, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`,
      `MAILER_ADAPTER` and `MAILER_FROM` from the environment and refuses
      to boot without them; dev and test have fixed development secrets.
      `config :ash, default_string_length_count: :codepoints`
    * the AshPostgres repo (`ash-functions` and `citext`, PostgreSQL 14+), the Ash domain and
      resources, enums and types of the Project, one module per file under
      `lib/<app>/`
    * Oban, configured through `AshOban.config/2`, with its migration
    * AshAuthentication with the **magic link** strategy on the User
      (WTF-355: no password material is read from Bubble): the email
      becomes a trimmed `:ci_string` with a unique identity, so case and
      whitespace never block sign-in (an index hint over the email alone,
      an `email equals` search, is not created: the identity's unique
      index serves it); registration is disabled (only
      stored users sign in); a token resource (`<Module>.Accounts.Token`,
      table `auth_tokens`); the authentication DSL lives in an owned
      `Spark.Dsl.Fragment` (`<Module>.Accounts.UserAuthentication`) the
      User includes, so tuning it is not a hand edit; the sender stub
      enqueues an Oban job (unique per email a minute) holding the link
      encrypted. Owned code reaches the User through the generated
      `<Module>.Accounts.Resources` (`user/0`, `email_field/0`,
      `confirmed_at_field/0`)
    * the User's `confirmed_at` (WTF-413, mapped by `BubbleEx.Target.Ash`:
      AshAuthentication's confirmation shape, filled by the data loader
      with a confirmed Bubble user's Created Date). Signing in with a
      magic link proves the email, so it counts as confirming it, as
      AshAuthentication's confirmation add-on does with
      `auto_confirm_actions [:sign_in_with_magic_link]`: that option only
      acts on the registering (create) sign-in action, and registration
      is disabled here (sign-in is a read), so the owned
      `AuthController.success/4` sets `confirmed_at` on a magic-link
      sign-in when it is nil and keeps a migrated one. The add-on itself
      (a confirmation sender) is not generated; the fragment's
      documentation says how to add it. Apps scaffolded before WTF-413
      have the attribute (generated) but not the owned controller change
    * an endpoint, router (sign-in routes, `/api/1.1/wf/:name`), layouts
      and a home page styled with Tailwind v4 (`@theme` tokens in
      `assets/css/bubble.css`; no daisyUI, WTF-359 Q4)
    * `.gitignore` ignoring `.wtf/plan.key` (the plan content key,
      WTF-367), and a smoke test (`mix test`: the endpoint boots, a stored
      user signs in with a magic link)

  `privacy: :omit` Projects render (the default) and `privacy: :enforced`
  ones (WTF-423); `:unverified` is for inspection only and is refused. With
  `:omit` the resources have **no authorization**: the generated Ash files
  and the README say so, and owners must add policies before exposing any
  resource through an API or LiveView.

  ## Enforced privacy (WTF-423)

  With `:enforced` the resources carry the policies compiled from Bubble's
  privacy rules (`BubbleEx.Target.Ash`, "Enforced") and the app enforces
  them (`docs/page-data.md`, "Enforced privacy"):

    * **reads** follow the rules: page data, frontend and backend
      workflows and the workflow API read with the current user (or the
      bearer token's), read afresh with `<Module>.Privacy.load_actor/1` at
      every page load, event, API call and job; searches use `:search`; a
      hidden field reads as empty
    * **writes** (Rico's option A): the runtime marks its data steps
      (private context `%{bubble_workflow_write: true}`) and `<Module>.Privacy.
      WorkflowWrite` authorizes them, so a workflow's conditions guard its
      writes, as in Bubble; any other write is forbidden. Writes are **not
      checked against the privacy rules**: the README, the Ash files'
      headers and a diagnostic say so
    * the workflow API's **admin token** bypasses privacy (`authorize?:
      false` for the run and the custom events it triggers)
    * **AshAuthentication**'s own interactions bypass the User's policies
      and field policies (a marked `bypass`, as its installer adds)
    * **private files** can follow "view attached files":
      `private: :privacy_rules` (`<Web>.Uploads`)

  The `data_access`, `serve_workflow_api` and private-file switches stay
  off by default, as with `:omit`: turning them on is the owner's call.
  An `:omit` render is byte for byte what it was.

  ## Generated and owned files (WTF-359 Q1)

  **Generated** files derive from the Bubble app: the Ash modules, the
  token resource, `Accounts.Resources`, the workflow API entry point
  (`<Module>Web.WorkflowApiController`), the file serving (`<Web>.Uploads`,
  `<Web>.UploadsController` and its test), the theme tokens
  (`assets/css/bubble.css`) and the name map (`.wtf/names.json`, the
  Project's `names`, to pass back to `BubbleEx.Target.Ash.map/3`). Each
  Elixir and CSS one starts with a "Generated by bubble_ex" header.
  Regeneration overwrites them; `.wtf/generated.json`
  (`BubbleEx.Target.Phoenix.Manifest`) records their SHA-256 and the input
  hashes, and `check_manifest/2` finds hand edits.

  With `api_clients:` (a `BubbleEx.Target.ApiClients.Spec`, WTF-374) the
  API Connector clients are generated too: the `<Module>.ApiClients`
  runtime (Req; secrets from environment variables at call time), one
  `<Module>.ApiClients.<Group>` module per group with one function per
  call, `<Module>.ApiClients.Decode` (responses into the external typed
  structs), a `Req.Test` request-shape test per call under
  `test/<app>/api_clients/`, and `.wtf/api_clients.json` (environment
  variables, residue, names); the manifest's inputs record the Spec's
  hash (see `BubbleEx.Target.Phoenix.ApiClients`).

  **Owned** files are everything else (mix.exs, config, router, layouts,
  controllers, the sender, tests…): scaffolded once, then the owner's; a
  packager writes them only when absent. `owned_paths/1` and the
  manifest's `owned` list them. Pages are owned too (below); per-surface
  `Workflows` modules will be.

  ## Migrated files (WTF-415)

  The files the data loader copied (`BubbleEx.Load.Storage.Local`) are
  served by the generated `<Web>.UploadsController` at
  `/uploads/<sha256>/<name>`, by the rules of the generated `<Web>.Uploads`:
  a stored file may be another Bubble app's hostile `.html` or `.svg`, so
  it is an attachment of an inert type (`application/octet-stream`, or
  `application/pdf`) unless its bytes are a PNG, JPEG, GIF or WebP image
  (inline), always with `nosniff` and `Content-Security-Policy: sandbox;
  default-src 'none'`; content addresses only (no traversal, no
  symlinks); single byte ranges. `uploads_host` (a separate origin,
  `https://` and a host, validated at boot and failing closed) is the
  preferred production setup; on it the generated
  `<Web>.UploadsHostGuard` (first in the new endpoint) serves public
  files only. Private files
  (`/uploads/private/<sha256>/<name>`) are **off** by default: with
  `privacy: :omit` nothing says who may read them, so the owner opts in
  with an authorization function (or `:signed_in`, weaker than Bubble).
  The routes are in the generated `<Web>.BubbleRoutes` (so existing apps
  get them on regeneration); pages link file and image fields through
  `<Web>.Uploads.url/1`, never to the stored URL; the generated
  `<Web>.UploadsTest` checks hostile files, traversal and the private
  default.

  ## Static assets (WTF-447)

  The images and icons set in the Bubble editor are the app's own after
  migration: pages never point at Bubble's storage. Downloading them is a
  separate, explicit step (`mix bubble.fetch_assets`,
  `BubbleEx.Frontend.StaticAssets.fetch/3`: Bubble's storage hosts only,
  bytes checked, SVG sanitized, content-addressed); rendering stays
  offline and deterministic and takes the result as `asset_store:`. A
  stored image is served from `priv/bubble_images/<sha256>.<ext>`
  (generated), a stored icon library's symbol is inlined; an image on
  Bubble's storage that was not downloaded renders without a source and is
  marked in the template. An image on another host stays linked to its
  original URL, as in Bubble (WTF-465): never fetched or proxied, linked
  over HTTPS with `loading="lazy"` and `referrerpolicy="no-referrer"`, and
  not marked. `.wtf/assets.json` (generated) lists every asset with its
  status, SHA-256, content type and size. New endpoints serve
  `/images/bubble` from `priv/bubble_images` with
  `X-Content-Type-Options: nosniff` and a sandbox
  `Content-Security-Policy`, outside `priv/static` so no other plug can
  serve them (WTF-455); older ones can add the same `Plug.Static`, or
  point theirs at `priv/bubble_images`. Until they do, `check_manifest/3`
  lists the images as `images_unserved`, with any file left under
  `priv/static/images/bubble/` (served there without the policy).
  New routers' browser pipeline adds `img-src 'self' data: blob: https:`
  to Phoenix's default policy; an older router without an `img-src`
  already allows them.

  ## Pages (WTF-370)

  With `frontend:` (a `BubbleEx.Frontend.Normalized`) the app gets its
  Bubble pages, printed by `BubbleEx.Target.Phoenix.Pages`: one owned
  LiveView per page (module + `.html.heex`), one owned function component
  per reusable element, `data-bubble-id` on every element, the owned
  `<Module>.Bubble.Runtime` the compiled bindings call, and generated
  `<Web>.BubbleRoutes` (the page routes at their Bubble paths, in an
  `ash_authentication_live_session`; the owned router calls its
  `bubble_routes/0` once, with or without a frontend, so pages added later
  are routed on regeneration; a page an owner dropped (WTF-422, a `:drop`
  in `project.applied`) is neither routed nor rendered), `assets/css/bubble.css` (`@theme` tokens,
  named styles as component classes), `assets/css/bubble_residue.css`,
  `<Web>.Bubble` (overlay JS commands and the Escape hook),
  `.wtf/surfaces.json` (locked page and component names) and a
  traceability test that checks every page's route, mounts it and renders
  every reusable element. A router scaffolded before WTF-370 lacks the
  call: `check_manifest/3` lists the pages as `unrouted` and the
  traceability test fails for them with the fix. `frontend_report/2`
  counts it.

  ## Frontend workflows (WTF-372)

  With `frontend_workflows:` (`BubbleEx.Target.Elixir.FrontendWorkflows.map/3`
  of the lowered page and reusable-element workflows) the pages run their
  Bubble workflows, printed by `BubbleEx.Target.Phoenix.FrontendWorkflows`:
  one owned `Workflows` module per page and per reusable element with
  workflows, custom states or tracked inputs (WTF-359 Q5), the generated
  runtime `<Web>.BubbleWorkflows` the LiveViews call (`mount`,
  `handle_params`, `handle_event` for the page's own `bubble:*` events,
  `handle_info`), elements wired with `phx-click` (JS commands for
  element-only workflows, else the page's click event, checked against
  the page's list), tracked inputs in their own `phx-change` form, custom
  states and input values kept per reusable-element instance, and an owned
  smoke test per native workflow tagged `bubble_smoke:` with its plan
  subject. Data steps and scheduled backend workflows run on the backend
  workflow runtime (`<Module>.Workflows.Runtime`, WTF-373: its job and
  call budgets apply), so `workflows:` is required with it. Workflows that
  read or write stored data run only with an explicit opt-in
  (`config :<app>, <Web>.BubbleWorkflows, data_access: true`): as
  generated (`privacy: :omit`) no resource has an authorizer, so nothing
  is authorized.

  ## Options

    * `:name` - the display name; blank or absent means the Bubble app ID
      (`project_name/2`)
    * `:module` - the root module (one alias segment), default
      `module_name/1` of the name; the web module is `<module>Web`
    * `:app` - the OTP application, default the module underscored
    * `:frontend` - the normalized frontend whose pages to render
    * `:expressions` - its compiled bindings
      (`BubbleEx.Target.Elixir.Frontend.compile/5`, with `runtime:
      "<Module>.Bubble.Runtime"` and `namespace: "<Module>"`)
    * `:surface_names` - the previous `.wtf/surfaces.json`, decoded: its
      page modules and paths and component names are kept (WTF-352 D5)
    * `:assets` - downloaded images and icons by exporter ID (as
      `BubbleEx.Frontend` collects them), served from
      `priv/bubble_images`
    * `:asset_store` - the static assets downloaded by
      `mix bubble.fetch_assets` (`BubbleEx.Frontend.StaticAssets.load_store/1`;
      see "Static assets" above)
    * `:api_clients` - a `BubbleEx.Target.ApiClients.Spec` to render the
      API Connector clients of (see above); none by default
    * `:frontend_workflows` - with `frontend:` and `workflows:`, the page
      and reusable-element workflows to wire into the pages
      (`BubbleEx.Target.Elixir.FrontendWorkflows.Spec`, see "Frontend
      workflows" above); none by default
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Frontend.Json
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Target.ApiClients.Spec
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec, as: FlowSpec
  alias BubbleEx.Target.Ash.{Identity, Project, Resource, Source, Versions}
  alias BubbleEx.Target.Ash.Workflows.Spec, as: WorkflowSpec
  alias BubbleEx.Target.Phoenix.{ApiClients, Formatter, Manifest, Pages, Templates}
  alias BubbleEx.Target.Phoenix.Structural.Bypasses
  alias BubbleEx.Target.Phoenix.Workflows, as: WorkflowFiles

  @version Mix.Project.config()[:version]

  # Scaffolding dependencies besides the Ash pins from BubbleEx.Target.Ash.
  # The framework is pinned exactly: these are the versions the Phoenix
  # compile check (scripts/phoenix_compile_check.sh) builds and tests.
  @scaffold_deps [
    {:ash_phoenix, "== 2.3.25"},
    {:ash_authentication, "== 4.15.0"},
    {:ash_authentication_phoenix, "== 2.17.4"},
    {:oban, "== 2.24.1"},
    {:ash_oban, "== 0.8.14"},
    {:phoenix, "== 1.8.15"},
    # the version the rendered HEEx is formatted with (Formatter)
    {:phoenix_live_view, "== " <> Formatter.live_view_version()},
    {:phoenix_html, "~> 4.1"},
    {:phoenix_ecto, "~> 4.5"},
    {:ecto_sql, "~> 3.13"},
    {:postgrex, ">= 0.0.0"},
    {:phoenix_live_reload, "~> 1.2", only: :dev},
    {:lazy_html, ">= 0.1.0", only: :test},
    {:sourceror, "~> 1.7", only: [:dev, :test]},
    {:esbuild, "~> 0.10", runtime: false},
    {:tailwind, "~> 0.5", runtime: false},
    {:swoosh, "~> 1.16"},
    {:req, "~> 0.5"},
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_poller, "~> 1.0"},
    {:jason, "~> 1.2"},
    {:dns_cluster, "~> 0.2.0"},
    {:bandit, "~> 1.5"}
  ]

  # Tailwind v4 and esbuild binaries (config :tailwind / :esbuild).
  @tailwind "4.3.3"
  @esbuild "0.25.4"

  # Oban's schema version (Oban.Migrations.Postgres) at the pinned Oban.
  @oban_migration 14
  @oban_migration_path "priv/repo/migrations/20260101000000_add_oban_jobs_table.exs"

  @token_table "auth_tokens"
  # Tables the scaffold creates besides the Project's.
  @claimed_tables [@token_table, "oban_jobs", "oban_peers"]
  # Root-level modules the scaffold defines besides the Project's (Repo,
  # Domain and Application are reserved by BubbleEx.Target.Ash.Naming).
  @claimed_modules ["Mailer"]

  # OTP applications a root module name must not turn into.
  @taken_apps ~w(elixir kernel stdlib logger mix eex ex_unit iex crypto ssl inets public_key
                 runtime_tools ash ash_postgres ash_sql ash_phoenix ash_authentication
                 ash_authentication_phoenix ash_oban oban phoenix phoenix_live_view phoenix_html
                 phoenix_ecto phoenix_pubsub phoenix_template phoenix_live_reload ecto ecto_sql
                 postgrex plug plug_crypto bandit swoosh req finch mint jason telemetry
                 telemetry_metrics telemetry_poller dns_cluster esbuild tailwind spark reactor
                 splode igniter decimal mime joken jose assent bcrypt_elixir castore websock
                 thousand_island)

  # Top-level module names a root module must not shadow: Elixir's own
  # (Task, Stream, Config, Registry, Logger, Mix, ExUnit…, read from the
  # compiling Elixir) and the dependencies' namespaces.
  @elixir_modules for app <- [:elixir, :logger, :ex_unit, :mix, :eex, :iex],
                      Application.load(app) in [:ok, {:error, {:already_loaded, app}}],
                      {:ok, modules} = :application.get_key(app, :modules),
                      module <- modules,
                      ["Elixir", top | _] <- [module |> Atom.to_string() |> String.split(".")],
                      uniq: true,
                      do: top
  @taken_modules Enum.sort(
                   @elixir_modules ++
                     ~w(Elixir Kernel Ash AshPostgres AshSql AshPhoenix AshAuthentication AshOban
                        Oban Phoenix Ecto Postgrex Plug Bandit Swoosh Req Finch Mint Jason
                        Telemetry DNSCluster Esbuild Tailwind Spark Reactor Splode Igniter
                        Decimal MIME Joken JOSE Assent Bcrypt Castore WebSock ThousandIsland
                        LazyHTML Sourceror Crux Iterex Multigraph YamlElixir Ymlr HPAX)
                 )

  @generated_header "Generated by bubble_ex (BubbleEx.Target.Phoenix). Do not edit: the next\n" <>
                      "generation overwrites this file, and .wtf/generated.json records its\n" <>
                      "SHA-256 so hand edits are detected."

  @no_authorization "privacy: :omit - NO authorization: Bubble's privacy rules are not enforced.\n" <>
                      "Add Ash policies before exposing this data through any API,\n" <>
                      "LiveView or controller."

  @enforced_note "privacy: :enforced - reads follow Bubble's privacy rules (compiled to Ash policies;\n" <>
                   "stricter than Bubble by design where a condition reads an empty value on the\n" <>
                   "user's side or a logged-out user, where `x is no` meets an empty yes/no, where the\n" <>
                   "everyone rule's grants would reach users another rule matches, and where a search\n" <>
                   "filters or sorts on a field the user may not view; see .wtf/verification and\n" <>
                   "BubbleEx.Verify.Difference).\n" <>
                   "WRITES ARE NOT CHECKED AGAINST THE PRIVACY RULES: the generated workflow runtime's\n" <>
                   "writes are allowed (the workflow's conditions guard them, as in Bubble); any\n" <>
                   "other write is forbidden."

  @type option ::
          {:name, String.t() | nil}
          | {:module, String.t()}
          | {:app, String.t()}
          | {:api_clients, Spec.t() | nil}
          | {:workflows, WorkflowSpec.t() | nil}
          | {:frontend_workflows, FlowSpec.t() | nil}
  @type files :: %{String.t() => binary()}

  @doc """
  The root module for a project name: its alphanumeric words camelized
  (`"Blue Sky"` → `"BlueSky"`), `"Project"` when nothing is left, prefixed
  with `"App"` when it would start with a digit, and suffixed with `"App"`
  when it would shadow an Elixir or dependency module or its application
  name would be a dependency's (`"Task"` → `"TaskApp"`, `"Phoenix"` →
  `"PhoenixApp"`).
  """
  @spec module_name(String.t() | nil) :: String.t()
  def module_name(name) do
    module =
      name
      |> to_string()
      |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
      |> Enum.map_join(&Macro.camelize/1)

    cond do
      module == "" -> "Project"
      String.match?(module, ~r/^[0-9]/) -> "App" <> module
      taken?(module) -> module <> "App"
      true -> module
    end
  end

  @doc """
  The project's display name: `name` when it has non-blank text (trimmed),
  otherwise the Bubble app ID, otherwise `"Bubble Import"`.
  """
  @spec project_name(Project.t(), String.t() | nil) :: String.t()
  def project_name(%Project{} = project, name) do
    [name, project.bubble_id]
    |> Enum.map(&if(is_binary(&1), do: String.trim(&1)))
    |> Enum.find("Bubble Import", &(is_binary(&1) and &1 != ""))
  end

  @doc """
  The project's Mix dependencies: the Target.Ash pins for `privacy` (the
  Project's privacy mode), then the scaffolding. Each is `{app,
  requirement}` or `{app, requirement, options}`.
  """
  @spec deps(:omit | :unverified | :enforced) ::
          [{atom(), String.t()} | {atom(), String.t(), keyword()}]
  def deps(privacy \\ :omit), do: Versions.versions(privacy: privacy) ++ @scaffold_deps

  @doc "The version of bubble_ex recorded in the manifest."
  @spec generator_version() :: String.t()
  def generator_version, do: @version

  @doc """
  Renders `project` as a file map (path → content), including the manifest
  `.wtf/generated.json`. See the module documentation for the options.
  """
  @spec render(Project.t(), [option()]) :: {:ok, files()} | {:error, Error.t()}
  def render(project, opts \\ [])

  def render(%Project{privacy: privacy} = project, opts)
      when privacy in [:omit, :enforced] and is_list(opts) do
    with {:ok, live_view} <- Formatter.ensure_live_view(),
         {:ok, ctx} <- context(project, opts),
         ctx = Map.put(ctx, :live_view, live_view),
         {:ok, clients} <- api_clients(opts),
         {:ok, user, email, confirmed_at} <- user(project),
         :ok <- check_claims(project, clients),
         {:ok, frontend} <- frontend(opts),
         :ok <- asset_store(opts),
         frontend = without_dropped_pages(frontend, project),
         :ok <- frontend_workflows(opts, frontend),
         {:ok, workflows} <- workflow_files(Keyword.get(opts, :workflows), ctx),
         ctx =
           Map.merge(ctx, %{
             user: user.module,
             email: email,
             confirmed_at: confirmed_at,
             api_clients: clients,
             workflows: workflows,
             data_resources: data_resources(Keyword.get(opts, :frontend_workflows)),
             join_topics: join_topics(project),
             private_files: private_files(project, ctx),
             # the PostgreSQL extensions the project's indexes need
             # (`pg_trgm` for trigram indexes), in the scaffolded Repo
             extensions: project.extensions
           }),
         {:ok, source} <- ash_source(project, user, ctx) do
      pages = pages(frontend, ctx, opts)
      ctx = Map.merge(ctx, %{routes: pages.routes, frontend: frontend_inputs(frontend)})

      generated =
        project
        |> generated_files(source, ctx)
        |> Map.merge(Map.new(pages.generated, fn {p, c} -> {p, mark_generated(p, c, false)} end))
        |> Map.merge(
          clients
          |> ApiClients.files(project, ctx)
          |> Map.new(fn {path, content} -> {path, mark_generated(path, content, false)} end)
        )

      owned = ctx |> owned_files() |> Map.merge(pages.owned)

      # Every authorization bypass the generator writes, per file and
      # purpose (WTF-386): generated, so hash-checked.
      generated =
        Map.put(
          generated,
          Bypasses.path(),
          generated
          |> Map.merge(owned)
          |> Map.filter(fn {path, _} -> String.starts_with?(path, "lib/") end)
          |> Bypasses.allowlist_json()
        )

      # Hash the exact bytes an owner receives; formatting must never be an
      # owner-side post-processing step that invalidates generated.json.
      generated =
        Map.new(generated, fn {path, content} -> {path, Formatter.format(path, content)} end)

      owned = Map.new(owned, fn {path, content} -> {path, Formatter.format(path, content)} end)

      case Enum.filter(Map.keys(generated), &Map.has_key?(owned, &1)) do
        [] ->
          manifest =
            project
            |> Manifest.build(ctx, generated, owned)
            |> put_workflow_input(generated)

          {:ok,
           generated
           |> Map.merge(owned)
           |> Map.put(Manifest.path(), Manifest.encode(manifest))}

        clashes ->
          invalid("generated and owned files clash: #{Enum.join(Enum.sort(clashes), ", ")}")
      end
    end
  end

  def render(%Project{privacy: privacy}, _opts),
    do:
      invalid(
        "the Phoenix target renders privacy: :omit or :enforced projects, got #{inspect(privacy)} " <>
          "(:unverified policies are for inspection only, WTF-356)"
      )

  def render(_project, _opts),
    do: invalid("expected a BubbleEx.Target.Ash.Project and a keyword list")

  @doc """
  What `render/2` made of the frontend (`frontend:`), as counts: pages and
  reusable elements rendered, elements emitted natively, as placeholders
  and inside runtime templates, markers, compiled and marked bindings, and
  style declarations as utilities or residue. No names or IDs.

  `"elements"` = `"native"` + `"placeholder"` + `"in_runtime_template"`,
  counted per rendered surface (an element of a reusable counts once, in
  its component, not per instance; the pages themselves are not counted):

    * `"native"` - printed as an HTML element of its own kind (a Text as
      `<p>`, a Button as `<button>`, a reusable instance as its component
      call…) outside any runtime template. It is **not** a measure of
      finished work: it includes elements that carry
      `TODO(bubble:<id>)` markers (an uncompiled binding, a dropped HTML
      ID) and elements with rules in the residue stylesheet. The Plan's
      coverage (`BubbleEx.Plan`) counts residue-free elements, so it is
      lower
    * `"placeholder"` - a sized stand-in with a marker: plugin and
      unsupported elements, missing or recursive reusables, HTML styles
      sized from other elements, runtime containers (dynamic Repeating
      Groups, Tables)
    * `"in_runtime_template"` - inside a runtime container's per-item
      template, whatever its kind

  `"markers"` counts `TODO(bubble:<id>)` notes (an element can carry
  several); `"bindings_compiled"` / `"bindings_marked"` value bindings;
  `"utilities"` / `"residue_declarations"` style declarations, and
  `"elements_with_residue"` the elements with a residue rule.
  `"assets_<status>"` count `.wtf/assets.json`'s assets by status;
  `"assets_external"` (images linked to other hosts, as in Bubble) is
  informational, not work to do.
  """
  @spec frontend_report(Project.t(), [option()]) :: {:ok, map()} | {:error, Error.t()}
  def frontend_report(%Project{} = project, opts) do
    with {:ok, ctx} <- context(project, opts),
         {:ok, %Normalized{} = frontend} <- frontend(opts) do
      {:ok, pages(without_dropped_pages(frontend, project), ctx, opts).report}
    else
      {:ok, nil} -> invalid("frontend_report/2 needs the frontend: option")
      error -> error
    end
  end

  @doc """
  The owned (scaffold-once) paths of a rendered file map, per its manifest.
  """
  @spec owned_paths(files()) :: [String.t()]
  def owned_paths(files) do
    case Manifest.decode(Map.get(files, Manifest.path(), "")) do
      {:ok, %{"owned" => owned}} when is_map(owned) -> owned |> Map.keys() |> Enum.sort()
      _ -> []
    end
  end

  @doc """
  Detects hand edits to generated files: compares the manifest (its JSON,
  or decoded) with `files` (path → content, or the project's root
  directory). With `previous:` (the older manifest) it also lists `stale`
  files: generated before, no longer generated, still present. See
  `BubbleEx.Target.Phoenix.Manifest.check/3`.

      {:ok, %{clean?: false, modified: ["lib/acme/invoice.ex"], missing: []}} =
        BubbleEx.Target.Phoenix.check_manifest(files[".wtf/generated.json"], edited_files)
  """
  @spec check_manifest(String.t() | map(), files() | Path.t(), keyword()) ::
          {:ok, Manifest.report()} | {:error, Error.t()}
  def check_manifest(manifest, files, opts \\ []), do: Manifest.check(manifest, files, opts)

  # --- context ------------------------------------------------------------------

  defp context(project, opts) do
    name = project_name(project, Keyword.get(opts, :name))
    module = Keyword.get(opts, :module) || module_name(name)

    with :ok <- check(:module, module, ~r/\A[A-Z][A-Za-z0-9]*\z/),
         :ok <- check_module(module) do
      app = Keyword.get(opts, :app) || Macro.underscore(module)

      with :ok <- check(:app, app, ~r/\A[a-z][a-z0-9_]*\z/),
           :ok <- check_app(app) do
        {:ok,
         %{
           name: name,
           module: module,
           web: module <> "Web",
           app: app,
           bubble_ex_version: @version,
           privacy: project.privacy,
           enforced?: project.privacy == :enforced
         }}
      end
    end
  end

  defp api_clients(opts) do
    case Keyword.get(opts, :api_clients) do
      nil ->
        {:ok, nil}

      %Spec{} = spec ->
        {:ok, spec}

      other ->
        invalid(
          "invalid api_clients #{inspect(other)}: expected a BubbleEx.Target.ApiClients.Spec"
        )
    end
  end

  defp check(option, value, pattern) do
    if is_binary(value) and Regex.match?(pattern, value),
      do: :ok,
      else: invalid("invalid #{option} #{inspect(value)}")
  end

  defp taken?(module),
    do: module in @taken_modules or Macro.underscore(module) in @taken_apps

  defp check_module(module) do
    if module in @taken_modules or (module <> "Web") in @taken_modules,
      do: invalid("the module #{inspect(module)} would shadow an Elixir or dependency module"),
      else: :ok
  end

  defp check_app(app) do
    if app in @taken_apps,
      do: invalid("the application name #{inspect(app)} is a dependency's"),
      else: :ok
  end

  # The User resource (Bubble's built-in user type), its email attribute
  # and its confirmed_at attribute (WTF-413).
  defp user(%Project{resources: resources}) do
    with %Resource{} = user <- Enum.find(resources, &(&1.source[:type] == "user")),
         %{name: email} <- Enum.find(user.attributes, &(&1.source[:field] == "email")),
         %{name: confirmed_at} <-
           Enum.find(user.attributes, &(&1.source[:auth] == "confirmed_at")) do
      {:ok, user, email, confirmed_at}
    else
      _ ->
        invalid(
          "the project has no User resource with email and confirmed_at attributes " <>
            "(map it again with BubbleEx.Target.Ash.map/3)"
        )
    end
  end

  defp check_claims(%Project{resources: resources, joins: joins}, clients) do
    # The API clients' root module (WTF-374), when they are rendered.
    claimed = if clients, do: ["ApiClients" | @claimed_modules], else: @claimed_modules

    clashes =
      for %Resource{} = r <- resources ++ joins,
          r.module in claimed or r.table in @claimed_tables,
          do: "#{r.module} (table #{r.table})"

    if clashes == [],
      do: :ok,
      else:
        invalid(
          "the Phoenix scaffold uses the module or table of #{Enum.join(clashes, ", ")}; " <>
            "rename it with a rename decision"
        )
  end

  # --- the frontend (WTF-370) -----------------------------------------------------

  defp frontend(opts) do
    case Keyword.get(opts, :frontend) do
      nil -> {:ok, nil}
      %Normalized{} = frontend -> {:ok, frontend}
      _ -> invalid("frontend: must be a BubbleEx.Frontend.Normalized")
    end
  end

  # Pages an owner dropped (WTF-422, `project.applied`) are neither routed
  # nor rendered: no LiveView, route, surface entry or traceability test.
  defp without_dropped_pages(nil, _project), do: nil

  defp without_dropped_pages(%Normalized{} = frontend, project) do
    dropped = Project.dropped(project).pages

    if MapSet.size(dropped) == 0,
      do: frontend,
      else: %{
        frontend
        | pages: Enum.reject(frontend.pages, &MapSet.member?(dropped, page_id(&1)))
      }
  end

  defp page_id(%{source: %{bubble_id: id}}) when is_binary(id) and id != "", do: id
  defp page_id(%{map_key: key}), do: key

  # Frontend workflows run their data steps and schedule backend workflows
  # on the backend workflow runtime (WTF-373), so they need `workflows:`
  # (a spec of no backend workflow still renders the runtime).
  defp frontend_workflows(opts, frontend) do
    case {Keyword.get(opts, :frontend_workflows), Keyword.get(opts, :workflows)} do
      {nil, _} ->
        :ok

      {%FlowSpec{}, _} when frontend == nil ->
        invalid("frontend_workflows: needs the frontend: option")

      {%FlowSpec{}, %WorkflowSpec{}} ->
        :ok

      {%FlowSpec{}, _} ->
        invalid(
          "frontend_workflows: needs workflows: (a BubbleEx.Target.Ash.Workflows.Spec, " <>
            "even of no backend workflow): its data steps run on the backend workflow runtime"
        )

      _ ->
        invalid("frontend_workflows: must be a BubbleEx.Target.Elixir.FrontendWorkflows.Spec")
    end
  end

  defp asset_store(opts) do
    case Keyword.get(opts, :asset_store) do
      nil -> :ok
      %BubbleEx.Frontend.StaticAssets.Store{} -> :ok
      _ -> invalid("asset_store: must be a BubbleEx.Frontend.StaticAssets.Store (load_store/1)")
    end
  end

  defp pages(nil, ctx, _opts),
    do: %{
      routes: [],
      owned: %{},
      generated: %{
        Pages.routes_path(ctx) => Pages.routes_module(ctx, []),
        "assets/css/bubble.css" => Pages.empty_stylesheet(),
        "assets/css/bubble_residue.css" => "/* No frontend was rendered. */\n"
      },
      report: %{}
    }

  defp pages(%Normalized{} = frontend, ctx, opts) do
    Pages.render(frontend, ctx,
      names: Keyword.get(opts, :surface_names),
      expressions: Keyword.get(opts, :expressions, %{}),
      assets: Keyword.get(opts, :assets, %{}),
      asset_store: Keyword.get(opts, :asset_store),
      workflows: Keyword.get(opts, :frontend_workflows)
    )
  end

  # The frontend's identity in the manifest inputs: the rendered pages are
  # a function of it.
  defp frontend_inputs(nil), do: nil

  defp frontend_inputs(%Normalized{} = frontend) do
    %{
      "bubble_id" => frontend.identity.bubble_id,
      "app_version" => frontend.identity.app_version,
      "normalized_schema_version" => frontend.normalized_schema_version,
      "source_sha256" => Json.sha256(frontend.source.payload || %{})
    }
  end

  # --- the Ash layer --------------------------------------------------------------

  defp ash_source(project, user, ctx) do
    # Magic links look users up by email. Bubble keeps emails unique and
    # compares them ignoring case, so the email is a trimmed :ci_string
    # (citext) with a unique identity.
    identity = %Identity{name: "unique_email", keys: [ctx.email], source: %{target: "phoenix"}}

    resources =
      Enum.map(project.resources, fn
        %Resource{module: module} = r when module == user.module ->
          identities =
            if Enum.any?(r.identities, &(&1.keys == [ctx.email])),
              do: r.identities,
              else: r.identities ++ [identity]

          %{
            r
            | attributes: Enum.map(r.attributes, &email_type(&1, ctx.email)),
              identities: identities,
              indexes: Enum.reject(r.indexes, &email_index?(&1, r, ctx.email))
          }

        r ->
          r
      end)

    Source.render(%{project | resources: resources},
      namespace: ctx.module,
      domain: ctx.module <> ".Domain",
      repo: ctx.module <> ".Repo",
      # The authentication configuration is an owned fragment; resources
      # with database-trigger workflows get the trigger change.
      extend:
        merge_extend([
          workflow_extend(ctx.workflows),
          data_extend(ctx),
          %{user.module => user_extension(project, ctx)}
        ]),
      extra_resources: [ctx.module <> ".Accounts.Token" | workflow_resources(ctx.workflows)]
    )
  end

  # The file fields private files may be attached to (the generated
  # Uploads' `private_files/0`, `privacy: :enforced`), as source.
  defp private_files(%Project{} = project, ctx) do
    for %Resource{privacy: %{file_fields: [_ | _] = fields}} = r <- project.resources,
        a <- r.attributes,
        a.name in fields do
      "{#{ctx.module}.#{r.module}, #{atom_source(a.name)}, #{match?({:array, _}, a.type)}}"
    end
    |> then(&("[" <> Enum.join(&1, ", ") <> "]"))
  end

  # Attribute names are identifiers (BubbleEx.Target.Ash.Naming); quoted
  # otherwise.
  defp atom_source(name) do
    if name =~ ~r/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/, do: ":" <> name, else: ":" <> inspect(name)
  end

  # The User includes the owned authentication fragment. With enforced
  # policies, AshAuthentication's own interactions (sign-in, token
  # lookups, the magic-link request) bypass them, first, as its installer
  # sets up; everything else follows the privacy rules.
  defp user_extension(%Project{privacy: :enforced}, ctx),
    do: %{
      fragments: [ctx.module <> ".Accounts.UserAuthentication"],
      policy_bypasses: [
        {"AshAuthentication.Checks.AshAuthenticationInteraction", "ash_authentication"}
      ]
    }

  defp user_extension(_project, ctx),
    do: %{fragments: [ctx.module <> ".Accounts.UserAuthentication"]}

  # An `email equals` search hint's btree index over the email alone
  # (WTF-418): the unique identity's index already serves it (citext
  # compares ignoring case), so a second index would only slow writes.
  # Wider indexes that start with the email are kept.
  defp email_index?(%{method: :btree, columns: columns}, resource, email) do
    case Enum.find(resource.attributes, &(&1.name == email)) do
      %{} = attribute -> columns == [attribute.column || attribute.name]
      nil -> false
    end
  end

  defp email_index?(_index, _resource, _email), do: false

  defp email_type(%{name: email} = attribute, email),
    do: %{attribute | type: :ci_string, constraints: [trim?: true, allow_empty?: false]}

  defp email_type(attribute, _email), do: attribute

  # --- files ----------------------------------------------------------------------

  defp generated_files(project, source, ctx) do
    lib = "lib/#{ctx.app}/"
    web = "lib/#{ctx.app}_web/"
    assigns = assigns(ctx)

    ash =
      for {module, code} <- split_modules(source), into: %{} do
        relative = String.replace_prefix(module, ctx.module <> ".", "")
        {lib <> Macro.underscore(relative) <> ".ex", code}
      end

    templates = %{
      (lib <> "repo_extensions.ex") => "lib/app/repo_extensions.ex",
      (lib <> "accounts/token.ex") => "lib/app/accounts/token.ex",
      (lib <> "accounts/resources.ex") => "lib/app/accounts/resources.ex",
      (web <> "controllers/workflow_api_controller.ex") =>
        "lib/web/controllers/workflow_api_controller.ex",
      # The migrated files (WTF-415), routed by the generated BubbleRoutes.
      (web <> "uploads.ex") => "lib/web/uploads.ex",
      (web <> "uploads_host_guard.ex") => "lib/web/uploads_host_guard.ex",
      (web <> "controllers/uploads_controller.ex") => "lib/web/controllers/uploads_controller.ex",
      "test/#{ctx.app}_web/uploads_test.exs" => "test/uploads_test.exs"
    }

    templates =
      if ctx.workflows,
        do:
          Map.merge(templates, %{
            (lib <> "workflows/runtime.ex") => "lib/app/workflows/runtime.ex",
            (lib <> "workflows/scheduler.ex") => "lib/app/workflows/scheduler.ex",
            (lib <> "workflows/triggers.ex") => "lib/app/workflows/triggers.ex"
          }),
        else: templates

    templated = Map.new(templates, fn {path, t} -> {path, Templates.render(t, assigns)} end)
    {workflow_json, workflow_code} = workflow_generated(ctx.workflows)

    ash
    |> Map.merge(templated)
    |> Map.merge(workflow_code)
    |> Map.new(fn {path, content} ->
      {path, mark_generated(path, content, Map.has_key?(ash, path), ctx.privacy)}
    end)
    |> Map.merge(workflow_json)
    |> then(fn files ->
      if ctx.join_topics == [] do
        files
      else
        path = "lib/#{ctx.app}/bubble/changes.ex"
        content = Templates.render("lib/app/bubble/changes.ex", assigns)
        Map.put(files, path, mark_generated(path, content, false))
      end
    end)
    |> Map.put(".wtf/names.json", pretty_json(project.names))
  end

  # --- backend workflows (WTF-373) ---------------------------------------------------

  defp workflow_files(nil, _ctx), do: {:ok, nil}

  defp workflow_files(%WorkflowSpec{namespace: namespace} = spec, %{module: namespace} = ctx),
    do: {:ok, WorkflowFiles.files(spec, ctx)}

  defp workflow_files(%WorkflowSpec{namespace: namespace}, ctx),
    do:
      invalid(
        "the workflows were mapped for namespace #{inspect(namespace)}, " <>
          "not the module #{inspect(ctx.module)}"
      )

  defp workflow_files(other, _ctx),
    do: invalid("expected a BubbleEx.Target.Ash.Workflows.Spec, got #{inspect(other)}")

  # Extensions for the same resource combine: their modules are listed
  # together and their DSL printed one after the other.
  defp merge_extend(extends) do
    Enum.reduce(extends, %{}, fn extend, acc ->
      Map.merge(acc, extend, fn _module, a, b -> Map.merge(a, b, &merge_extension/3) end)
    end)
  end

  defp merge_extension(:dsl, a, b), do: a <> "\n" <> b
  defp merge_extension(_key, a, b), do: Enum.uniq(a ++ b)

  # --- page data (WTF-420) ----------------------------------------------------------

  # The resources the pages' data reads (relative modules): they publish
  # their changes so the pages reload.
  defp data_resources(%FlowSpec{surfaces: surfaces}) do
    for {_id, s} <- surfaces,
        d <- Map.get(s, :data, []),
        d.residue == [] and is_binary(d.resource),
        uniq: true,
        do: d.resource
  end

  defp data_resources(_), do: []

  # A join write changes the owner's list even though the owner record itself
  # was not updated. Publish only the affected owner IDs, never join records.
  defp join_topics(project) do
    types = Map.new(project.resources, &{&1.source.type, &1.module})

    for join <- project.joins do
      owners =
        for side <- join.join.sides,
            endpoint = Map.fetch!(join.join, side.owner),
            uniq: true,
            do: {Map.fetch!(types, side.type), endpoint.column}

      {join.module, owners}
    end
  end

  # Page resources publish type and record topics through Ash.Notifier.PubSub.
  # Join resources use Changes as a notifier to publish their owners' record
  # topics; writing membership does not update the owner itself.
  defp data_extend(ctx) do
    ctx.data_resources
    |> Kernel.++(Enum.map(ctx.join_topics, &elem(&1, 0)))
    |> Enum.uniq()
    |> Map.new(&data_extension(&1, ctx))
  end

  defp data_extension(resource, ctx) do
    topic = inspect(resource)

    dsl = """
    pub_sub do
      module #{ctx.module}.Bubble.Changes
      prefix "bubble"

      publish_all :create, [#{topic}]
      publish_all :update, [#{topic}]
      publish_all :destroy, [#{topic}]
      publish_all :update, [#{topic}, :_pkey]
      publish_all :destroy, [#{topic}, :_pkey]
    end
    """

    notifiers =
      if(resource in ctx.data_resources, do: ["Ash.Notifier.PubSub"], else: []) ++
        if Enum.any?(ctx.join_topics, fn {join, _} -> join == resource end),
          do: ["#{ctx.module}.Bubble.Changes"],
          else: []

    {resource,
     %{notifiers: notifiers, dsl: if(resource in ctx.data_resources, do: dsl, else: "")}}
  end

  defp workflow_extend(nil), do: %{}
  defp workflow_extend(%{extend: extend}), do: extend

  defp workflow_resources(nil), do: []
  defp workflow_resources(%{resources: resources}), do: resources

  # The generated workflow files: the JSON report (no header) and the code.
  defp workflow_generated(nil), do: {%{}, %{}}

  defp workflow_generated(%{generated: generated}),
    do: Map.split_with(generated, fn {path, _} -> String.ends_with?(path, ".json") end)

  defp put_workflow_input(manifest, generated) do
    case generated[".wtf/workflows.json"] do
      nil ->
        manifest

      json ->
        sha = :sha256 |> :crypto.hash(json) |> Base.encode16(case: :lower)
        put_in(manifest, ["inputs", "workflows_sha256"], sha)
    end
  end

  defp owned_files(ctx) do
    lib = "lib/#{ctx.app}"
    web = "lib/#{ctx.app}_web"
    assigns = assigns(ctx)

    templates = %{
      ".formatter.exs" => "formatter.exs",
      ".gitignore" => "gitignore",
      "README.md" => "README.md",
      "mix.exs" => "mix.exs",
      "config/config.exs" => "config/config.exs",
      "config/dev.exs" => "config/dev.exs",
      "config/test.exs" => "config/test.exs",
      "config/prod.exs" => "config/prod.exs",
      "config/runtime.exs" => "config/runtime.exs",
      "#{lib}.ex" => "lib/app.ex",
      "#{lib}/application.ex" => "lib/app/application.ex",
      "#{lib}/repo.ex" => "lib/app/repo.ex",
      "#{lib}/mailer.ex" => "lib/app/mailer.ex",
      "#{lib}/accounts/secrets.ex" => "lib/app/accounts/secrets.ex",
      "#{lib}/accounts/user_authentication.ex" => "lib/app/accounts/user_authentication.ex",
      "#{lib}/accounts/magic_link_sender.ex" => "lib/app/accounts/magic_link_sender.ex",
      "#{lib}/accounts/magic_link_email.ex" => "lib/app/accounts/magic_link_email.ex",
      "#{web}.ex" => "lib/web.ex",
      "#{web}/endpoint.ex" => "lib/web/endpoint.ex",
      "#{web}/router.ex" => "lib/web/router.ex",
      "#{web}/telemetry.ex" => "lib/web/telemetry.ex",
      "#{web}/live_user_auth.ex" => "lib/web/live_user_auth.ex",
      "#{web}/auth_overrides.ex" => "lib/web/auth_overrides.ex",
      "#{web}/components/layouts.ex" => "lib/web/components/layouts.ex",
      "#{web}/components/layouts/root.html.heex" => "lib/web/components/layouts/root.html.heex",
      "#{web}/controllers/error_html.ex" => "lib/web/controllers/error_html.ex",
      "#{web}/controllers/error_json.ex" => "lib/web/controllers/error_json.ex",
      "#{web}/controllers/page_controller.ex" => "lib/web/controllers/page_controller.ex",
      "#{web}/controllers/page_html.ex" => "lib/web/controllers/page_html.ex",
      "#{web}/controllers/page_html/home.html.heex" =>
        "lib/web/controllers/page_html/home.html.heex",
      "#{web}/controllers/auth_controller.ex" => "lib/web/controllers/auth_controller.ex",
      "assets/css/app.css" => "assets/css/app.css",
      "assets/js/app.js" => "assets/js/app.js",
      "priv/repo/migrations/.formatter.exs" => "priv/migrations_formatter.exs",
      "priv/repo/seeds.exs" => "priv/seeds.exs",
      @oban_migration_path => "priv/add_oban.exs",
      "priv/static/robots.txt" => "priv/robots.txt",
      "test/test_helper.exs" => "test/test_helper.exs",
      "test/support/data_case.ex" => "test/support/data_case.ex",
      "test/support/conn_case.ex" => "test/support/conn_case.ex",
      "test/#{ctx.app}_web/smoke_test.exs" => "test/smoke_test.exs",
      "test/#{ctx.app}_web/bubble_images_test.exs" => "test/bubble_images_test.exs"
    }

    templates =
      if ctx.routes == [] and ctx.workflows == nil,
        do: templates,
        else: Map.put(templates, "#{lib}/bubble/runtime.ex", "lib/app/bubble/runtime.ex")

    templates
    |> Map.new(fn {path, t} -> {path, Templates.render(t, assigns)} end)
    |> Map.merge(if ctx.workflows, do: ctx.workflows.owned, else: %{})
    |> Map.put(
      "mix.lock",
      "# Resolved by mix deps.get; mix.exs pins the framework.\n%{}\n"
    )
  end

  defp assigns(ctx) do
    Map.merge(ctx, %{
      workflows?: Map.get(ctx, :workflows) != nil,
      deps: deps_source(ctx.privacy),
      tailwind: @tailwind,
      esbuild: @esbuild,
      oban_migration: @oban_migration,
      token_table: @token_table,
      name_attribute: html_attribute(ctx.name),
      salts: %{live_view: salt(ctx.app, "live_view"), session: salt(ctx.app, "session")},
      dev_secrets: secrets(ctx.app, "dev"),
      test_secrets: secrets(ctx.app, "test")
    })
  end

  defp deps_source(privacy) do
    privacy
    |> deps()
    |> Enum.map_join(",\n", fn
      {app, requirement} ->
        "      {#{inspect(app)}, #{Templates.source(requirement)}}"

      {app, requirement, opts} ->
        options = Enum.map_join(opts, ", ", fn {k, v} -> "#{k}: #{Templates.source(v)}" end)
        "      {#{inspect(app)}, #{Templates.source(requirement)}, #{options}}"
    end)
  end

  # Deterministic per-app salts and development-only secrets: the same
  # project renders the same bytes. Production secrets come from the
  # environment (config/runtime.exs).
  defp salt(app, purpose) do
    :sha256
    |> :crypto.hash("bubble_ex:#{purpose}:#{app}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 8)
  end

  defp secrets(app, env) do
    secret = fn purpose ->
      :sha512
      |> :crypto.hash("bubble_ex:#{env}:#{purpose}:#{app}")
      |> Base.encode64()
      |> binary_part(0, 64)
    end

    %{
      secret_key_base: secret.("secret_key_base"),
      token_signing_secret: secret.("token_signing_secret")
    }
  end

  # A HEEx attribute value: a literal when the name needs no escaping.
  defp html_attribute(text) do
    if String.match?(text, ~r/\A[^"'{}<>&\\#]*\z/),
      do: ~s("#{text}"),
      else: "{" <> Templates.heex_literal(text) <> "}"
  end

  # One `{module, code}` per top-level `defmodule` of the Source output (its
  # header comment is dropped: each generated file gets its own).
  defp split_modules(source) do
    source
    |> String.split(~r/\n(?=defmodule )/)
    |> Enum.flat_map(fn chunk ->
      case Regex.run(~r/\Adefmodule ([A-Za-z0-9_.]+) do/, chunk) do
        [_, module] -> [{module, String.trim_trailing(chunk) <> "\n"}]
        nil -> []
      end
    end)
  end

  defp mark_generated(path, content, ash?, privacy \\ :omit) do
    header =
      cond do
        not ash? -> @generated_header
        privacy == :enforced -> @generated_header <> "\n\n" <> @enforced_note
        true -> @generated_header <> "\n\n" <> @no_authorization
      end

    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] ->
        comment(header, "# ", "") <> "\n" <> content

      ".css" ->
        "/* " <> String.replace(header, "\n", "\n   ") <> " */\n\n" <> content

      _ ->
        content
    end
  end

  defp comment(text, prefix, suffix) do
    text
    |> String.split("\n")
    |> Enum.map_join(&(String.trim_trailing(prefix <> &1 <> suffix) <> "\n"))
  end

  defp pretty_json(value),
    do: (value |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"

  defp invalid(message), do: {:error, Error.new(:invalid_input, message)}
end
