# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added

- S1 frontend exporter: `BubbleEx.Frontend.normalize/2`, `export/3`,
  `export_payload/3`, `BubbleEx.export_frontend/3`, and
  `mix bubble.export_frontend`. Writes a portable HTML/CSS package with
  bindings, findings, and coverage for the modern responsive renderer.
  S1 lowers Page, Group (Fixed / Align to Parent / Row / Column), plain
  Text, public Image, decorative Shape, label-only Button, text-only
  resolved Link, and Text/Email/Password Input. Everything else is a
  dimension-preserving placeholder.

- Frozen-case fidelity gates (#30): `mix bubble.fidelity` and `mix test --only
  fidelity` render committed cases through the S1 exporter and compare them
  to frozen Bubble references (0 CSS-px geometry, byte-identical PNGs). PR
  CI runs the gate; live recapture is opt-in and never default.

- Frozen S1 Image case `bprkyexk` (#35): Stretch, Rescale, Zoom, and
  Adjust-element-height on one authorized page, with public image bytes
  hashed and rewritten by the exporter. This is case-correct, not S1
  slice-complete.

- Frozen S1 text-only Link case `bptaixqv` (#36): resolved external and
  internal destinations, new-tab + nofollow, wrapping, and literal disabled
  behavior on one authorized page. Internal Bubble page ids are rewritten to
  portable package paths.

- Frozen S1 Text/Password Input case `bpewigqu` (#37): empty Text placeholder
  paint and a benign masked Password literal on one authorized page. The
  exporter preserves Bubble's `content` field, emits exact native input types,
  and supplies placeholder-backed accessible names. This validates the static
  Text/Email/Password subset, not broader Input behavior.

- Frozen S1 normal/H4 Text case `bpcybc` (#38): explicit `normal` and `h4`
  paint, geometry, typography, fixed-width two-line wrapping, and exporter-owned
  `<p>` / `<h4>` semantics on one authorized page. Shared CSS neutralizes browser
  paragraph and heading defaults before authored typography is applied. An
  authorized full-suite live review found all five cases and 34 viewports
  byte-identical to their committed references, with exact tracked geometry and
  typography.

- Frozen static native controls case `bpqqfagk` (#32): fixed-height Multiline
  Input, literal checked/unchecked Checkboxes, static Dropdown, and static Radio
  Buttons.
  The normalized schema is now v2. Exported controls preserve resolved value,
  choices/default, placeholder, maxlength, checked/required/disabled state,
  labels, and native keyboard semantics. Fit-height multiline and dynamic
  checkbox/dropdown/radio variants remain dimension-preserving placeholders.
  The authorized two-viewport Bubble capture passes with zero geometry error
  and byte-identical Chromium 140 PNGs.

- API Connector v2 External API types are resolved into the universal database
  map and rendered deliberately by every registered schema encoder. Detailed
  rendering and app enrichment expose structured, artifact-scoped warnings.

- `BubbleEx.AppTree.generate/3` and `mix bubble.app_tree`: explode a
  `.bubble.json` export into a two-layer, agent-readable source tree
  (lossless split with round-trip guarantee + generated OUTLINE/WORKFLOWS/
  API/STYLES/SETTINGS/DBML views with honest coverage reporting).
- `BubbleEx.Db.Reader.parse/1` now also accepts the readable `.bubble.json`
  export shape (`display`/`fields`/`values`) in addition to the scraped
  `%d`/`%f3` shape.
- Added `BubbleEx.Secrets.Native`, a pure-Elixir offline secret-scanning adapter
  (regex + base64 + opt-in entropy, no live verification).

### Changed

- New Reader output uses `external_types: :preserve`, which may add by-value
  shapes to generated artifacts. Use `external_types: :legacy` during migration
  for pre-feature output, or `:opaque` for JSON/map containers without shape
  expansion. No schema is inferred from connector response samples.

## [0.3.0] - 2026-06-21

### Added

- Telemetry. BubbleEx now emits `:telemetry` span events for its major
  operations — see `BubbleEx.Telemetry` for the full contract:
  - `[:bubble_ex, :http, :request, :start | :stop | :exception]`
  - `[:bubble_ex, :apps, :fetch_app, :start | :stop | :exception]`
  - `[:bubble_ex, :secrets, :scan, :start | :stop | :exception]`
- `:finch` option / `config :bubble_ex, :finch` to run requests through a
  dedicated named Finch pool (default unchanged: Req's built-in pool).

### Changed

- `Apps.Parser.find_app_line/1` scans for the app marker instead of splitting the
  whole (multi-MB) response body, reducing peak memory on large bundles. Output
  is unchanged.

## [0.2.0] - 2026-06-20

Maturity refactor. **This is a breaking release** — the public surface was
reshaped around a single HTTP client and a single error type.

### Breaking Changes

- **All public functions now return `{:ok, result} | {:error, %BubbleEx.Error{}}`.**
  Errors are no longer bare atoms, English strings, `{:http_error, ...}` tuples,
  or leaked HTTP structs. Pattern-match on `error.kind` (a closed atom set).
- **Removed `BubbleEx.Meta`** (the cookie-authenticated "my apps" API) entirely.
- **Removed the legacy delegators on `BubbleEx.Apps`:** `get_dynamic_js/1`,
  `find_app_line/1`, `extract_json_string/1`, `get_app_json/1`,
  `get_plugins_from_payload/1`, `handle_get_latest_change/1`,
  `enrich_obj_endpoints/1`, `enrich_wf_endpoints/1`. Call the underlying modules
  directly (`BubbleEx.Apps.Parser`, `BubbleEx.Apps.Enricher`).
- **Renamed `BubbleEx.Apps.is_dedicated/2` → `BubbleEx.Apps.dedicated?/2`.**
- **Removed `BubbleEx.TrufflehogAdapter`.** Secret scanning is now pluggable via
  the `BubbleEx.Secrets` behaviour; the default adapter is
  `BubbleEx.Secrets.Trufflehog`. When the CLI is absent, scans return
  `{:error, %BubbleEx.Error{kind: :cli_missing}}` instead of raising.
- **Removed `BubbleEx.Utils`** (orphaned helpers, duplicate key-rename tables,
  duplicate validators, `get_page/2`).
- `BubbleEx.Db.Dbml.quote_special_chars?/1` (which returned a string) was renamed
  to `quote_identifier/1`; the other `Db.Reader`/`Db.Dbml` internals are now
  private.

### Added

- `BubbleEx.Error` — the single error type (`kind`, `message`, `context`).
- `BubbleEx.HTTP` — one Req-based client with retries, redirects, auth, and the
  high-level `fetch_page`/`fetch_json`/`post_json`/`check_redirect` helpers;
  `Req.Test`-stubbable.
- `BubbleEx.Secrets` behaviour + `BubbleEx.Secrets.Trufflehog` adapter.
- Real `config/*.exs` files backing `BubbleEx.Config`.
- A trustworthy, mostly-offline test suite (live tests tagged `:integration`).

### Fixed

- Double-retry of transient HTTP failures (Req's auto-retry layered under the
  explicit retry loop).
- `BubbleEx.Server` now runs scans under a `Task.Supervisor` instead of a raw
  `spawn` + manual monitor + "fake task struct"; the `nil`-key `Map.delete` bug
  is gone.
- Trufflehog command is built with `Port.open({:spawn_executable, ...}, args: ...)`
  instead of shell-string interpolation (no command-injection surface).

## [0.1.0]

- Initial release.
