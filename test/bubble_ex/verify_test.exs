defmodule BubbleEx.VerifyTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Error, Verify}
  alias BubbleEx.Test.PermutedJson
  alias BubbleEx.Verify.{Recording, Result, Scenario, Seed, Staleness}

  @dir "test/support/verify"
  @goldens ~w(seed.json scenario.privacy_read.json scenario.api_workflow.json
              recording.bubble.json recording.model.json result.pass.json
              result.decided_difference.json result.waived.json result.quarantined.json
              result.stale.json)

  defp golden(name), do: File.read!(Path.join(@dir, name))

  defp load(name) do
    {:ok, doc} = name |> golden() |> Verify.decode()
    doc
  end

  describe "golden examples" do
    for name <- @goldens do
      test "#{name} round-trips to its canonical JSON" do
        text = golden(unquote(name))
        {:ok, doc} = Verify.decode(text)

        assert Verify.encode(doc) == text |> Jason.decode!() |> CanonicalJson.encode()
        assert {:ok, ^doc} = doc |> Verify.encode() |> Verify.decode()
      end

      test "#{name} encodes the same bytes whatever the member order" do
        raw = unquote(name) |> golden() |> Jason.decode!()
        {:ok, doc} = Verify.decode(golden(unquote(name)))

        for seed <- 1..5 do
          :rand.seed(:exsss, {seed, seed, seed})
          {:ok, permuted} = raw |> PermutedJson.encode() |> Verify.decode()
          assert Verify.encode(permuted) == Verify.encode(doc)
        end
      end
    end

    test "decode dispatches on format" do
      assert %Seed{} = load("seed.json")
      assert %Scenario{} = load("scenario.privacy_read.json")
      assert %Recording{oracle: :bubble} = load("recording.bubble.json")
      assert %Result{status: :waived} = load("result.waived.json")
      assert Verify.formats() == Enum.sort(Verify.formats())
    end

    test "content hashes are pinned (a change here is a format change)" do
      seed = load("seed.json")
      scenario = load("scenario.privacy_read.json")

      assert Seed.sha256(seed) ==
               "eb77f55e705fd65ea0b648ff426b57d4ed503350c4b613450983256a9f4ae510"

      assert scenario.seed.sha256 == Seed.sha256(seed)

      assert Scenario.sha256(scenario) ==
               "66912ad57afa03b58031449262701f0f598b4cd16bb1cc3403ea17153b5c1636"
    end

    test "the examples are consistent with each other and current" do
      seed = load("seed.json")
      privacy = load("scenario.privacy_read.json")
      api = load("scenario.api_workflow.json")
      bubble = load("recording.bubble.json")
      model = load("recording.model.json")

      assert :ok = Scenario.check_seed(privacy, seed)
      assert :ok = Scenario.check_seed(api, seed)
      assert :ok = Recording.check_scenario(bubble, privacy)
      assert :ok = Recording.check_scenario(model, privacy)
      assert Staleness.recording(bubble, privacy, seed) == []

      result = load("result.pass.json")
      assert result.oracle.sha256 == Recording.sha256(bubble)

      assert Staleness.result(result, %{
               scenario: privacy,
               seed: seed,
               recording: bubble,
               source_sha256: result.basis.source_sha256,
               decisions_sha256: result.basis.decisions_sha256
             }) == []
    end
  end

  describe "decode/1" do
    test "an unknown format is :unknown_format" do
      assert {:error, %Error{kind: :unknown_format}} =
               Verify.decode(~s({"format": "bubble_ex.verify.nope"}))
    end

    test "invalid JSON and documents without a format are :invalid_input" do
      assert {:error, %Error{kind: :invalid_input}} = Verify.decode("{")
      assert {:error, %Error{kind: :invalid_input}} = Verify.decode(~s([1]))
    end

    test "an unsupported schema_version is :invalid_input" do
      raw = "seed.json" |> golden() |> Jason.decode!() |> Map.put("schema_version", 2)

      assert {:error, %Error{kind: :invalid_input, message: message}} = Verify.decode(raw)
      assert message =~ "schema_version"
    end

    test "unknown members are :invalid_input in every format" do
      for name <- @goldens do
        raw = name |> golden() |> Jason.decode!() |> Map.put("extra", 1)
        assert {:error, %Error{kind: :invalid_input, message: message}} = Verify.decode(raw)
        assert message =~ "unknown"
      end
    end
  end
end
