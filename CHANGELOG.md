# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added

- S1 simple SliderInput (`type=range`) and static AutocompleteDropdown
  (`type=search` + `<datalist>`). Two-handle sliders and dynamic/Google
  search stay placeholders. Authorized page `bubbleex-i67-slider-search`
  is on `tiptap-plugin` Test; freeze is a follow-up.

- Frozen S1 PictureInput case `bpdimzwm` (`bubbleex-i65-picture-input`)

- S1 PictureInput lowering as `<input type="file" accept="image/*">`.
  Authorized page `bubbleex-i65-picture-input` is on `tiptap-plugin` Test.

- Frozen S1 numbers / datetime / FileInput case `bpoyzixi`
  (`bubbleex-i63-datetime-numbers-file`)

- S1 numbers-only Input, datetime DateInput, and FileInput lowering.
  Numbers use `inputmode=numeric`. Datetime stays `type=text` (no
  native picker). FileInput is `<input type="file">` with no upload.
  Authorized page `bubbleex-i63-datetime-numbers-file` is on
  `tiptap-plugin` Test. Google address autocomplete remains deferred
  (needs a live Google contract).

- Frozen S1 Address Input / DateInput case `bpizatjd`
  (`bubbleex-i61-address-dateinput`)

- S1 Address Input and DateInput lowering as `type=text` (no Google
  autocomplete, no native date-picker chrome). Authorized page
  `bubbleex-i61-address-dateinput` is on `tiptap-plugin` Test.

- Frozen S1 extra Input formats case `bpjehwxg`
  (`bubbleex-i59-input-formats`)

- S1 decimal / percent / currency / US phone / euro-date Input lowering
  as `type=text` with matching `inputmode`. Authorized page
  `bubbleex-i59-input-formats` is on `tiptap-plugin` Test; freeze is a
  follow-up.

- Frozen S1 date / integer Input case `bpqkcldq`
  (`bubbleex-i57-date-integer-input`)

- S1 date and integer Input lowering (`content_format` `date` / `integer`
  as `type=text`, integer `inputmode=numeric`). Authorized page
  `bubbleex-i57-date-integer-input` is on `tiptap-plugin` Test; freeze is a
  follow-up.

- Frozen S1 fit-height MultiLineInput case `bpuzekut`
  (`bubbleex-i55-fit-height-multiline`)

- S1 fit-height MultiLineInput lowering (`fit_height` + static content →
  `field-sizing: content`). Authorized page `bubbleex-i55-fit-height-multiline`
  is on `tiptap-plugin` Test; freeze is a follow-up.

- Frozen S1 icon Link case `bpaupfbj` (`bubbleex-i53-icon-link`)

- S1 icon / icon+label Link lowering for static Font Awesome 4 icons
  (`show_icon` or `link_type: icon`). Authorized page `bubbleex-i53-icon-link`
  is on `tiptap-plugin` Test; freeze is a follow-up.

- Literal newlines in Text become `<br>` so 404 boilerplate keeps its paragraph
  break. Native Input chrome uses `appearance: none`, white fill, and a 1px border.

- S1 icon / icon+label Button lowering for static Font Awesome 4 icons, with frozen
  case `bpiordvb` on `tiptap-plugin` Test (`bubbleex-i51-icon-button`).

- Theme tokens and default styles: export emits `:root` CSS variables from
  `settings.client_safe` color/font tokens and applies `default_styles` classes
  to elements that omit an explicit style (unstyled primary buttons, `--font_default`).

- Empty-page hydration: a page-specific fetch that returns layout properties but
  no `%el` (internal-link targets like `bubbleex-i36-target`) is treated as a
  hydrated empty page instead of failing the export.

- Frontend export falls back to `BubbleEx.Secrets.Native` when the default
  Trufflehog CLI is missing (`:cli_missing`), so `mix bubble.export_frontend`
  works without Trufflehog. An explicit non-Trufflehog adapter is unchanged.

- Frozen BBCode Text case `bpwipyqn` (#44): controlled `bubbleex-i44-bbcode-text`
  page on `tiptap-plugin` Test. Block BBCode (`[ul]/[ol]`) exports as a `div`
  with Bubble-like list/link CSS; `[b]`, `[url=https]` stay inline.

- Selected live-page hydration (#40): `BubbleEx.export_frontend/3` and
  `mix bubble.export_frontend` fetch each requested metadata-only page from the
  sanitized app origin, preserving `/version-test` and `/version-development`
  prefixes. Extra page fetches are deduplicated and capped at 20 by default;
  use `max_page_fetches:` or `--max-page-fetches` to override the bound.

- Button-to-link inference (#21): a label-only Button with exactly one
  unconditioned `ButtonClicked` workflow whose only action is a static
  `ChangePage` or `OpenURL` is exported as a semantic `<a>`. The original
  workflow payload is preserved on the node. Multi-action, conditioned,
  parameterized, disabled, icon, and `ListGoToPage` clicks stay buttons.

- S1 frontend exporter: `BubbleEx.Frontend.normalize/2`, `export/3`,
  `export_payload/3`, `BubbleEx.export_frontend/3`, and
  `mix bubble.export_frontend`. Writes a portable HTML/CSS package with
  bindings, findings, and coverage for the modern responsive renderer.
  S1 lowers Page, Group (Fixed / Align to Parent / Row / Column), plain
  Text, public Image, decorative Shape, label-only Button, text-only
  resolved Link, and Text/Email/Password Input. Everything else is a
  dimension-preserving placeholder.

- Authenticated/private-app frontend export (#33): HTTP Basic Auth can come
  from `BUBBLE_EX_FRONTEND_USERNAME` plus `BUBBLE_EX_FRONTEND_PASSWORD`, or
  URL userinfo; `BUBBLE_EX_FRONTEND_SESSION_COOKIE` imports an existing Bubble
  application-user session. Payload auth is HTTPS exact-origin scoped, and
  `--authenticated-assets` explicitly opts same-origin assets into auth.
  Credentials and sessions are never persisted. Login, session renewal,
  private workflow execution, and private-record fetching remain out of scope.

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
- Added the frozen Issue #42 complex-composition fidelity case with two selected
  pages, nested reusable expansion, local image/font/icon assets, a viewport
  Floating Group, portable navigation, and an explicit Repeating Group boundary.
  The gate now records bounded material pixel metrics rather than treating all
  PNG drift as an unqualified mismatch. A pinned Pixelmatch comparator excludes
  detected edge antialiasing from the gate while retaining raw pixel telemetry.
- Added `scripts/package_consumer_smoke.sh` and an Elixir 1.18.4 / OTP 28 CI lane
  to compile and execute the unpacked production package from a fresh project.

### Security

- Link destinations use a safe scheme allowlist. CSS values that can escape a
  declaration or fetch a remote URL are omitted with explicit findings.
- Cross-origin public assets must resolve to public HTTP(S) destinations. The
  validated address is pinned for the connection, and every redirect is
  revalidated. Failed or missing local assets never retain a remote HTML/network
  fallback.
- Secret-scan errors and frontend export errors redact raw token material.
  Trufflehog inputs now live in random private temporary directories instead of
  payload-derived paths. The fidelity harness uses Playwright 1.55.1, which fixes
  its browser download certificate-validation advisory.

### Changed

- Page hydration now merges page-bundle shared styles with the same deterministic
  precedence as reusable definitions. Reusable package directories are
  collision-safe, and legacy fixed-container placement dimensions remain
  authoritative during normalization.

- Frontend live-payload parsing now applies Bubble's data-only
  `Object.assign(..., JSON.parse(...))` page patches instead of exporting only
  the initial page metadata. Decoded `%nm` names, aliased text expressions,
  and common paint aliases are normalized through the existing payload seam.
  `collapse_when_hidden` is treated as behavior, not current visibility.
  Selected live metadata-only pages are hydrated from their page-specific URLs
  before one combined export. A requested page that remains metadata-only still
  fails closed instead of reporting empty 100% coverage.

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
