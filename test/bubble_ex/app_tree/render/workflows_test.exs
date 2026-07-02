defmodule BubbleEx.AppTree.Render.WorkflowsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.Render.Workflows

  setup do
    app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")

    ctx = %{
      title: "index",
      element_names: %{"elGrp" => "grp-main", "elBtn" => "BTN: Go", "elNavTxt" => "Text N"},
      files: %{
        "wfReset" => "workflows/reset-form--wfReset.json",
        "wfClick" => "workflows/button-clicked-btn-go--wfClick.json",
        "apiAvatar" => "update-avatar--apiAvatar.json"
      }
    }

    {:ok, app: app, ctx: ctx}
  end

  test "renders page workflows exactly", %{app: app, ctx: ctx} do
    {iodata, coverage} = Workflows.render(app["pages"]["pgA"]["workflows"], ctx)

    assert IO.iodata_to_binary(iodata) == """
           # Workflows: index

           _Generated from workflows/*.json — do not edit._

           ## When BTN: Go is clicked

           _Source: workflows/button-clicked-btn-go--wfClick.json_

           1. OpenURL: https://example.com
           2. Plugin action 123x456-AAA
           3. Unrendered action MysteryAction — see workflows/button-clicked-btn-go--wfClick.json#actions.2

           ## When custom event "Reset Form" is triggered

           _Source: workflows/reset-form--wfReset.json_

           1. HideElement: grp-main
           2. ResetInputs
           """

    assert coverage.actions == %{total: 5, rendered: 3}
  end

  test "renders the backend API index", %{app: app, ctx: ctx} do
    {iodata, coverage} = Workflows.render_api(app["api"], %{ctx | title: "Backend workflows"})

    assert IO.iodata_to_binary(iodata) == """
           # Workflows: Backend workflows

           _Generated from workflows/*.json — do not edit._

           ## When backend workflow "update-avatar" is called

           _Source: update-avatar--apiAvatar.json_

           1. ChangeThing
           """

    assert coverage.actions == %{total: 1, rendered: 1}
  end
end
