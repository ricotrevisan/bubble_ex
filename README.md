# BubbleEx

BubbleEx is a set of utilities that scans bubble.io apps. It can:
- check if a url is a bubble.io app
- check if a bubble app is in a dedicated instance
- build the db structure and export it as DBML, SQL (Postgres/SQLite/T-SQL), Ecto, Zod, Xano, or Convex
- check for exposed endpoints
- scan for exposed secrets (built-in Native scanner or Trufflehog)
- query application logs for monitoring and debugging
- deep search through nested data structures to find specific values
- export a modern-responsive frontend as portable HTML, CSS, assets, and manifests

> **Responsible use:** BubbleEx must only be used on apps you own or are explicitly
> authorized to test. See [SECURITY.md](SECURITY.md) for details.

## Error Handling

Every public function returns either `{:ok, result}` or `{:error, %BubbleEx.Error{}}`.
`BubbleEx.Error` is a single struct with a `:kind` (a closed set of atoms such as
`:not_a_bubble_app`, `:unauthorized`, `:invalid_input`, `:parse_failed`,
`:cli_missing`, `:request_failed`), a human-readable `:message`, and a `:context`
map. Pattern-match on `kind` to handle failures uniformly:

```elixir
case BubbleEx.fetch_app("some-app") do
  {:ok, app} -> app
  {:error, %BubbleEx.Error{kind: :not_a_bubble_app}} -> :not_bubble
  {:error, %BubbleEx.Error{} = error} -> Logger.warning(Exception.message(error))
end
```

## Installation

Add `bubble_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:bubble_ex, "~> 0.3"}]
end
```

Documentation is available at <https://hexdocs.pm/bubble_ex>.

If using with Phoenix, you will likely have an error with `floki`. You will have to remove the `only: test` restriction so that it works.

## Configuration

BubbleEx can be configured in your application config:

```elixir
config :bubble_ex,
  logs: [
    default_endpoint: "https://bubble.io/appeditor/get_jetstream_logs",
    default_timeout: 30_000,
    default_app_version: "live",
    pool_max_connections: 10,
    pool_timeout: 30_000
  ],
  apps: [
    default_timeout: 10_000,
    max_body_length: 100_000_000
  ],
  frontend: [
    asset_timeout: 30_000,
    max_asset_bytes: 20_000_000
  ]
```

## Frontend export

Export one modern-responsive app version as a portable HTML/CSS package.
Legacy Bubble rendering is rejected with `:unsupported_renderer`.

```elixir
{:ok, result} = BubbleEx.export_frontend("my-app", "out/frontend", app_version: "live")
# or from an already-decoded payload:
{:ok, result} = BubbleEx.Frontend.export_payload(payload, "out/frontend")
```

CLI (public apps only; no credentials):

```
mix bubble.export_frontend my-app -o out/frontend [--version live] [--pages index,about] [--fallback] [--force]
```

The package contains `pages/`, reusable fragments, shared/page CSS, hashed
`assets/`, `model.json`, `bindings.json`, `findings.json`, `coverage.json`,
and `MANIFEST.json`. Workflows, conditions, and unsupported elements stay as
bindings and findings. A leaked-credential finding blocks the export and
writes nothing.

## Database Structure & Schema Export

BubbleEx reconstructs a Bubble app's data model — data types (tables), option
sets, fields, types, and relationships — and renders it to a range of schema
formats. Pass a `:format` to `fetch_app/2`; the rendered schema comes back in the
`:schema` key.

```elixir
{:ok, app} = BubbleEx.fetch_app("my-app", format: :postgres)
IO.puts(app.schema)
# CREATE SCHEMA IF NOT EXISTS "custom";
#
# CREATE TABLE "custom"."Survey Response" (
#   "answer" text,
#   ...
#   "_id" text,
#   PRIMARY KEY ("_id")
# );
#
# ALTER TABLE "custom"."Survey Response"
#   ADD FOREIGN KEY ("status") REFERENCES "option"."Status Type" ("Display");
```

### Available formats

| `:format`   | Output |
|-------------|--------|
| `:dbml`     | DBML ([dbdiagram.io](https://dbdiagram.io) / [dbml.org](https://dbml.org)) |
| `:postgres` | PostgreSQL DDL |
| `:sqlite`   | SQLite DDL |
| `:tsql`     | SQL Server / Azure SQL T-SQL DDL |
| `:ecto`     | Ecto schema modules + migrations |
| `:ash`      | Ash resources and embedded resources |
| `:zod`      | Zod (TypeScript) validation schemas |
| `:xano`     | Xano table-schema import JSON |
| `:convex`   | Convex `schema.ts` |

### Naming

Output uses the app's human-readable display names by default (`naming: :proper`).
Pass `naming: :id` to use Bubble's internal identifiers instead:

```elixir
{:ok, app} = BubbleEx.fetch_app("my-app", format: :ecto, naming: :id)
```

### What is and isn't preserved

Each encoder maps Bubble's model as faithfully as the target allows. Scalar
references become real foreign keys (SQL/Ecto) or id fields; Bubble *list* fields
become native arrays where supported (`text[]` in Postgres) or a JSON/text column
otherwise. Option sets (enums) are emitted as lookup tables or string fields —
Bubble's payload does not carry option *member values*, so they cannot become
native database enums.

API Connector v2 External API types reachable from active database fields are
kept as by-value shapes, separate from persisted tables and relationships.
Rendering defaults to `external_types: :preserve`; use `:opaque` for JSON/map
containers without expansion, or `:legacy` for pre-feature API-field output.

```elixir
{:ok, app} = BubbleEx.fetch_app("my-app", format: :zod, external_types: :preserve)
app.schema_warnings # structured warnings, present only when non-empty
```

DBML diagnostics are returned separately in `:dbml_warnings`. BubbleEx never
infers type members from response samples. Version-sensitive output is opt-in
through `external_type_capabilities`, for example `%{tsql: [:native_json]}`.
Target limitations are localized: PostgreSQL uses composites where possible;
Ecto/Ash use identity-free embeds; Zod uses loose objects; Xano expands acyclic
shapes inline; DBML, SQLite, T-SQL, and unsupported recursive edges use honest
JSON fallbacks.

### DBML / database diagram (legacy options)

The original DBML path is unchanged and still available via its own options:

```elixir
{:ok, app} = BubbleEx.fetch_app("my-app", dbml: true)
app.dbml       # DBML text
app.dbdiagram  # same content
```

### Custom formats

Formats are pluggable. Each is a module implementing the `BubbleEx.Db.Encoder`
behaviour — `encode(db_map, opts) :: {:ok, String.t()} | {:error, %BubbleEx.Error{}}`
over the universal map produced by `BubbleEx.Db.Reader.parse/1` — registered in
`BubbleEx.Db.Encoder`. `BubbleEx.Db.Encoder.render/3` additionally returns
structured warnings with the generated content. To add a target, implement the
behaviour and register its `:format` atom.

## Scanning for Secrets

Secret scanning is pluggable via the `BubbleEx.Secrets` behaviour. The default
adapter, `BubbleEx.Secrets.Trufflehog`, shells out to the optional `trufflehog`
CLI. You can swap in your own scanner per call (`adapter:` option) or globally:

```elixir
config :bubble_ex, :secrets_adapter, MyApp.CustomScanner
```

### BubbleEx.Secrets.Native

`BubbleEx.Secrets.Native` is a pure-Elixir, zero-dependency offline scanner —
no CLI required. It is a good baseline for environments where `trufflehog` is
unavailable, or when you want a fast, dependency-free first pass. It detects
fewer secret types than Trufflehog and performs **no live verification** — every
finding carries `verified: false` and should be treated as a potential secret
pending further review.

**Select it globally:**

```elixir
config :bubble_ex, :secrets_adapter, BubbleEx.Secrets.Native
```

**Or per call:**

```elixir
{:ok, findings} = BubbleEx.Secrets.scan(payload, adapter: BubbleEx.Secrets.Native)
```

**Detectors (run by default):** AWS credentials, GitHub personal-access tokens,
Stripe keys, Slack tokens, Google API keys, JWTs, and PEM private-key headers.
A base64 decode pass re-scans decoded values. An additional entropy tier is
available but **opt-in** (off by default):

```elixir
{:ok, findings} = BubbleEx.Secrets.scan(payload,
  adapter: BubbleEx.Secrets.Native,
  entropy: true
)
```

**Finding shape** (atom keys):

```elixir
%{
  detector: "github_pat",   # string identifying the detector
  raw:      "ghp_...",      # the matched string
  redacted: "ghp_…abcd",
  # Path elements are strings (map keys) OR integers (list indices),
  # e.g. ["plugins", 0, "token"] for a secret inside the first list item.
  path:     ["plugins", 0, "token"],
  decoder:  :plain,         # :plain | :base64
  verified: false,          # always false — no live check is performed
  confidence: :high         # :high (regex/base64) | :low (entropy)
}
```

### Prerequisites

The default adapter (`BubbleEx.Secrets.Trufflehog`) requires the `trufflehog`
CLI on your `PATH`
([install instructions](https://github.com/trufflesecurity/trufflehog)). When it
is not installed, scans return `{:error, %BubbleEx.Error{kind: :cli_missing}}`
rather than raising. Use `BubbleEx.Secrets.Native` if you need a no-CLI
alternative.

### Synchronous Scanning

For simple, synchronous scanning:

```elixir
# With an Elixir map
payload = %{"_id" => "app_123", "data" => "content to scan"}
{:ok, results} = BubbleEx.scan_payload_for_secrets(payload)

# Process results
Enum.each(results, fn item ->
  IO.puts("Found secret: #{item["DetectorType"]}")
end)
```

### Asynchronous Scanning with Server

For long-running scans, you can use the `Server` which runs scans asynchronously:

#### Starting the Server

First, add the Server to your supervision tree in your application.ex file:

```elixir
def start(_type, _args) do
  children = [
    # ...other children
    {BubbleEx.Server, []}
  ]

  opts = [strategy: :one_for_one, name: YourApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

Alternatively, start it manually:

```elixir
{:ok, _pid} = BubbleEx.Server.start_link()
```

#### Using the Server

```elixir
# Start a scan and get a ref
payload = %{"_id" => "app_123", "data" => "content to scan"}
{:ok, ref} = BubbleEx.start_scan_for_secrets(payload)

# The calling process will receive progress messages:
receive do
  {:scan_started, ^ref} ->
    IO.puts("Scan started")

  {:scan_output, ^ref, output} ->
    IO.puts("Scan progress: #{output}")

  {:scan_completed, ^ref, results} ->
    IO.puts("Scan completed with #{length(results)} findings")

  {:scan_error, ^ref, error} ->
    IO.puts("Scan error: #{inspect(error)}")

  {:scan_cancelled, ^ref} ->
    IO.puts("Scan was cancelled")
end

# Check status
{:ok, status} = BubbleEx.scan_status(ref)

# Cancel a scan if needed
:ok = BubbleEx.cancel_scan(ref)
```

## Querying Application Logs

BubbleEx provides functionality to query logs from your Bubble.io applications for monitoring, debugging, and analytics.

### Prerequisites

You need a valid Bubble session cookie to authenticate with the Bubble API. This can be obtained by logging into your Bubble account and extracting the session cookie from your browser.

### Basic Usage

```elixir
# Fetch logs for the last hour
{:ok, logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123..."
)

# Access the log entries
IO.inspect(logs.logs)
```

### Time Range Filtering

```elixir
# Fetch logs for the last 30 minutes
{after_time, before_time} = BubbleEx.Logs.time_range({:minutes, 30})
{:ok, logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123...",
  after: after_time,
  before: before_time
)

# Fetch logs for the last day
{after_time, before_time} = BubbleEx.Logs.time_range(:last_day)
{:ok, logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123...",
  after: after_time,
  before: before_time
)
```

### Filtering by Log Type

```elixir
# Fetch only error logs
{:ok, error_logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123...",
  tags: BubbleEx.Logs.preset_filter(:errors, "my-app")
)

# Fetch only workflow-related logs
{:ok, workflow_logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123...",
  tags: BubbleEx.Logs.preset_filter(:workflows, "my-app")
)

# Fetch API-related logs
{:ok, api_logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123...",
  tags: BubbleEx.Logs.preset_filter(:api, "my-app")
)
```

### Available Preset Filters

- `:errors` - Error and failure messages
- `:workflows` - Workflow execution logs
- `:api` - HTTP requests and API workflows
- `:database` - Database operations
- `:plugins` - Plugin console output and errors
- `:scheduled` - Scheduled task execution
- `:all` - All log types (default)

### Custom Filtering

```elixir
# Custom tag filtering
{:ok, custom_logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123...",
  tags: %{
    message: ["running event", "event completed"],
    appname: "my-app",
    app_version: "live"
  }
)
```

### Querying Different App Versions

```elixir
# Fetch logs from test version
{:ok, test_logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123...",
  app_version: "test"
)

# Fetch logs from development version
{:ok, dev_logs} = BubbleEx.fetch_logs("my-app",
  cookie: "bubble_session=abc123...",
  app_version: "development"
)
```

### Asynchronous Usage

For applications that need to query logs asynchronously or handle large volumes of log requests, here are some patterns:

#### Using Task for Async Log Fetching

```elixir
# Fetch logs asynchronously
task = Task.async(fn ->
  BubbleEx.fetch_logs("my-app",
    cookie: System.get_env("BUBBLE_COOKIE"),
    tags: BubbleEx.Logs.preset_filter(:errors, "my-app")
  )
end)

# Do other work...

# Get the result
case Task.await(task, 30_000) do
  {:ok, logs} ->
    IO.puts("Found #{length(logs.logs)} error logs")
  {:error, reason} ->
    IO.puts("Error fetching logs: #{inspect(reason)}")
end
```

#### Using GenServer for Periodic Log Monitoring

```elixir
defmodule MyApp.LogMonitor do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    app_id = Keyword.fetch!(opts, :app_id)
    cookie = Keyword.fetch!(opts, :cookie)
    interval = Keyword.get(opts, :interval, 60_000) # 1 minute

    schedule_check(interval)

    {:ok, %{app_id: app_id, cookie: cookie, interval: interval}}
  end

  def handle_info(:check_logs, state) do
    {after_time, before_time} = BubbleEx.Logs.time_range({:minutes, 5})

    case BubbleEx.fetch_logs(state.app_id,
           cookie: state.cookie,
           after: after_time,
           before: before_time,
           tags: BubbleEx.Logs.preset_filter(:errors, state.app_id)) do
      {:ok, %{logs: logs}} when length(logs) > 0 ->
        # Handle error logs - send alerts, store in database, etc.
        handle_error_logs(logs)
      {:ok, _} ->
        # No errors found
        :ok
      {:error, reason} ->
        # Log monitoring error
        Logger.error("Failed to fetch logs: #{inspect(reason)}")
    end

    schedule_check(state.interval)
    {:noreply, state}
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_logs, interval)
  end

  defp handle_error_logs(logs) do
    # Process error logs...
    Enum.each(logs, fn log ->
      Logger.warning("App error detected: #{inspect(log)}")
    end)
  end
end

# Start the monitor
{:ok, _pid} = MyApp.LogMonitor.start_link(
  app_id: "my-app",
  cookie: System.get_env("BUBBLE_COOKIE")
)
```

#### Batch Processing Multiple Apps

```elixir
defmodule MyApp.LogAggregator do
  def fetch_logs_for_apps(app_configs) do
    app_configs
    |> Task.async_stream(fn %{app_id: app_id, cookie: cookie} ->
      {after_time, before_time} = BubbleEx.Logs.time_range(:last_hour)

      case BubbleEx.fetch_logs(app_id,
             cookie: cookie,
             after: after_time,
             before: before_time) do
        {:ok, logs} -> {:ok, app_id, logs}
        {:error, reason} -> {:error, app_id, reason}
      end
    end, max_concurrency: 5, timeout: 30_000)
    |> Enum.to_list()
  end
end

# Usage
apps = [
  %{app_id: "app1", cookie: "cookie1"},
  %{app_id: "app2", cookie: "cookie2"},
  %{app_id: "app3", cookie: "cookie3"}
]

results = MyApp.LogAggregator.fetch_logs_for_apps(apps)

results
|> Enum.each(fn
  {:ok, {:ok, app_id, logs}} ->
    IO.puts("#{app_id}: #{length(logs.logs)} logs")
  {:ok, {:error, app_id, reason}} ->
    IO.puts("#{app_id}: Error - #{inspect(reason)}")
end)
```

### Performance Optimization

BubbleEx uses HTTP connection pooling for improved performance when making multiple log requests:

```elixir
# Configure connection pooling (optional)
config :bubble_ex,
  logs: [
    pool_max_connections: 20,  # Maximum concurrent connections
    pool_timeout: 30_000       # Pool timeout in milliseconds
  ]
```

The connection pool is automatically managed and reuses connections across requests, significantly improving performance for applications that make frequent log queries.

### Security Considerations

- Never log or expose session cookies in your application logs
- Store cookies securely as environment variables or in secure configuration
- Use proper error handling to avoid leaking authentication details
- Consider implementing cookie rotation for long-running applications
- When using async patterns, ensure proper timeout handling to avoid hanging processes

## Deep Search

BubbleEx provides powerful deep search functionality for traversing and searching through complex nested data structures, which is particularly useful when analyzing Bubble.io application data.

### Basic Usage

```elixir
# Search for a specific value in nested data
data = %{
  "user" => %{
    "name" => "John Doe",
    "email" => "john@example.com",
    "settings" => %{
      "theme" => "dark",
      "notifications" => ["email", "push"]
    }
  },
  "posts" => [
    %{"title" => "First Post", "content" => "Hello world"},
    %{"title" => "Second Post", "content" => "Another post"}
  ]
}

# Find all paths containing "email"
paths = BubbleEx.DeepSearch.find_all_paths(data, "email")
# Returns: [["user", "settings", "notifications", 0], ["user", "email"]]

# Find all paths containing "Post"
paths = BubbleEx.DeepSearch.find_all_paths(data, "Post")
# Returns: [["posts", 1, "title"], ["posts", 0, "title"]]
```

### Understanding Path Results

The returned paths are lists where:
- String elements represent map keys
- Integer elements represent list indices

**Note on `get_in/2` usage:** While paths containing only map keys work with `get_in/2`, paths with list indices do not due to Elixir's Access limitations. For list access, use manual traversal or `Enum.at/2`.

```elixir
# Map-only paths work with get_in
data = %{"users" => %{"admin" => %{"name" => "Alice"}}}
[path] = BubbleEx.DeepSearch.find_all_paths(data, "Alice")
value = get_in(data, path)
# Returns: "Alice"

# Paths with list indices require manual traversal
data = %{"items" => ["first", "second", "third"]}
[["items", 1]] = BubbleEx.DeepSearch.find_all_paths(data, "second")
value = data["items"] |> Enum.at(1)
# Returns: "second"
```

### Practical Examples with Bubble.io Data

```elixir
# Search for specific field IDs in Bubble app data
{:ok, app_data} = BubbleEx.fetch_bubble_app("myapp")
field_paths = BubbleEx.DeepSearch.find_all_paths(app_data, "_id_1234567890")

# Find all references to a specific user
user_refs = BubbleEx.DeepSearch.find_all_paths(app_data, "user_abc123")

# Locate API endpoints
api_paths = BubbleEx.DeepSearch.find_all_paths(app_data, "api/1.1/")

# Find database table references
table_paths = BubbleEx.DeepSearch.find_all_paths(app_data, "data_type_")
```

### Processing Search Results

```elixir
# Extract and process all matching values
data = fetch_complex_data()
paths = BubbleEx.DeepSearch.find_all_paths(data, "secret_")

# Get all the actual values
values = Enum.map(paths, fn path ->
  {path, get_in(data, path)}
end)

# Group paths by depth
grouped = Enum.group_by(paths, &length/1)

# Find top-level occurrences only
top_level = Enum.filter(paths, fn path -> length(path) == 1 end)
```

### Performance Considerations

- The function performs a complete traversal of the data structure
- For very large datasets, consider implementing pagination or streaming
- Results are returned in reverse order of discovery (deepest first)
- String matching is case-sensitive for performance
