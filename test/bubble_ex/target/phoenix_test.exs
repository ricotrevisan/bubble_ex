defmodule BubbleEx.Target.PhoenixTest do
  use ExUnit.Case, async: true

  alias BubbleEx.CanonicalJson
  alias BubbleEx.Target.Ash.{Project, Source}
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Target.Phoenix.Formatter
  alias BubbleEx.Test.DecidedFixture

  @generated [
    ".wtf/bypasses.json",
    ".wtf/names.json",
    "assets/css/bubble.css",
    "assets/css/bubble_residue.css",
    "lib/acme_import/accounts/resources.ex",
    "lib/acme_import/accounts/token.ex",
    "lib/acme_import/domain.ex",
    "lib/acme_import/enums/status.ex",
    "lib/acme_import/invoice.ex",
    "lib/acme_import/invoice2.ex",
    "lib/acme_import/repo_extensions.ex",
    "lib/acme_import/tag.ex",
    "lib/acme_import/types/json_value.ex",
    "lib/acme_import/user.ex",
    "lib/acme_import_web/bubble_routes.ex",
    "lib/acme_import_web/controllers/uploads_controller.ex",
    "lib/acme_import_web/controllers/workflow_api_controller.ex",
    "lib/acme_import_web/uploads.ex",
    "lib/acme_import_web/uploads_host_guard.ex",
    "test/acme_import_web/uploads_test.exs"
  ]

  @owned [
    ".formatter.exs",
    ".gitignore",
    "README.md",
    "assets/css/app.css",
    "assets/js/app.js",
    "config/config.exs",
    "config/dev.exs",
    "config/prod.exs",
    "config/runtime.exs",
    "config/test.exs",
    "lib/acme_import.ex",
    "lib/acme_import/accounts/magic_link_email.ex",
    "lib/acme_import/accounts/magic_link_sender.ex",
    "lib/acme_import/accounts/secrets.ex",
    "lib/acme_import/accounts/user_authentication.ex",
    "lib/acme_import/application.ex",
    "lib/acme_import/mailer.ex",
    "lib/acme_import/repo.ex",
    "lib/acme_import_web.ex",
    "lib/acme_import_web/auth_overrides.ex",
    "lib/acme_import_web/components/layouts.ex",
    "lib/acme_import_web/components/layouts/root.html.heex",
    "lib/acme_import_web/controllers/auth_controller.ex",
    "lib/acme_import_web/controllers/error_html.ex",
    "lib/acme_import_web/controllers/error_json.ex",
    "lib/acme_import_web/controllers/page_controller.ex",
    "lib/acme_import_web/controllers/page_html.ex",
    "lib/acme_import_web/controllers/page_html/home.html.heex",
    "lib/acme_import_web/endpoint.ex",
    "lib/acme_import_web/live_user_auth.ex",
    "lib/acme_import_web/router.ex",
    "lib/acme_import_web/telemetry.ex",
    "mix.exs",
    "mix.lock",
    "priv/repo/migrations/.formatter.exs",
    "priv/repo/migrations/20260101000000_add_oban_jobs_table.exs",
    "priv/repo/seeds.exs",
    "priv/static/robots.txt",
    "test/acme_import_web/bubble_images_test.exs",
    "test/acme_import_web/smoke_test.exs",
    "test/support/conn_case.ex",
    "test/support/data_case.ex",
    "test/test_helper.exs"
  ]

  defp render!(project \\ representative_project(), opts \\ [name: "Acme Import"]) do
    {:ok, files} = Phoenix.render(project, opts)
    files
  end

  defp manifest(files), do: Jason.decode!(files[".wtf/generated.json"])

  describe "render/2" do
    test "renders the complete Phoenix/Ash file map, deterministically" do
      project = representative_project()
      files = render!(project)

      assert files |> Map.keys() |> Enum.sort() ==
               Enum.sort([".wtf/generated.json" | @generated ++ @owned])

      assert files == render!(project)
      assert Enum.all?(files, fn {path, content} -> is_binary(path) and is_binary(content) end)

      # No migrations or snapshots of the resources: mix ash.codegen makes them.
      refute Enum.any?(Map.keys(files), &String.contains?(&1, "snapshot"))
    end

    test "fresh output is formatter-clean and the manifest hashes the formatted bytes" do
      files = render!()

      for {path, content} <- files, Path.extname(path) in [".ex", ".exs"] do
        assert content == Phoenix.Formatter.format(path, content), path
      end

      for {path, content} <- files, String.ends_with?(path, ".heex") do
        assert content == Phoenix.Formatter.format(path, content), path
      end

      assert {:ok, %{clean?: true, modified: []}} =
               Phoenix.check_manifest(files[".wtf/generated.json"], files)
    end

    test "every generated Elixir file parses" do
      for {path, content} <- render!(), Path.extname(path) in [".ex", ".exs"] do
        assert {:ok, _} = Code.string_to_quoted(content), "#{path} does not parse"
      end
    end

    test "splits the Ash source one module per file (ProjectRenderer parity)" do
      files = render!()

      invoice = files["lib/acme_import/invoice.ex"]
      assert invoice =~ "defmodule AcmeImport.Invoice do"
      assert invoice =~ ~r/use Ash.Resource,\s+domain: AcmeImport.Domain,/
      assert invoice =~ "repo AcmeImport.Repo"
      assert invoice =~ ~r/attribute :id, :string,\s+primary_key\?: true/
      assert invoice =~ "belongs_to :owner, AcmeImport.User"
      assert invoice =~ "reference :owner, ignore?: true"
      assert invoice =~ "attribute :status, AcmeImport.Enums.Status"
      refute invoice =~ "defmodule AcmeImport.Tag"
      # privacy: :omit: no policy machinery
      refute invoice =~ "Ash.Policy.Authorizer"

      domain = files["lib/acme_import/domain.ex"]
      assert domain =~ "use Ash.Domain"

      for resource <- ~w(Invoice Invoice2 Tag User Accounts.Token),
          do: assert(domain =~ "resource AcmeImport.#{resource}")

      assert files["lib/acme_import/repo.ex"] =~
               ~s{["ash-functions", "citext"] ++ AcmeImport.RepoExtensions.all()}

      assert files["lib/acme_import/repo_extensions.ex"] =~ "def all, do: []"
      assert files["lib/acme_import/repo.ex"] =~ "%Version{major: 14"
      assert files["lib/acme_import/enums/status.ex"] =~ ~s({"open", [label: "Open"]})
    end

    test "join resources (WTF-406) are generated files; the Repo installs the indexes' extensions" do
      {:ok, project} = BubbleEx.Test.DecidedFixture.project(:cut3)
      files = render!(project)
      assert files["lib/acme_import/project_tasks.ex"] =~ "defmodule AcmeImport.ProjectTasks do"
      assert files["lib/acme_import/domain.ex"] =~ "resource AcmeImport.ProjectTasks"
      assert Map.has_key?(manifest(files)["generated"], "lib/acme_import/project_tasks.ex")
      assert files["lib/acme_import/project.ex"] =~ "through AcmeImport.ProjectTasks"

      # the cut-2 hints applied by default include a trigram index: the
      # generated RepoExtensions lists pg_trgm, and a Repo scaffolded
      # before it (no call) is reported
      {:ok, indexed} = BubbleEx.Test.DecidedFixture.project(:indexes)
      assert indexed.extensions == ["pg_trgm"]
      files = render!(indexed)
      assert files["lib/acme_import/repo_extensions.ex"] =~ ~s(def all, do: ["pg_trgm"])
      # the note for an owned Repo scaffolded before it is in the generated file
      assert files["lib/acme_import/repo_extensions.ex"] =~
               "does not call it and is never rewritten"

      assert Map.has_key?(manifest(files)["generated"], "lib/acme_import/repo_extensions.ex")
      manifest = files[".wtf/generated.json"]
      assert {:ok, %{extensions_unlisted: []}} = Phoenix.check_manifest(manifest, files)

      old_repo =
        String.replace(
          files["lib/acme_import/repo.ex"],
          " ++ AcmeImport.RepoExtensions.all()",
          ""
        )

      assert {:ok, %{extensions_unlisted: ["pg_trgm"]}} =
               Phoenix.check_manifest(manifest, %{files | "lib/acme_import/repo.ex" => old_repo})

      named = String.replace(old_repo, ~s("citext"]), ~s("citext", "pg_trgm"]))

      assert {:ok, %{extensions_unlisted: []}} =
               Phoenix.check_manifest(manifest, %{files | "lib/acme_import/repo.ex" => named})
    end

    test "change notifications dispatch join owner topics without a compile-time map" do
      template = "lib/app/bubble/changes.ex"
      assigns = %{module: "AcmeImport", web: "AcmeImportWeb", join_topics: %{}}
      empty = BubbleEx.Target.Phoenix.Templates.render(template, assigns)
      refute empty =~ "@join_topics"
      assert empty =~ "defp join_topics(_resource), do: []"

      joined =
        BubbleEx.Target.Phoenix.Templates.render(template, %{
          assigns
          | join_topics: %{"ProjectTasks" => [{"Project", "project_id"}]}
        })

      assert joined =~
               "defp join_topics(AcmeImport.ProjectTasks), do: [{\"Project\", :project_id}]"

      assert joined =~ "defp join_topics(_resource), do: []"
      assert joined =~ "join_topics(resource)"
    end

    test "adds magic-link authentication to the User through an owned fragment" do
      files = render!()
      user = files["lib/acme_import/user.ex"]

      assert user =~ "fragments: [AcmeImport.Accounts.UserAuthentication]"
      assert user =~ "identity :unique_email, [:email]"
      # case-insensitive and trimmed, so case and whitespace never block sign-in
      assert user =~
               ~r/attribute :email, :ci_string,[^\n]*\n[^a]*.*trim\?: true, allow_empty\?: false/s

      refute user =~ "authentication do"

      auth = files["lib/acme_import/accounts/user_authentication.ex"]
      assert auth =~ "use Spark.Dsl.Fragment, of: Ash.Resource, extensions: [AshAuthentication]"
      assert auth =~ "magic_link do"
      assert auth =~ "identity_field Resources.email_field()"
      assert auth =~ "registration_enabled? false"
      assert auth =~ "sender AcmeImport.Accounts.MagicLinkSender"
      assert auth =~ "token_resource AcmeImport.Accounts.Token"
      refute auth =~ ~r/^\s*password do/m

      resources = files["lib/acme_import/accounts/resources.ex"]
      assert resources =~ "def user, do: AcmeImport.User"
      assert resources =~ "def email_field, do: :email"

      token = files["lib/acme_import/accounts/token.ex"]
      assert token =~ "extensions: [AshAuthentication.TokenResource]"
      assert token =~ ~s(table "auth_tokens")

      sender = files["lib/acme_import/accounts/magic_link_sender.ex"]
      assert sender =~ "use AshAuthentication.Sender"
      assert sender =~ "Phoenix.Token.encrypt("
      assert sender =~ "Oban.insert!"
      assert files["lib/acme_import/accounts/magic_link_email.ex"] =~ "unique: [period: 60"

      # Owned code names the User only through Accounts.Resources.
      for path <- @owned,
          do: refute(files[path] =~ "AcmeImport.User", "#{path} names the User")

      router = files["lib/acme_import_web/router.ex"]
      assert router =~ "auth_routes AuthController, AcmeImport.Accounts.Resources.user()"
      assert router =~ "magic_sign_in_route(AcmeImport.Accounts.Resources.user(), :magic_link"
      assert router =~ ~s(scope "/api/1.1/wf", AcmeImportWeb)
      assert router =~ ~s(match :*, "/:__wf_name", WorkflowApiController, :dispatch)

      # The sign-in pages load nothing from a third party (WTF-378): the
      # default banner's logo is on ash-hq.org.
      assert router =~
               "overrides: [AcmeImportWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]"

      refute router =~ "overrides: [AshAuthentication.Phoenix.Overrides.Default]"
      overrides = files["lib/acme_import_web/auth_overrides.ex"]
      assert overrides =~ "set :image_url, nil"
      assert overrides =~ "set :dark_image_url, nil"
      assert overrides =~ ~s(set :text, "Acme Import")
    end

    test "the User's confirmed_at: generated, and a magic-link sign-in sets it (WTF-413)" do
      files = render!()

      assert files["lib/acme_import/user.ex"] =~
               "attribute :confirmed_at, :utc_datetime_usec, allow_nil?: true, writable?: true, public?: false"

      assert files["lib/acme_import/accounts/resources.ex"] =~
               "def confirmed_at_field, do: :confirmed_at"

      controller = files["lib/acme_import_web/controllers/auth_controller.ex"]
      assert controller =~ "user = confirm_email(user, activity)"
      # only a sign-in, with a user (the request phase has none)
      assert controller =~ "defp confirm_email(%_{} = user, {:magic_link, :sign_in}) do"
      assert controller =~ "def success(conn, {:magic_link, :request}, _user, _token) do"
      assert controller =~ "Resources.confirmed_at_field()"

      assert files["test/acme_import_web/smoke_test.exs"] =~
               "signing in keeps a confirmed_at loaded from Bubble"

      # A Project without it (mapped before WTF-413) is refused.
      project = representative_project()

      project = %{
        project
        | resources:
            Enum.map(project.resources, fn r ->
              %{r | attributes: Enum.reject(r.attributes, &(&1.source[:auth] == "confirmed_at"))}
            end)
      }

      assert {:error, %BubbleEx.Error{kind: :invalid_input, message: message}} =
               BubbleEx.Target.Phoenix.render(project, name: "Acme Import")

      assert message =~ "confirmed_at"
    end

    test "uses the User's email attribute, whatever its name" do
      project = representative_project()

      project = %{
        project
        | resources:
            Enum.map(project.resources, fn r ->
              attributes =
                Enum.map(r.attributes, fn a ->
                  if a.source[:field] == "email", do: %{a | name: "login_email"}, else: a
                end)

              %{r | attributes: attributes}
            end)
      }

      files = render!(project)
      assert files["lib/acme_import/user.ex"] =~ "identity :unique_email, [:login_email]"
      assert files["lib/acme_import/user.ex"] =~ "attribute :login_email, :ci_string"
      assert files["lib/acme_import/accounts/resources.ex"] =~ "def email_field, do: :login_email"

      # the owned files do not change
      assert Map.take(files, @owned) == Map.take(render!(), @owned)
    end

    test "an index hint over the email alone is skipped: the unique identity serves it (WTF-418)" do
      project = representative_project()

      index = fn name, method, columns ->
        %BubbleEx.Target.Ash.Index{
          name: name,
          method: method,
          columns: columns,
          fields: columns,
          using: if(method == :gin, do: "gin"),
          source: %{type: "user", key: "search_index:user", index: 0}
        }
      end

      # what an `email equals` search hint maps to, a wider index starting
      # with the email, and a non-btree index over it
      hinted = [
        index.("user_email_index", :btree, ["email"]),
        index.("user_email_created_date_index", :btree, ["email", "created_date"]),
        index.("user_email_gin_index", :gin, ["email"])
      ]

      project = %{
        project
        | resources:
            Enum.map(project.resources, fn
              %{source: %{type: "user"}} = r -> %{r | indexes: hinted}
              r -> r
            end)
      }

      user = render!(project)["lib/acme_import/user.ex"]
      assert user =~ "identity :unique_email, [:email]"
      refute user =~ ~s(name: "user_email_index")
      assert user =~ ~s(index [:email, :created_date], name: "user_email_created_date_index")
      assert user =~ ~s(name: "user_email_gin_index")

      # the Ash target alone (no identity) keeps it
      {:ok, source} = Source.render(project)
      assert source =~ ~s(index [:email], name: "user_email_index")

      # an index names columns: an email attribute stored in a column of
      # another name is matched by its column
      project = %{
        project
        | resources:
            Enum.map(project.resources, fn
              %{source: %{type: "user"}} = r ->
                %{
                  r
                  | attributes:
                      Enum.map(r.attributes, fn
                        %{name: "email"} = a -> %{a | column: "email_address"}
                        a -> a
                      end),
                    indexes: [
                      index.("user_email_address_index", :btree, ["email_address"]),
                      index.("user_slug_index", :btree, ["slug"])
                    ]
                }

              r ->
                r
            end)
      }

      user = render!(project)["lib/acme_import/user.ex"]
      assert user =~ "identity :unique_email, [:email]"
      refute user =~ "user_email_address_index"
      assert user =~ ~s(index [:slug], name: "user_slug_index")
    end

    test "pins the Ash versions and the framework without PicoSAT" do
      mix = render!()["mix.exs"]

      refute mix =~ ":picosat_elixir"

      for {app, requirement} <- BubbleEx.Target.Ash.versions(privacy: :omit),
          do: assert(mix =~ "{#{inspect(app)}, #{inspect(requirement)}}")

      for dep <- Phoenix.deps(:omit) do
        assert mix =~ "{#{inspect(elem(dep, 0))}, #{inspect(elem(dep, 1))}"
      end

      for app <- ~w(phoenix phoenix_live_view ash_phoenix ash_authentication
                    ash_authentication_phoenix oban ash_oban tailwind esbuild),
          do: assert(mix =~ "{:#{app}, ")

      assert {:ok, _} = Code.string_to_quoted(mix)
    end

    test "configures Ash, Oban and secrets from the environment" do
      files = render!()
      config = files["config/config.exs"]

      assert config =~ ~S|import_config "#{config_env()}.exs"|
      assert config =~ "config :ash, default_string_length_count: :codepoints"
      assert config =~ "ash_domains: [AcmeImport.Domain]"
      assert config =~ "config :acme_import, Oban,"
      assert files["lib/acme_import/application.ex"] =~ "AshOban.config("

      runtime = files["config/runtime.exs"]

      for var <- ~w(DATABASE_URL SECRET_KEY_BASE TOKEN_SIGNING_SECRET MAILER_ADAPTER MAILER_FROM),
          do: assert(runtime =~ ~r/System.get_env\("#{var}"\) \|\|\s+raise/)

      # production never falls back to the local mailbox
      assert files["config/prod.exs"] =~ "config :swoosh, local: false"
      assert runtime =~ "adapter: mailer_adapter"

      # Development secrets differ per environment and app, and never
      # appear in the production configuration.
      dev = files["config/dev.exs"]
      test = files["config/test.exs"]
      [dev_secret] = Regex.run(~r/secret_key_base: "([^"]+)"/, dev, capture: :all_but_first)
      [test_secret] = Regex.run(~r/secret_key_base: "([^"]+)"/, test, capture: :all_but_first)
      assert byte_size(dev_secret) == 64
      refute dev_secret == test_secret
      refute runtime =~ dev_secret

      # The tests' database: TEST_DATABASE_URL when set (mix wtf.task --test-db,
      # WTF-448), else Phoenix's defaults.
      assert test =~ ~s|database_url = System.get_env("TEST_DATABASE_URL")|
      assert test =~ ~s|if database_url not in [nil, ""] do|
      assert test =~ "url: database_url"
      refute test =~ ~s|System.get_env("DATABASE_URL")|
      assert test =~ ~s|database: "acme_import_test\#{System.get_env("MIX_TEST_PARTITION")}"|
      assert test =~ "pool: Ecto.Adapters.SQL.Sandbox"
      refute render!(representative_project(), name: "Other")["config/dev.exs"] =~ dev_secret

      # config/test.exs is owned: the page data seed is there even before
      # any page is generated, for pages added later. mix wtf.task is not a
      # dependency: the README says to run it from bubble_ex with --root
      # (WTF-455).
      assert test =~ "BubbleData, random_seed: "
      assert files["README.md"] =~ "mix wtf.task audit --root /path/to/this/project"
    end

    test "uses Tailwind v4 theme tokens and no daisyUI" do
      files = render!()

      assert files["assets/css/app.css"] =~ ~s(@import "tailwindcss/utilities.css")
      assert files["assets/css/app.css"] =~ ~s(@import "./bubble.css")
      assert files["assets/css/app.css"] =~ ~s(@import "./bubble_residue.css")
      # No Preflight: Bubble pages assume the browser's defaults.
      refute files["assets/css/app.css"] =~ ~s(@import "tailwindcss")
      assert files["assets/css/bubble.css"] =~ "@theme {"

      # no daisyUI plugin, dependency or component classes
      for {path, content} <- files,
          do:
            refute(
              content =~ ~r/@plugin\s+"daisyui|:daisyui|Overrides\.DaisyUI|btn-primary/,
              path
            )
    end

    test "the workflow API does not echo the requested name" do
      controller = render!()["lib/acme_import_web/controllers/workflow_api_controller.ex"]
      assert controller =~ "def dispatch(conn, _params)"
      refute controller =~ ~s("name")
    end

    test "says the resources have no authorization" do
      files = render!()
      assert files["README.md"] =~ "**no\nauthorization**"

      for path <-
            ~w(lib/acme_import/invoice.ex lib/acme_import/user.ex lib/acme_import/domain.ex),
          do: assert(files[path] =~ "NO authorization", path)
    end

    test "ignores the plan content key" do
      assert render!()[".gitignore"] =~ ~r{^/\.wtf/plan\.key$}m
    end

    test "writes the name map" do
      project = representative_project()
      names = Jason.decode!(render!(project)[".wtf/names.json"])
      assert names == Jason.decode!(Jason.encode!(project.names))
      assert names["resources"]["invoice-a"]["module"] == "Invoice"
    end

    test "marks generated Elixir and CSS files" do
      files = render!()

      for path <- @generated, Path.extname(path) in [".ex", ".css"] do
        assert files[path] =~ "Generated by bubble_ex (BubbleEx.Target.Phoenix)", path
      end

      for path <- @owned, do: refute(files[path] =~ "Generated by bubble_ex", path)
    end

    test "takes the module and app from the options" do
      files = render!(representative_project(), name: "Acme", module: "Shop", app: "shop_app")

      assert files["lib/shop_app/user.ex"] =~ "defmodule Shop.User do"
      assert files["lib/shop_app_web/router.ex"] =~ "defmodule ShopWeb.Router do"
      assert files["mix.exs"] =~ "app: :shop_app"
      assert manifest(files)["module"] == "Shop"
      assert manifest(files)["app"] == "shop_app"
    end

    test "rejects invalid options, unverified privacy and claimed names" do
      project = representative_project()

      for opts <- [
            [module: "acme"],
            [module: "Acme.Web"],
            [module: "Task"],
            [module: "Ecto"],
            [app: "Acme"],
            [app: "phoenix"]
          ],
          do:
            assert(
              {:error, %BubbleEx.Error{kind: :invalid_input}} = Phoenix.render(project, opts)
            )

      assert {:error, %BubbleEx.Error{message: message}} =
               Phoenix.render(%{project | privacy: :unverified})

      assert message =~ "privacy: :omit"

      assert {:error, _} = Phoenix.render(:not_a_project)

      mailer = %{
        project
        | resources: Enum.map(project.resources, &%{&1 | module: &1.module |> mailer()})
      }

      assert {:error, %BubbleEx.Error{message: message}} = Phoenix.render(mailer)
      assert message =~ "Mailer"

      no_user = %{
        project
        | resources: Enum.reject(project.resources, &(&1.source.type == "user"))
      }

      assert {:error, %BubbleEx.Error{message: message}} = Phoenix.render(no_user)
      assert message =~ "User"
    end

    test "derives the names like bubble_wtf's ProjectRenderer" do
      assert Phoenix.module_name("Blue Sky") == "BlueSky"
      assert Phoenix.module_name("  !!  ") == "Project"
      assert Phoenix.module_name("42 crm") == "App42Crm"
      assert Phoenix.module_name(nil) == "Project"
      # an application name a dependency has
      assert Phoenix.module_name("Phoenix") == "PhoenixApp"
      assert Phoenix.module_name("oban") == "ObanApp"

      # an Elixir or dependency module
      for name <- ~w(Task Stream Config Calendar Registry Logger Mix ExUnit Ecto Plug Enum),
          do: assert(Phoenix.module_name(name) == name <> "App")

      project = representative_project()

      for name <- [nil, "", "   "] do
        files = render!(project, name: name)
        assert files["README.md"] =~ ~r/\A# acme\n/
        assert files["lib/acme.ex"] =~ "defmodule Acme do"
      end

      assert Phoenix.project_name(project, "  Blue Sky ") == "Blue Sky"
      assert Phoenix.project_name(%{project | bubble_id: nil}, " ") == "Bubble Import"
    end

    test "escapes the display name in code and templates" do
      files = render!(representative_project(), name: ~S|Acme "#{System.halt()}" <b>|)

      for {path, content} <- files, Path.extname(path) in [".ex", ".exs"] do
        assert {:ok, _} = Code.string_to_quoted(content), "#{path} does not parse"
        refute content =~ ~S|"#{System.halt()}"|, path
      end

      assert files["lib/acme_system_halt_b_web/components/layouts/root.html.heex"] =~
               ~S|default={"Acme \"\#\x7BSystem.halt()\x7D\" \x3Cb>"}|
    end
  end

  # WTF-423: privacy: :enforced renders the compiled policies and the
  # runtime that enforces them. Behavior: scripts/phoenix_compile_check.sh
  # (test/support/target/phoenix/enforced_behavior.exs, and the matrix).
  # An app with its backend workflows, pages and their workflows, as
  # scripts/phoenix_compile_check/render.exs renders it.
  defp full_render(app, privacy) do
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, index} = BubbleEx.Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: privacy)
    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Acme")
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Acme.Bubble.Runtime",
        namespace: "Acme"
      )

    {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
    {:ok, page_data} = BubbleEx.PageData.build(app, model)

    {:ok, flows} =
      BubbleEx.Target.Elixir.FrontendWorkflows.map(lowered, project,
        namespace: "Acme",
        frontend: frontend,
        backend: workflows,
        page_data: page_data
      )

    {:ok, files} =
      Phoenix.render(project,
        name: "Acme",
        module: "Acme",
        workflows: workflows,
        frontend: frontend,
        expressions: expressions,
        frontend_workflows: flows
      )

    files
  end

  describe "render/2 with privacy: :enforced" do
    setup do
      app = "test/support/target/phoenix/enforced.json" |> File.read!() |> Jason.decode!()
      %{files: full_render(app, :enforced), omit: full_render(app, :omit)}
    end

    test "pins PicoSAT and renders the policies, the checks and the Privacy module",
         %{files: files} do
      assert files["mix.exs"] =~ ~s({:picosat_elixir, "== 0.2.3"})
      assert files["lib/acme/task.ex"] =~ "authorizers: [Ash.Policy.Authorizer]"
      assert files["lib/acme/task.ex"] =~ "authorize_if Acme.Privacy.WorkflowWrite"
      assert files["lib/acme/task.ex"] =~ "read :attachments do"
      assert files["lib/acme/privacy/workflow_write.ex"] =~ "bubble_workflow_write: true"
      assert files["lib/acme/privacy.ex"] =~ "def mode, do: :enforced"

      # Every generated Ash file says writes are not policy-checked.
      assert files["lib/acme/task.ex"] =~ "WRITES ARE NOT CHECKED AGAINST THE PRIVACY RULES"
      refute files["lib/acme/task.ex"] =~ "NO authorization"
    end

    test "AshAuthentication's own interactions bypass the User's policies, marked",
         %{files: files} do
      user = files["lib/acme/user.ex"]

      assert user =~
               "# bubble:ignores_privacy scaffold:ash_authentication\n    bypass AshAuthentication.Checks.AshAuthenticationInteraction do"

      assert user =~
               "field_policy_bypass :*, AshAuthentication.Checks.AshAuthenticationInteraction do"

      assert user =~ "private_fields :include"
    end

    test "the runtime marks its writes, loads actors and lets the admin token bypass",
         %{files: files} do
      runtime = files["lib/acme/workflows/runtime.ex"]
      assert runtime =~ "private: %{bubble_workflow_write: true}"
      assert runtime =~ ~r"admin\?\(authorization\) ->\s+\{:ok, nil, true\}"
      assert runtime =~ "Acme.Privacy.load_actor(actor)"
      assert runtime =~ "load: Acme.Privacy.actor_loads()"
      assert runtime =~ "defp visible_lists(record, changes) do"

      data = files["lib/acme_web/bubble_data.ex"]
      assert data =~ "action: :search, actor: ctx.actor"
      assert data =~ "defp failed(_query, %Ash.Error.Forbidden{}), do: nil"

      workflows = files["lib/acme_web/bubble_workflows.ex"]
      assert workflows =~ "def refresh_actor(socket)"
      assert workflows =~ "actor = current_actor(socket)"

      uploads = files["lib/acme_web/uploads.ex"]
      assert uploads =~ ~r":privacy_rules ->\s+attachments\?\(actor"
      assert uploads =~ "def private_files, do: [{Acme.Task, :attachment, false}]"
    end

    test "the README warns that writes are not policy-checked; defaults stay off",
         %{files: files} do
      readme = files["README.md"]
      assert readme =~ "Warning: writes are not checked against the privacy rules"
      assert readme =~ "data_access: true"
      assert files["config/runtime.exs"] =~ "private: false"
    end

    # WTF-457: a search constrained on a field some users may not view
    # (Task's Done: only watchers; Note's Flagged: only its owner) is
    # loaded; Privacy.SearchFields decides per actor and record (only the
    # records where the actor may view the field), since field policies do
    # not guard a filter in code. Stricter than Bubble, by decision.
    test "a page search over a hidden field is loaded, guarded by SearchFields",
         %{files: files, omit: omit} do
      page = files["lib/acme_web/live/index_live/workflows.ex"]
      refute page =~ "search_field_hidden"
      assert page =~ "Ash.Query.filter(done == false)"
      assert page =~ "Ash.Query.filter(flagged == true)"
      refute page =~ "TODO(bubble:element:bList) not loaded"
      refute omit["lib/acme_web/live/index_live/workflows.ex"] =~ "search_field_hidden"

      search_fields = files["lib/acme/privacy/search_fields.ex"]
      assert search_fields =~ "flagged: [[:privacy_rule_owner]]"
      assert search_fields =~ "done: [[:privacy_rule_watching]]"
      assert search_fields =~ "hidden_field_constraint_matches"
      assert files["lib/acme/note.ex"] =~ "authorize_if Acme.Privacy.SearchFields"
      refute omit["lib/acme/privacy/search_fields.ex"]
      # Bubble's random sort reads no field (WTF-452): it loads, through
      # :search like any other search.
      refute page =~ "TODO(bubble:element:bRandom)"
      assert page =~ "|> BubbleData.random_sort()"
    end

    # WTF-459: the generated project's `mix format --check-formatted` must
    # pass whichever Elixir formats it. Elixir 1.17 and 1.18 keep a
    # `name [list] do` head on one line when only its ` do` passes 98
    # columns; 1.19+ break the list. A render made on one version then
    # failed the check on the other (Note's owner field policy head is 100
    # columns). The check below runs on the test's own Elixir; the head
    # length is what the other versions disagree on.
    test "the Elixir is format-clean on every Elixir version", %{files: files} do
      sources = for {path, _} <- files, Path.extname(path) in [".ex", ".exs"], do: path

      for path <- sources,
          do: assert(Formatter.format(path, files[path]) == files[path], path)

      long_heads =
        for path <- sources,
            line <- String.split(files[path], "\n"),
            String.length(line) > 98,
            line =~ ~r/^\s*[a-z_]+ \[.*\] do$/,
            do: {path, line}

      assert long_heads == []
      assert files["lib/acme/note.ex"] =~ ~r/^    field_policy \[\n      :created_date,$/m
    end

    test "a page count reads keys through :search, capped", %{files: files} do
      data = files["lib/acme_web/bubble_data.ex"]
      refute data =~ "Ash.count("
      assert data =~ "|> Ash.read(action: :search, actor: ctx.actor, authorize?: true)"
      assert data =~ "def max_count do"
    end

    test "an :omit render has none of it", %{omit: files} do
      all = files |> Map.values() |> Enum.join()
      refute all =~ "workflow_write"
      refute all =~ "Privacy.load_actor"
      refute all =~ ":privacy_rules"
      refute all =~ "AshAuthenticationInteraction"
      assert files["README.md"] =~ "## Authorization: none yet"
    end

    test ":unverified projects are refused" do
      {:ok, model} = BubbleEx.Model.build(%{"_id" => "x", "user_types" => %{}})
      {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :unverified)
      assert {:error, %BubbleEx.Error{message: message}} = Phoenix.render(project)
      assert message =~ ":unverified policies are for inspection only"
    end
  end

  describe "the manifest" do
    test "records every generated file's hash, the owned files and the inputs" do
      project = representative_project()
      files = render!(project)
      manifest = manifest(files)

      assert manifest["version"] == 1
      assert manifest["target"] == "phoenix"
      assert manifest["generated"] |> Map.keys() |> Enum.sort() == @generated
      assert manifest["owned"] |> Map.keys() |> Enum.sort() == @owned
      assert Phoenix.owned_paths(files) == @owned

      for {path, hash} <- Map.to_list(manifest["generated"]) ++ Map.to_list(manifest["owned"]),
          do: assert(hash == sha256(files[path]), path)

      assert manifest["inputs"] == %{
               "bubble_ex_version" => Phoenix.generator_version(),
               "project_schema_version" => Project.schema_version(),
               "project_sha256" => project |> Project.to_map() |> CanonicalJson.sha256(),
               "decisions_sha256" => nil,
               "applied_sha256" => nil,
               "privacy" => "omit",
               "frontend" => nil
             }

      assert Phoenix.generator_version() == Mix.Project.config()[:version]
      # canonical: sorted keys, stable bytes
      assert files[".wtf/generated.json"] ==
               (manifest |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
    end

    test "records the decision hashes the project was mapped with" do
      project = DecidedFixture.project(:combined, privacy: :omit)
      {:ok, project} = project
      inputs = render!(project)[".wtf/generated.json"] |> Jason.decode!() |> Map.fetch!("inputs")

      assert inputs["decisions_sha256"] == project.decisions_sha256
      assert inputs["applied_sha256"] == project.applied_sha256
      assert is_binary(inputs["decisions_sha256"]) and is_binary(inputs["applied_sha256"])
    end

    test "a changed project changes the project hash, not the owned files" do
      project = representative_project()
      files = render!(project)

      renamed = %{
        project
        | resources: Enum.map(project.resources, &%{&1 | bubble_name: "Renamed"})
      }

      other = render!(renamed)

      refute manifest(files)["inputs"]["project_sha256"] ==
               manifest(other)["inputs"]["project_sha256"]

      assert manifest(files)["owned"] == manifest(other)["owned"]
    end

    test "check_manifest/2 detects hand edits and missing files" do
      files = render!()
      json = files[".wtf/generated.json"]

      assert {:ok, %{clean?: true, modified: [], missing: [], unchanged: unchanged}} =
               Phoenix.check_manifest(json, files)

      assert unchanged == @generated

      edited =
        files
        |> Map.update!("lib/acme_import/invoice.ex", &(&1 <> "# hand edit\n"))
        |> Map.delete("assets/css/bubble.css")
        # owned files are the owner's: not checked
        |> Map.update!("lib/acme_import_web/router.ex", &(&1 <> "# mine\n"))

      assert {:ok, %{clean?: false, modified: ["lib/acme_import/invoice.ex"], missing: missing}} =
               Phoenix.check_manifest(Jason.decode!(json), edited)

      assert missing == ["assets/css/bubble.css"]
    end

    test "check_manifest/3 lists stale generated files with the previous manifest" do
      files = render!()
      old = files[".wtf/generated.json"]

      # the next generation no longer makes the Tag resource
      project = representative_project()

      next =
        render!(%{project | resources: Enum.reject(project.resources, &(&1.module == "Tag"))})

      new = next[".wtf/generated.json"]

      assert {:ok, %{stale: ["lib/acme_import/tag.ex"]}} =
               Phoenix.check_manifest(new, files, previous: old)

      assert {:ok, %{stale: []}} = Phoenix.check_manifest(new, files)

      assert {:ok, %{stale: []}} =
               Phoenix.check_manifest(new, Map.delete(files, "lib/acme_import/tag.ex"),
                 previous: old
               )

      assert {:error, _} = Phoenix.check_manifest(new, files, previous: "not json")
    end

    @tag :tmp_dir
    test "check_manifest/2 reads a project directory", %{tmp_dir: dir} do
      files = render!()

      for {path, content} <- files do
        File.mkdir_p!(Path.join(dir, Path.dirname(path)))
        File.write!(Path.join(dir, path), content)
      end

      json = files[".wtf/generated.json"]
      assert {:ok, %{clean?: true}} = Phoenix.check_manifest(json, dir)

      File.write!(Path.join(dir, "lib/acme_import/user.ex"), "edited")
      assert {:ok, %{modified: ["lib/acme_import/user.ex"]}} = Phoenix.check_manifest(json, dir)

      assert {:error, _} = Phoenix.check_manifest(json, Path.join(dir, "absent"))
    end

    test "check_manifest/2 rejects invalid manifests" do
      files = render!()
      hash = String.duplicate("a", 64)

      for manifest <- [
            "not json",
            ~s({"version": 2, "generated": {}}),
            %{"generated" => %{}},
            %{"version" => 1, "generated" => %{"lib/a.ex" => "short"}},
            %{"version" => 1, "generated" => %{"../outside.ex" => hash}},
            %{"version" => 1, "generated" => %{"/etc/passwd" => hash}}
          ] do
        assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
                 Phoenix.check_manifest(manifest, files)
      end

      assert {:error, _} = Phoenix.check_manifest(files[".wtf/generated.json"], :nope)
    end
  end

  describe "Target.Ash.Source extensions" do
    test "adds extensions and DSL to one resource and resources to the domain" do
      project = representative_project()

      {:ok, source} =
        Source.render(project,
          namespace: "Acme",
          extend: %{
            "Tag" => %{
              extensions: ["Some.Extension"],
              fragments: ["Acme.Tag.Fragment"],
              dsl: "custom_section do\nend"
            }
          },
          extra_resources: ["Acme.Extra"]
        )

      [tag] = Regex.run(~r/defmodule Acme.Tag do.*?\nend\n/s, source)
      assert tag =~ "extensions: [Some.Extension]"
      assert tag =~ "fragments: [Acme.Tag.Fragment]"
      assert tag =~ "custom_section do"
      refute source =~ ~r/defmodule Acme.Invoice do[^\n]*\n[^\n]*extensions/
      assert source =~ "resource Acme.Extra"

      for {extend, extra} <- [
            {%{"Nope" => %{extensions: [], dsl: ""}}, []},
            {%{"Tag" => %{extensions: ["not an alias"], dsl: ""}}, []},
            {%{"Tag" => :bad}, []},
            {%{"Tag" => %{other: 1}}, []},
            {%{"Tag" => %{fragments: ["bad alias"]}}, []},
            {:bad, []},
            {%{}, ["lowercase"]},
            {%{}, :bad}
          ] do
        assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
                 Source.render(project, namespace: "Acme", extend: extend, extra_resources: extra)
      end
    end
  end

  defp mailer("Tag"), do: "Mailer"
  defp mailer(module), do: module

  defp sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defp representative_project do
    payload = %{
      "_id" => "acme",
      "user_types" => %{
        "invoice-a" => %{
          "%d" => "Invoice",
          "%f3" => %{
            "title" => %{"%d" => "Title", "%v" => "text"},
            "tags" => %{"%d" => "Tags", "%v" => "list.custom.tag"},
            "owner" => %{"%d" => "Owner", "%v" => "user"},
            "status" => %{"%d" => "Status", "%v" => "option.status"},
            "mystery" => %{"%d" => "Mystery", "%v" => "not.real"}
          }
        },
        "invoice-b" => %{"%d" => "Invoice", "%f3" => %{}},
        "tag" => %{"%d" => "Tag", "%f3" => %{}}
      },
      "option_sets" => %{
        "status" => %{
          "%d" => "Status",
          "values" => %{
            "open-a" => %{"%d" => "Open", "db_value" => "open"},
            "closed" => %{"%d" => "Closed", "db_value" => "closed"}
          }
        }
      }
    }

    {:ok, model} = BubbleEx.Model.build(payload)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    project
  end
end
