defmodule BubbleEx.Test.LoadFixture do
  @moduledoc false

  # Invented data (no real app, no real person) shaped like Bubble Data API
  # results, for the data loader (WTF-357): unit tests and
  # scripts/ash_compile_check/load.exs, which loads it into the databases
  # AshPostgres migrated. Two apps:
  #
  #   * :field_types - test/support/model/field_types.json, every Bubble
  #     field kind, mapped source-faithfully
  #   * :cut2 - BubbleEx.Test.DecidedFixture's :cut2 decision set: derived
  #     counts, text references, a derived has_many
  #   * :combined - its :combined set (cut 1): fields derived from related
  #     records, refined number types, renamed table and attributes
  #
  # Keys are field IDs for some fields and display names for others (the
  # loader accepts both); some values are deliberately wrong.

  alias BubbleEx.Load.Export
  alias BubbleEx.Model

  def id(n), do: "1700000000000x" <> String.pad_leading(Integer.to_string(n), 18, "0")

  # --- users (both apps) -------------------------------------------------------------

  def ada, do: id(1)
  def bob, do: id(2)
  def carol, do: id(3)
  def gone_user, do: id(99)

  defp users(extra) do
    [
      Map.merge(
        %{
          "_id" => ada(),
          "Created Date" => "2024-01-01T10:00:00.000Z",
          "Modified Date" => "2024-01-02T10:00:00.000Z",
          "email" => "  Ada@Example.test ",
          "authentication" => %{
            "email" => %{"email" => "ada@example.test", "email_confirmed" => true}
          },
          "user_signed_up" => true
        },
        Enum.at(extra, 0, %{})
      ),
      Map.merge(
        %{
          "_id" => bob(),
          "Created Date" => 1_704_103_200_000,
          "Modified Date" => "2024-01-02T10:00:00.000Z",
          "authentication" => %{
            "email" => %{"email" => "bob@example.test", "email_confirmed" => false}
          }
        },
        Enum.at(extra, 1, %{})
      ),
      Map.merge(
        %{
          "_id" => carol(),
          "Created Date" => "2024-01-03T10:00:00.000Z",
          "Modified Date" => "2024-01-03T10:00:00.000Z",
          "authentication" => %{
            "email" => %{"email" => "carol@example.test", "email_confirmed" => true},
            "google" => %{}
          }
        },
        Enum.at(extra, 2, %{})
      )
    ]
  end

  # --- :field_types --------------------------------------------------------------------

  def task1, do: id(11)
  def task2, do: id(12)
  def project1, do: id(21)

  @cdn "//abc123.cdn.bubble.io/f1700000000000x111/cover%20photo.png"
  @private_url "https://acme.bubbleapps.io/fileupload/f1700000000000x222/contract.pdf"
  @missing_url "https://abc123.cdn.bubble.io/f1700000000000x333/lost.pdf"
  @external_url "https://files.example.test/manual.pdf"

  def cdn_url, do: "https:" <> @cdn
  def private_url, do: @private_url
  def missing_url, do: @missing_url
  def external_url, do: @external_url

  def field_types_rows do
    %{
      "project" => [
        %{"_id" => project1(), "Created Date" => "2024-02-01T00:00:00Z", "Name" => "Launch"}
      ],
      "task" => [
        %{
          "_id" => task1(),
          "Created Date" => "2024-02-02T08:30:00.123Z",
          "Modified Date" => "2024-02-03T08:30:00.000Z",
          "Created By" => ada(),
          "Slug" => "first-task",
          "title_text" => "  keeps spaces ",
          "Attachment" => @private_url,
          "Cover" => @cdn,
          "Files" => [@private_url, @missing_url, @external_url],
          "Images" => [@cdn],
          "Budget" => %{"min" => 10, "max" => 20.5},
          "Window" => ["2024-03-01T00:00:00Z", 1_711_929_600_000],
          "Ranges" => [%{"start" => "2024-03-01T00:00:00Z", "end" => "2024-03-02T00:00:00Z"}],
          "Checks" => [true, false, true],
          "Dates" => ["2024-01-01T00:00:00.5Z", 1_704_067_200_000],
          "Done" => true,
          "Due" => "2024-04-01T12:00:00.000Z",
          "Duration" => 3_600_000,
          "Estimate" => 2,
          "Labels" => ["open", "Closed", "archived"],
          "Notes" => ["see //abc123.cdn.bubble.io/f1x2/a.png", ""],
          "Owner" => bob(),
          "Place" => %{"address" => "1 Main St", "lat" => 50.85, "lng" => 4.35},
          "Places" => [%{"address" => "2 Side St", "lat" => 1, "lng" => 2}, "Plain address"],
          "Project" => project1(),
          "Scores" => [1, "two", 3.5],
          "status_option_status" => "Open",
          "Subtasks" => [task2(), id(98)],
          "Watchers" => [ada(), gone_user()],
          "Legacy Field" => "not in the model"
        },
        %{
          "_id" => task2(),
          "Created Date" => "2024-02-04T00:00:00Z",
          "Modified Date" => "2024-02-04T00:00:00Z",
          "title_text" => "",
          "Estimate" => "three",
          "Done" => "yes",
          "Labels" => [],
          "Owner" => "admin_user_acme_test"
        },
        %{"Created Date" => "2024-02-05T00:00:00Z", "title_text" => "no id"}
      ],
      "user" => users([%{"Nickname" => "ada"}, %{"nickname_text" => "bob"}])
    }
  end

  def field_types_files do
    [
      %{url: cdn_url(), content: "PNG bytes of a cover", content_type: "image/png"},
      %{url: @private_url, content: "%PDF private contract", content_type: "application/pdf"},
      %{url: @missing_url, error: "http_404"}
    ]
  end

  # --- :cut2 ---------------------------------------------------------------------------------

  def board1, do: id(31)
  def board2, do: id(32)
  def card1, do: id(41)
  def card2, do: id(42)
  def card3, do: id(43)
  def gone_card, do: id(97)

  def cut2_rows do
    %{
      "board" => [
        %{
          "_id" => board1(),
          "Created Date" => "2024-05-01T00:00:00Z",
          "Modified Date" => "2024-05-02T00:00:00Z",
          "Name" => "Roadmap",
          "Cards" => [card1(), card2(), gone_card()],
          "Card Count" => 3,
          "Watchers" => [ada(), gone_user()],
          "Watcher Count" => 2,
          "Location" => %{"address" => "Grand Place", "lat" => 50.8467, "lng" => 4.3525}
        },
        %{
          "_id" => board2(),
          "Created Date" => "2024-05-03T00:00:00Z",
          "Modified Date" => "2024-05-03T00:00:00Z",
          "name_text" => "Backlog",
          "Card Count" => 0,
          "Watcher Count" => 0
        }
      ],
      "card" => [
        %{
          "_id" => card1(),
          "Created Date" => "2024-05-04T00:00:00Z",
          "Modified Date" => "2024-05-05T00:00:00Z",
          "Created By" => ada(),
          "Board" => board1(),
          "Title" => "One",
          "Points" => 3,
          "Status" => "doing",
          "Assignee ID" => " #{ada()} ",
          "Blockers" => [card2(), "not an id", gone_card()],
          "Tags" => ["a", "b"],
          "Board card count" => 2,
          "Board watcher count" => 1
        },
        %{
          "_id" => card2(),
          "Created Date" => "2024-05-04T00:00:00Z",
          "Modified Date" => "2024-05-04T00:00:00Z",
          "Board" => board1(),
          "Title" => "Two",
          "Points" => "x",
          "Assignee ID" => "",
          "Board card count" => 5,
          "Board watcher count" => 1
        },
        %{
          "_id" => card3(),
          "Created Date" => "2024-05-06T00:00:00Z",
          "Modified Date" => "2024-05-06T00:00:00Z",
          "Board" => board2(),
          "Title" => "Three",
          "Assignee ID" => gone_user(),
          "Board card count" => 1,
          "Board watcher count" => 0
        },
        # An older copy of card1 (the data changed while paging): not loaded.
        %{
          "_id" => card1(),
          "Created Date" => "2024-05-04T00:00:00Z",
          "Modified Date" => "2024-05-04T12:00:00Z",
          "Board" => board1(),
          "Title" => "One (stale)"
        }
      ],
      "user" => users([%{"Name" => "Ada"}])
    }
  end

  # --- :combined (cut 1: derive_from_related, refine_number_type) ---------------------------

  def workspace1, do: id(51)
  def initiative1, do: id(61)
  def initiative2, do: id(62)
  def todo1, do: id(71)

  def combined_rows do
    %{
      "workspace" => [
        %{"_id" => workspace1(), "Created Date" => "2024-06-01T00:00:00Z", "Name" => "Acme"}
      ],
      "project" => [
        %{
          "_id" => initiative1(),
          "Created Date" => "2024-06-02T00:00:00Z",
          "Workspace" => workspace1(),
          "Workspace created" => "2024-06-01T00:00:00.000Z",
          "Sort: Workspace Name" => "Old name",
          "Task Count" => 2,
          "Title" => "Plan"
        },
        %{
          "_id" => initiative2(),
          "Created Date" => "2024-06-03T00:00:00Z",
          "Task Count" => 2.5,
          "Title" => "Spare"
        }
      ],
      "task" => [
        %{"_id" => todo1(), "Project" => initiative1(), "Points" => 1.25, "Title" => "Write"}
      ],
      "user" => users([])
    }
  end

  # --- exports ---------------------------------------------------------------------------------

  def app(:field_types),
    do: "test/support/model/field_types.json" |> File.read!() |> Jason.decode!()

  def app(:cut2), do: BubbleEx.Test.DecidedFixture.app(:cut2)
  def app(:combined), do: BubbleEx.Test.DecidedFixture.app(:combined)

  def model(which) do
    {:ok, model} = Model.build(app(which))
    model
  end

  def rows(:field_types), do: field_types_rows()
  def rows(:cut2), do: cut2_rows()
  def rows(:combined), do: combined_rows()

  def files(:field_types), do: field_types_files()
  def files(_which), do: []

  @doc "The mapped Project (`opts` go to `Target.Ash.map/3`)."
  def project(which, opts \\ [])
  def project(:field_types, opts), do: BubbleEx.Target.Ash.map(model(:field_types), [], opts)
  def project(which, opts), do: BubbleEx.Test.DecidedFixture.project(which, opts)

  @doc "Writes the fixture's export to `dir`; `rows` overrides the rows."
  def export(which, dir, rows \\ nil) do
    rows = rows || rows(which)

    Export.write(dir, %{
      app: "fixture-app",
      model_sha256: Model.sha256(model(which)),
      # The app's host, where its private (/fileupload/) files live.
      source: %{"kind" => "fixture", "base_url" => "https://acme.bubbleapps.io/version-test"},
      created_at: "2026-09-26T00:00:00Z",
      types: for({type, list} <- Enum.sort(rows), do: %{type: type, path: type, rows: list}),
      files: files(which)
    })
  end
end
