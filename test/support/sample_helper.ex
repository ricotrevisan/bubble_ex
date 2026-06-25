defmodule BubbleEx.SampleHelper do
  @moduledoc """
  Helper module for loading and accessing sample files used in tests.
  This module provides functions to load various sample files from the test/support/samples directory.
  """

  @samples_dir "test/support/samples"

  @doc """
  Loads a JSON sample file by name.
  Returns the parsed JSON as a map.

  ## Parameters
    - name: The name of the JSON file without the .json extension
      (e.g., "synthetic_app")
  """
  def load_json_sample(name) when is_binary(name) do
    @samples_dir
    |> Path.join(name <> ".json")
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Returns a list of available JSON sample names.
  """
  def available_json_samples do
    @samples_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&String.replace(&1, ".json", ""))
  end

  @doc """
  Returns a list of all available sample files.
  """
  def available_samples do
    File.ls!(@samples_dir)
  end
end
