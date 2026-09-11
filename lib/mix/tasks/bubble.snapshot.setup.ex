defmodule Mix.Tasks.Bubble.Snapshot.Setup do
  @shortdoc "Install the optional pinned browser snapshot runtime"
  @moduledoc """
  Installs Node packages and Chromium for browser snapshot mode.

      mix bubble.snapshot.setup

  Requires Node 18+ and npm. Uses the user cache directory, or
  `BUBBLE_EX_SNAPSHOT_RUNTIME` when set. The app-data renderer needs neither.
  """
  use Mix.Task
  alias BubbleEx.Frontend.Snapshot.Runtime

  @impl true
  def run([]) do
    Mix.Task.run("compile")
    dir = Runtime.directory()

    with :ok <- Runtime.setup_files(dir),
         {_, 0} <- System.cmd("npm", ["ci", "--ignore-scripts"], cd: dir, into: IO.stream()),
         {_, 0} <-
           System.cmd(
             "node",
             [Path.join(dir, "node_modules/playwright/cli.js"), "install", "chromium"],
             into: IO.stream()
           ) do
      Mix.shell().info("Snapshot runtime installed in #{dir}")
    else
      _ -> Mix.raise("Snapshot runtime installation failed")
    end
  end

  def run(_), do: Mix.raise("Usage: mix bubble.snapshot.setup")
end
