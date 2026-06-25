defmodule BubbleEx.Characterization.DbEctoTest do
  @moduledoc """
  Characterization test freezing Db.Reader + Db.Ecto output against the synthetic
  fixture (test/support/samples/synthetic_app.json). Asserts stable, intentional
  structural facts (module names, primary-key attrs, fields, belongs_to lines,
  migration adds, and FK indexes) rather than byte-for-byte output, since column
  order follows unspecified map iteration order.
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Ecto
  alias BubbleEx.Db.Reader

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  setup do
    {:ok, db} = Reader.parse(@app)
    {:ok, code} = Ecto.encode(db)
    {:ok, code: code}
  end

  test "emits a schema module per table with the namespaced module name", %{code: code} do
    assert code =~ "defmodule MyApp.OnboardingAnswer do"
    assert code =~ "defmodule MyApp.SurveyResponse do"
    assert code =~ "defmodule MyApp.StatusType do"
    assert code =~ "use Ecto.Schema"
    assert code =~ "import Ecto.Changeset"
  end

  test "emits a string primary key with autogenerate disabled", %{code: code} do
    assert code =~ "@primary_key {:_id, :string, autogenerate: false}"
    assert code =~ "@foreign_key_type :string"
  end

  test "emits the schema/0 call keyed on the snake_case table name", %{code: code} do
    assert code =~ ~s[schema "onboarding_answer" do]
    assert code =~ ~s[schema "survey_response" do]
  end

  test "maps scalar fields to their Ecto types", %{code: code} do
    assert code =~ "field :label, :string"
    assert code =~ "field :score, :float"
    assert code =~ "field :answer, :string"
    assert code =~ "field :rating, :float"
  end

  test "renders a scalar custom reference as belongs_to", %{code: code} do
    assert code =~
             "belongs_to :onboarding_answer, MyApp.OnboardingAnswer, foreign_key: :onboarding_answer_id, references: :_id, type: :string"
  end

  test "renders an option-set reference as belongs_to to the sibling module", %{code: code} do
    assert code =~
             "belongs_to :status, MyApp.StatusType, foreign_key: :status_id, references: :display, type: :string"
  end

  test "emits a migration per table that creates the table without a default pk", %{code: code} do
    assert code =~ "defmodule MyApp.Repo.Migrations.CreateSurveyResponse do"
    assert code =~ "use Ecto.Migration"
    assert code =~ ~s[create table("survey_response", primary_key: false) do]
    assert code =~ "add :_id, :string, primary_key: true"
    assert code =~ "add :answer, :string"
    assert code =~ "add :rating, :float"
    assert code =~ "add :onboarding_answer_id, :string"
    assert code =~ "add :status_id, :string"
  end

  test "emits an index per scalar foreign key", %{code: code} do
    assert code =~ "create index(\"survey_response\", [:onboarding_answer_id])"
    assert code =~ "create index(\"survey_response\", [:status_id])"
  end

  test "emits a changeset casting value fields and requiring the primary key", %{code: code} do
    assert code =~ "rec |> cast(attrs, ["
    assert code =~ ":onboarding_answer_id"
    assert code =~ ":status_id"
    assert code =~ "|> validate_required([:_id])"
  end
end
