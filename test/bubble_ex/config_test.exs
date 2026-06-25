defmodule BubbleEx.ConfigTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Config

  describe "get/3" do
    test "returns value from application config" do
      Application.put_env(:bubble_ex, :logs, default_endpoint: "https://custom.endpoint.com")

      result = Config.get(:logs, :default_endpoint)

      assert result == "https://custom.endpoint.com"

      # Cleanup
      Application.delete_env(:bubble_ex, :logs)
    end

    test "returns default when key not found" do
      Application.delete_env(:bubble_ex, :logs)

      result = Config.get(:logs, :default_endpoint, "default_value")

      assert result == "default_value"
    end

    test "returns default when module config not found" do
      Application.delete_env(:bubble_ex, :nonexistent)

      result = Config.get(:nonexistent, :key, "default_value")

      assert result == "default_value"
    end
  end

  describe "get/1" do
    test "returns entire module config" do
      config = [default_endpoint: "https://test.com", default_timeout: 5000]
      Application.put_env(:bubble_ex, :logs, config)

      result = Config.get(:logs)

      assert result == config

      # Cleanup
      Application.delete_env(:bubble_ex, :logs)
    end

    test "returns nil when module config not found" do
      Application.delete_env(:bubble_ex, :nonexistent)

      result = Config.get(:nonexistent)

      assert result == nil
    end
  end

  describe "logs_endpoint/1" do
    test "returns endpoint from options" do
      opts = [endpoint: "https://custom.bubble.io/logs"]

      result = Config.logs_endpoint(opts)

      assert result == "https://custom.bubble.io/logs"
    end

    test "returns endpoint from application config when not in options" do
      Application.put_env(:bubble_ex, :logs, default_endpoint: "https://config.bubble.io/logs")

      result = Config.logs_endpoint([])

      assert result == "https://config.bubble.io/logs"

      # Cleanup
      Application.delete_env(:bubble_ex, :logs)
    end

    test "returns default endpoint when not configured" do
      Application.delete_env(:bubble_ex, :logs)

      result = Config.logs_endpoint([])

      assert result == "https://bubble.io/appeditor/get_jetstream_logs"
    end
  end

  describe "logs_timeout/1" do
    test "returns timeout from options" do
      opts = [timeout: 15_000]

      result = Config.logs_timeout(opts)

      assert result == 15_000
    end

    test "returns timeout from application config when not in options" do
      Application.put_env(:bubble_ex, :logs, default_timeout: 25_000)

      result = Config.logs_timeout([])

      assert result == 25_000

      # Cleanup
      Application.delete_env(:bubble_ex, :logs)
    end

    test "returns default timeout when not configured" do
      Application.delete_env(:bubble_ex, :logs)

      result = Config.logs_timeout([])

      assert result == 30_000
    end
  end

  describe "logs_app_version/1" do
    test "returns app_version from options" do
      opts = [app_version: "test"]

      result = Config.logs_app_version(opts)

      assert result == "test"
    end

    test "returns app_version from application config when not in options" do
      Application.put_env(:bubble_ex, :logs, default_app_version: "development")

      result = Config.logs_app_version([])

      assert result == "development"

      # Cleanup
      Application.delete_env(:bubble_ex, :logs)
    end

    test "returns default app_version when not configured" do
      Application.delete_env(:bubble_ex, :logs)

      result = Config.logs_app_version([])

      assert result == "live"
    end
  end

  describe "logs_pool_max_connections/1" do
    test "returns pool_max_connections from options" do
      opts = [pool_max_connections: 20]

      result = Config.logs_pool_max_connections(opts)

      assert result == 20
    end

    test "returns pool_max_connections from application config when not in options" do
      Application.put_env(:bubble_ex, :logs, pool_max_connections: 15)

      result = Config.logs_pool_max_connections([])

      assert result == 15

      # Cleanup
      Application.delete_env(:bubble_ex, :logs)
    end

    test "returns default pool_max_connections when not configured" do
      Application.delete_env(:bubble_ex, :logs)

      result = Config.logs_pool_max_connections([])

      assert result == 10
    end
  end

  describe "logs_pool_timeout/1" do
    test "returns pool_timeout from options" do
      opts = [pool_timeout: 45_000]

      result = Config.logs_pool_timeout(opts)

      assert result == 45_000
    end

    test "returns pool_timeout from application config when not in options" do
      Application.put_env(:bubble_ex, :logs, pool_timeout: 60_000)

      result = Config.logs_pool_timeout([])

      assert result == 60_000

      # Cleanup
      Application.delete_env(:bubble_ex, :logs)
    end

    test "returns default pool_timeout when not configured" do
      Application.delete_env(:bubble_ex, :logs)

      result = Config.logs_pool_timeout([])

      assert result == 30_000
    end
  end

  describe "apps_timeout/1" do
    test "returns timeout from options" do
      opts = [timeout: 8000]

      result = Config.apps_timeout(opts)

      assert result == 8000
    end

    test "returns timeout from application config when not in options" do
      Application.put_env(:bubble_ex, :apps, default_timeout: 12_000)

      result = Config.apps_timeout([])

      assert result == 12_000

      # Cleanup
      Application.delete_env(:bubble_ex, :apps)
    end

    test "returns default timeout when not configured" do
      Application.delete_env(:bubble_ex, :apps)

      result = Config.apps_timeout([])

      assert result == 10_000
    end
  end

  describe "apps_max_body_length/1" do
    test "returns max_body_length from options" do
      opts = [max_body_length: 50_000_000]

      result = Config.apps_max_body_length(opts)

      assert result == 50_000_000
    end

    test "returns max_body_length from application config when not in options" do
      Application.put_env(:bubble_ex, :apps, max_body_length: 75_000_000)

      result = Config.apps_max_body_length([])

      assert result == 75_000_000

      # Cleanup
      Application.delete_env(:bubble_ex, :apps)
    end

    test "returns default max_body_length when not configured" do
      Application.delete_env(:bubble_ex, :apps)

      result = Config.apps_max_body_length([])

      assert result == 100_000_000
    end
  end
end
