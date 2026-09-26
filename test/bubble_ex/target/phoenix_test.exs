defmodule BubbleEx.Target.PhoenixTest do
  use ExUnit.Case, async: true

  alias BubbleEx.CanonicalJson
  alias BubbleEx.Target.Ash.{Project, Source}
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Test.DecidedFixture

  @generated [
    ".wtf/names.json",
    "assets/css/bubble.css",
    "lib/acme_import/accounts/token.ex",
    "lib/acme_import/domain.ex",
    "lib/acme_import/enums/status.ex",
    "lib/acme_import/invoice.ex",
    "lib/acme_import/invoice2.ex",
    "lib/acme_import/tag.ex",
    "lib/acme_import/types/json_value.ex",
    "lib/acme_import/user.ex",
    "lib/acme_import_web/controllers/workflow_api_controller.ex"
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
    "lib/acme_import/application.ex",
    "lib/acme_import/mailer.ex",
    "lib/acme_import/repo.ex",
    "lib/acme_import_web.ex",
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

      assert files["lib/acme_import/repo.ex"] =~ ~s(["ash-functions"])
      assert files["lib/acme_import/enums/status.ex"] =~ ~s({"open", [label: "Open"]})
    end

    test "adds magic-link authentication to the User" do
      files = render!()
      user = files["lib/acme_import/user.ex"]

      assert user =~ "extensions: [AshAuthentication]"
      assert user =~ "identity :unique_email, [:email]"
      assert user =~ "magic_link do"
      assert user =~ "identity_field :email"
      assert user =~ "registration_enabled? false"
      assert user =~ "sender AcmeImport.Accounts.MagicLinkSender"
      assert user =~ "token_resource AcmeImport.Accounts.Token"
      refute user =~ "password"

      token = files["lib/acme_import/accounts/token.ex"]
      assert token =~ "extensions: [AshAuthentication.TokenResource]"
      assert token =~ ~s(table "auth_tokens")

      sender = files["lib/acme_import/accounts/magic_link_sender.ex"]
      assert sender =~ "use AshAuthentication.Sender"
      assert sender =~ "Oban.insert!"

      router = files["lib/acme_import_web/router.ex"]
      assert router =~ "auth_routes AuthController, AcmeImport.User"
      assert router =~ "magic_sign_in_route(AcmeImport.User, :magic_link"
      assert router =~ ~s(scope "/api/1.1/wf", AcmeImportWeb)
      assert router =~ ~s(match :*, "/:name", WorkflowApiController, :dispatch)
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
      assert files["lib/acme_import/user.ex"] =~ "identity_field :login_email"
      assert files["lib/acme_import/user.ex"] =~ "identity :unique_email, [:login_email]"
      assert files["test/acme_import_web/smoke_test.exs"] =~ "login_email: email"
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

      for var <- ~w(DATABASE_URL SECRET_KEY_BASE TOKEN_SIGNING_SECRET),
          do: assert(runtime =~ ~s|System.get_env("#{var}")|)

      # Development secrets differ per environment and app, and never
      # appear in the production configuration.
      dev = files["config/dev.exs"]
      test = files["config/test.exs"]
      [dev_secret] = Regex.run(~r/secret_key_base: "([^"]+)"/, dev, capture: :all_but_first)
      [test_secret] = Regex.run(~r/secret_key_base: "([^"]+)"/, test, capture: :all_but_first)
      assert byte_size(dev_secret) == 64
      refute dev_secret == test_secret
      refute runtime =~ dev_secret
      refute render!(representative_project(), name: "Other")["config/dev.exs"] =~ dev_secret
    end

    test "uses Tailwind v4 theme tokens and no daisyUI" do
      files = render!()

      assert files["assets/css/app.css"] =~ ~s(@import "tailwindcss")
      assert files["assets/css/app.css"] =~ ~s(@import "./bubble.css")
      assert files["assets/css/bubble.css"] =~ "@theme {"

      # no daisyUI plugin, dependency or component classes
      for {path, content} <- files,
          do:
            refute(
              content =~ ~r/@plugin\s+"daisyui|:daisyui|Overrides\.DaisyUI|btn-primary/,
              path
            )
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

      for opts <- [[module: "acme"], [module: "Acme.Web"], [app: "Acme"], [app: "phoenix"]],
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
               ~S|default={"Acme \"\#{System.halt()}\" <b>"}|
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
               "privacy" => "omit"
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
          extend: %{"Tag" => %{extensions: ["Some.Extension"], dsl: "custom_section do\nend"}},
          extra_resources: ["Acme.Extra"]
        )

      [tag] = Regex.run(~r/defmodule Acme.Tag do.*?\nend\n/s, source)
      assert tag =~ "extensions: [Some.Extension]"
      assert tag =~ "custom_section do"
      refute source =~ ~r/defmodule Acme.Invoice do[^\n]*\n[^\n]*extensions/
      assert source =~ "resource Acme.Extra"

      for {extend, extra} <- [
            {%{"Nope" => %{extensions: [], dsl: ""}}, []},
            {%{"Tag" => %{extensions: ["not an alias"], dsl: ""}}, []},
            {%{"Tag" => :bad}, []},
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
