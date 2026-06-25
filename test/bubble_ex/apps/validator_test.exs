defmodule BubbleEx.Apps.ValidatorTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Apps.Validator
  alias BubbleEx.Error

  describe "validate_input/1" do
    test "maps a bare slug to a bubbleapps.io URL" do
      assert {:ok, "https://my-app.bubbleapps.io"} = Validator.validate_input("my-app")
    end

    test "normalizes a bare domain to an https URL" do
      assert {:ok, "https://bubble.io"} = Validator.validate_input("bubble.io")
    end

    test "returns an :invalid_input error for unparseable input" do
      # Uppercase with no reserved chars and no dot: not a slug, not a URL.
      assert {:error, %Error{kind: :invalid_input}} = Validator.validate_input("NotASlug")
    end

    test "returns an :invalid_input error for non-string input" do
      assert {:error, %Error{kind: :invalid_input}} = Validator.validate_input(123)
    end
  end

  describe "validate_bubble_id/1" do
    test "accepts a valid slug" do
      assert :ok = Validator.validate_bubble_id("abacus-desktop")
    end

    test "rejects an invalid bubble id with an :invalid_input error" do
      assert {:error, %Error{kind: :invalid_input}} = Validator.validate_bubble_id("Has Spaces")
    end

    test "rejects a non-string bubble id" do
      assert {:error, %Error{kind: :invalid_input}} = Validator.validate_bubble_id(nil)
    end
  end

  describe "valid_slug?/1" do
    test "accepts lowercase alphanumeric with hyphens" do
      assert Validator.valid_slug?("my-app-1")
    end

    test "rejects uppercase and spaces" do
      refute Validator.valid_slug?("My App")
    end
  end
end
