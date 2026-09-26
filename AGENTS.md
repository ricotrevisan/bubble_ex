# Project

## Project Overview

BubbleEx is an Elixir library for analyzing and reverse engineering Bubble.io applications. It provides utilities to:
- Scan and validate Bubble.io apps
- Extract database structures and generate DBML diagrams
- Scan for exposed secrets using Trufflehog
- Query application logs for monitoring/debugging
- Analyze plugins, contributors, and app configurations

## Essential Commands

### Development
- `mix compile` - Compile the project
- `mix test` - Run all tests
- `mix test test/path/to/test.exs` - Run specific test file
- `mix deps.get` - Install dependencies
- `mix deps.update` - Update dependencies

### Testing
Tests are organized by module under `test/` directory. Use `mix test --trace` for detailed test output.

## Architecture Overview

The codebase follows a modular architecture with clear separation of concerns:

### Core Modules
- **BubbleEx** - Main public API interface
- **BubbleEx.Error** - The single error struct returned everywhere: `%BubbleEx.Error{kind, message, context}`
- **BubbleEx.HTTP** - The one HTTP client (Req-based). Owns retries, redirects, auth, domain/bubble-id extraction, and the high-level `fetch_page`/`fetch_json`/`post_json`/`check_redirect` helpers. `Req.Test`-stubbable for offline tests.
- **BubbleEx.Apps** - App analysis orchestration layer with sub-modules:
  - `Apps.Parser` - Data parsing and JSON extraction
  - `Apps.Validator` - Input validation and sanitization
  - `Apps.Enricher` - Data enhancement and transformation
- **BubbleEx.Db** - Table view of the Model (`Db.Reader`, a projection of `BubbleEx.Model`; it parses nothing itself, test-enforced) and schema encoders behind the `Db.Encoder` behaviour: `Db.Dbml` (DBML) and `Db.Sql.Postgres` (PostgreSQL DDL). New targets (SQLite, Convex) register in `Db.Encoder`. Ash is not an encoder: see `BubbleEx.Target.Ash`.
- **BubbleEx.Expression** - Typed, stack-neutral Bubble expression AST (both key forms), raw nodes + diagnostics for unmodeled pieces, source re-emission and canonical hashing
- **BubbleEx.Expression.Typing / Compiler** - Types expression ASTs from the Model and the element tree (`Expression.Tree`, `Expression.Env`) and compiles them to the stack-neutral `Expression.IR`; `Expression.Sites` finds every page, reusable and workflow expression with its context. Targets consume the IR: `Target.Ash.Expressions` (filters as `%Target.Ash.Expr{}` data, printed by `Target.Ash.Source.expr/1`; privacy rules and searches) and `Target.Elixir` (value expressions as source). `Target.CompileReport` counts what compiles
- **BubbleEx.Privacy** - Data-type privacy rules (conditions as expression ASTs, permissions, per-field visibility)
- **BubbleEx.Model** - Typed, stack-neutral model of an app's data (data types, fields with content types, built-in fields, option sets with stable keys, API Connector types with cycle cuts, privacy rules), keyed by Bubble IDs with no target-language names; built from app JSON (it owns API Connector groups/calls and type resolution, `Model.External.Resolver`; `Model.ConnectorReader` reads call names in both key forms, URL hosts and header/parameter names and `private` flags, never values, query strings or paths) and `Privacy`, which types rule conditions against the Model's pre-privacy schema. Nothing outside `lib/bubble_ex/model` and `lib/bubble_ex/privacy` reads data-model members (test-enforced by `Db.OneInterpretationTest`). Target stacks map from it
- **BubbleEx.Target.Ash** - Maps the Model to `%Target.Ash.Project{}` (plain structs describing Ash resources, attributes, relationships, enums, typed structs, diagnostics and the per-app name map; no Ash dependency). `Target.Ash.Naming` owns Ash names (WTF-339); `Target.Ash.Decisions` applies owner decisions from `Decision.applicable/2` (cut 1: `refine_number_type`, `derive_from_related` as calculations, `rename` overrides; `project.applied`). `Target.Ash.Source` only prints a Project (xref-tested: no dependency on the Model or Reader); `Target.Ash.MatrixTests` (WTF-383, V3) prints ExUnit privacy-matrix tests for a `privacy: :unverified` Project from a `Verify.Matrix` (or the decoded `.wtf/verification` files): the seed in the Ecto sandbox with Bubble IDs as primary keys, actors via the generated `load_actor/1`, keyed `:read`, `:search` and visible fields per scenario against the expected recording (a Bubble one when given, else the model's), writing observations that `MatrixTests.results/3` turns into `Verify.Result`s; `scripts/ash_compile_check.sh` compiles its output against pinned Ash and runs those tests
- **BubbleEx.Index** - Deterministic symbol and reference index keyed by stable Bubble IDs (reads/writes per field, privacy-rule references, workflow call graph with cycles, execution class, invocation modes); a disposable derived cache built from `Workflows`, `Expression` and the `Model` (data types, fields, option sets, API Connector groups, privacy rules; pass `model:` to build the Model once)
- **BubbleEx.Findings** - Deterministic model-refinement analyzers over the index that emit `BubbleEx.Finding`s (kind and category registry in `Finding.Kinds`): evidence, a stack-neutral proposal, confidence, a stable ID, a `proposal_sha256` and a `basis_sha256` (content of its subject and evidence symbols, via `Index.subject_sha256/2`); separate from diagnostics
- **BubbleEx.Plan** - Stack-neutral migration task graph (WTF-366) from the Model, Index, normalized Frontend and `Decision.applicable/2`: generator nodes, one task per surface and backend folder with workflows as auto-closing subtasks, cycles as one task (SCC), acceptance/data/replay/delivery/cutover tasks, typed dependencies (cycle-safe, deterministic order), abstract criteria (`Plan.Criteria`), per-task `source_sha256` over its subgraph (covered symbols' semantic digests with `Plan.Content` keyed HMAC digests of raw definitions, data-model values and API calls; residue; `decisions_sha256` incl. decision records' states; the content algorithm and key ID), a `symbols` table (128-bit) and counts-only `coverage`; `Plan.diff/2` (`Plan.Diff`, WTF-367) classifies tasks unchanged/changed/added/removed, diffs covered symbols by ID and propagates `needs_reverify` along non-ordering edges (not `generate`/`early`) and to parents, never touching owned code. `Plan.Residue` says what a generator cannot lower (uncompiled expressions, plugins, placeholders, unsupported actions/events, styles); canonical JSON is `.wtf/plan.json`
- **BubbleEx.Decision** - Stack-neutral, append-only owner decision records (kinds `finding`, `rename`, `parity_exception`; a parity exception's params are `scope`, `checks` (the `Verify.Check` names it excuses), `bubble_behavior`, `chosen_behavior`) with a strict versioned JSON codec, the `modify` parameter whitelist per transform (`Decision.Params`), `resolve/3` (states active/stale/orphaned/superseded/expired, `Decision.Resolved`), `applicable/2` (`Decision.Applied`) and `decisions_sha256/1` (generation inputs only)
- **BubbleEx.Verify** - Stack-neutral verification formats (WTF-381, V1 of WTF-358): `Verify.Seed` (synthetic records and personas; emails must use reserved domains), `Verify.Scenario` (persona, subject Bubble IDs, ops and what each observes), `Verify.Recording` (observations with oracle `bubble` (a `wtfreplay…` branch of a Bubble app ID, checked by `Verify.Replay`) or `model`; masks; staleness hashes) and `Verify.Result` (per-check status with the status rules of `Verify.Check`: privacy/data/auth differences only through the owner's decisions, agent quarantine ≤ 7 days from the first quarantine for behaviour checks, no self-declared owner waivers, structural never; `decision` = key + `proposal_sha256`). A decoded result never counts by itself: `Result.evaluate/3` links its decision against `Decision.resolve/3` (author, relevance, hashes), requires `app:` and evidence for every non-structural check, never counts `skipped`, trusts only listed reviewers and the cited complete recording (or, for L4 data/auth, the export hash), and says whether it passes and is Bubble-verified (`model` never is). Finding decisions explain only the checks and diff ops their kind maps to (`Verify.Check.explains?/3`) and only diffs within their subject; parity exceptions excuse only their named `checks`. `Verify.Value` holds canonical WTF-338 values (tagged JSON, numbers as floats, dates as ms, `json` for JsonValue), `Verify.Mask` masks nondeterministic parts, `Verify.Staleness` compares pinned hashes (scenario, source, seed, recording, `decisions_sha256`). Strict versioned codecs, canonical JSON. `Verify.Interpreter` (WTF-382, V2) evaluates privacy rules (through the expression IR) over seed data for a persona (visible, visible fields, searchable), with every unverified Bubble semantic a named flag of `Interpreter.Assumptions` (incl. `defaults_applied_at_creation`: an omitted field reads as its Model default; `nil` is explicitly empty; matrix seeds write defaults out and keep explicit empties as `null`) (default: the compiler's fail-safe reading) and each verdict listing the flags it depends on; unsupported rules make verdicts `:unknown`. `Verify.Matrix` synthesizes personas, seeds (`Matrix.Personas`, `Matrix.Solver`), `privacy_read` scenarios and `model`-oracle recordings plus a coverage report: rules solved, rules observable (mutation coverage, `Matrix.Coverage`) and per-flag dependent checks (`result/4` compares a subject's observations with them). The interpreter shares the expression compiler with the Ash target, so its Ash cross-check does not test the compiler; the hand-authored expectation tables do. No replay driver yet
- **BubbleEx.Logs** - Log querying and filtering functionality
- **BubbleEx.Server** - Asynchronous scan processing (GenServer on top of `Task.Supervisor`)
- **BubbleEx.Frontend** - Modern-responsive frontend export: normalize a decoded
  payload, then write a portable HTML/CSS package (`pages/`, `reusables/`,
  hashed `assets/`, bindings/findings/coverage, `MANIFEST.json`). S1 native
  slice only; other kinds are dimension-preserving placeholders. Separate from
  `BubbleEx.AppTree`. Frozen-case fidelity is `BubbleEx.Frontend.Fidelity` /
  `mix bubble.fidelity` (Playwright 1.55, Chromium 140); default `mix test`
  excludes `:fidelity`.
- **BubbleEx.Secrets** - Pluggable secret-scanning behaviour; `Secrets.Trufflehog` is the default adapter

### Key Dependencies
- **Req** - HTTP client for external requests
- **Jason** - JSON encoding/decoding
- **Floki** - HTML parsing for web scraping
- **Trufflehog CLI** - Optional external tool for the default secrets adapter (graceful `:cli_missing` error when absent)

## Important Implementation Details

### Error Handling Pattern
Every public function returns `{:ok, result} | {:error, %BubbleEx.Error{}}`. Never `raise` for control flow, never leak HTTP structs as error reasons. `kind` is a closed atom set (see `BubbleEx.Error`). Use `with` to chain fallible operations.

### Configuration
App/logs configuration lives in `config/config.exs` and is read through `BubbleEx.Config`. There are no hardcoded duplicate defaults.

### JSON Parsing Strategy
`Apps.Parser` extracts the app JSON from the dynamic JS bundle with a single-path, principled decoder (handles JS string escapes, `\xHH`, `\u{...}`, and UTF-16 surrogate pairs). Pure-module output is pinned by characterization tests in `test/characterization/`.

### Async Processing
Secret scanning can run asynchronously through `BubbleEx.Server`, which runs each scan in a supervised `Task` and streams progress messages to the caller. The scanner adapter is injectable (`start_link(adapter: ...)` or app config), which is how it is tested offline.

### Test Structure
- Unit tests for individual modules under `test/bubble_ex/`
- Integration tests in `test/integration_test.exs`
- Test fixtures and samples in `test/support/`

## Development Notes

### Adding New Features
1. Follow the established module structure and naming conventions
2. Add comprehensive `@spec` type annotations for public functions
3. Implement consistent error handling patterns
4. Include comprehensive tests with edge cases
5. Update documentation and examples

### Working with External APIs
- Bubble.io apps are accessed via predictable URL patterns
- HTTP operations should include proper timeout handling
- Rate limiting may be required for bulk operations
- Authentication may be needed for private apps

### Performance Considerations
- Connection pooling is configured for log queries
- JSON parsing includes optimizations for typical app sizes
- Large payloads are handled but may require streaming for extreme cases

<!-- usage-rules-start -->
<!-- usage-rules-header -->
# Usage Rules

**IMPORTANT**: Consult these usage rules early and often when working with the packages listed below.
Before attempting to use any of these packages or to discover if you should use them, review their
usage rules to understand the correct patterns, conventions, and best practices.
<!-- usage-rules-header-end -->

<!-- usage_rules-start -->
## usage_rules usage
_A dev tool for Elixir projects to gather LLM usage rules from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->

## Agent skills

### Issue tracker

GitHub Issues on `ricotrevisan/bubble_ex` via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default roles: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` at the repo root and ADRs in `docs/adr/`. See `docs/agents/domain.md`.

