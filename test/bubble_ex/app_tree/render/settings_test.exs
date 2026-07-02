defmodule BubbleEx.AppTree.Render.SettingsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.Render.Settings

  test "summarizes domain, API exposure, and installed plugins" do
    app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")

    text = app["settings"] |> Settings.render() |> IO.iodata_to_binary()

    assert text == """
           # Settings

           _Generated from settings.json — do not edit._

           - Domain: example.com
           - Data API exposed: true
           - Workflow API exposed: false

           ## Installed plugins (1)

           - 123x456

           _Note: `settings.json` contains the full client_safe payload; the `secure` section ships redacted by Bubble._
           """
  end

  test "tolerates missing settings" do
    assert Settings.render(nil) |> IO.iodata_to_binary() =~ "# Settings"
  end
end
