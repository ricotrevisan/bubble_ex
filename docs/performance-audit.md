# Memory and performance audit

## Scope and limits

Audited checkout `1c0fafb` (0.3.0), focusing on dynamic-bundle parsing and payload lifecycle. All measurements use synthetic local data through `mix run`; no live apps were fetched. The reporting application's deployed revision, API path, payload sizes, concurrency and memory profile were not supplied. Findings below are reproducible library risks, not a proven diagnosis of that application's incident.

No production source files were changed. Existing `fix/scan-memory` work was inspected read-only, not merged. Commit `6c04ccc` is in HEAD; `9a34f18` and `63f282a` are not. Branch overlap: `9a34f18` directly addresses finding 5 (enables bounded body reception, makes size/encoding rejections non-retryable, drops buffered overflow instead of flattening) and the decoder change measured in finding 2. It does not touch Server, Logs, error retention, or metadata detachment, so findings 1, 3, and 4 plus the Logs gap remain uncovered by that branch.

## Highest-priority findings

### 1. Small returned metadata can retain the entire decoded JSON buffer

**Confirmed retention; high priority for `fetch_app` callers that keep results.**

- `lib/bubble_ex/apps/parser.ex:294`: `Jason.decode/1` uses the default `strings: :reference`.
- `lib/bubble_ex/apps.ex:331`: metadata fields are taken directly from the parsed map.
- `lib/bubble_ex/apps/enricher.ex:51-58`: description is also returned without detaching its binary.
- `lib/bubble_ex/http.ex:517`: HTTP JSON decode has the same default, including when it discards an envelope.

An offline reproduction kept a **100-byte title referencing 5,000,192 bytes** (`:binary.referenced_byte_size/1`). `include_payload: false` does not detach these strings. Keeping one such title per independently decoded result can retain hundreds of otherwise-discardable buffers. Not every short string retains a buffer: BEAM may copy small strings, so realistic field lengths matter.

**Recommendation:** copy the small strings at long-lived result boundaries, especially metadata-only returns. Consider an explicit `strings: :copy` decode policy where consumers keep arbitrary subsets. Benchmark it rather than switching every decoder blindly: copying all strings can increase allocation when the whole decoded map is needed. Test retained byte size, not just output equality.

### 2. Escape-dense JS literals still create a large temporary list

**Measured; high priority for parsing peaks.**

`lib/bubble_ex/apps/parser.ex:378-450` accumulates spans and escapes in a list until the complete literal has been decoded. HEAD has already removed the older per-character implementation, but memory still scales with escape count. The no-match finalizer also flattens the accumulated prefix before appending the final span.

The parser-only change in existing commit `9a34f18` uses an owned binary accumulator. Compared under a renamed module in the current Mix environment, using an identical 7,988,959-byte synthetic bundle with 100,000 records:

| Metric | HEAD | Existing candidate |
|---|---:|---:|
| Median parse time, 3 runs | 1,741 ms | 672 ms |
| Sampled peak worker-process memory | 180.4 MiB | 40.0 MiB |

That is about **61% less parse time and 78% less sampled process memory** for this fixture. Worker memory was sampled every 1 ms; it excludes off-heap reference-counted binary contents and is not a total-RSS or exact-peak figure. Independent whole-VM runs, including fixture setup and compilation, reported high-water RSS of 712 MiB vs 508 MiB. Those figures are corroborating observations, not isolated parser allocations.

Current parser tests: **13 passed**. The same tests against the renamed candidate: **13 passed**. This checks existing behavior, not all possible JS literals. Validate sparse escapes, dense escapes, Unicode/surrogates, malformed literals and Object.assign patches before release. Do not assume the whole branch is ready from this parser-only comparison.

### 3. Error values keep full response/JSON bodies alive

**Confirmed retention; high priority if callers store failures or telemetry metadata.**

- `lib/bubble_ex/apps/parser.ex:294-310` embeds `%Jason.DecodeError{}` in the returned reason, including its full `data` field.
- `lib/bubble_ex/http.ex:517-533` also keeps the JSON decode exception.
- `lib/bubble_ex/error.ex:88-90` stores the complete HTTP error body in context.

The offline malformed-JSON reproduction returned an error retaining **5,000,020 bytes** of source JSON. A small error count can consume substantial memory if results, mailboxes or telemetry handlers retain these values. Frontend.Fetch strips parser error details, so that wrapper does not expose the same retained exception.

**Recommendation:** return bounded structured diagnostics (phase, position, original byte count and safe reason). If snippets are necessary, truncate, redact and copy them; a sub-binary slice alone can still retain the original. Treat error-payload shape changes as API changes.

### 4. Completed asynchronous scans retain their original payloads indefinitely

**Offline-confirmed with a no-op adapter; high priority for `BubbleEx.Server` users.** Five completed no-op scans with 1,000,000-byte payloads left `scans=5, tasks=0` and 5,000,000 payload bytes still held in Server state.

`lib/bubble_ex/server.ex:158-197` stores the full payload in `state.scans`. Completion, failure, crash and cancellation update status but never remove the payload or expire the record. `scan_status` only needs its `_id`. A long-lived server therefore retains all historical payloads regardless of parser improvements. It also starts a task for every accepted call without a concurrency bound; moving the map through the server and into a task copies ordinary heap terms across processes (large binaries can be shared).

**Recommendation:** retain only the payload ID/status metadata, clear terminal task references, and define bounded history/TTL. Add bounded admission/backpressure with an explicit queue policy. Test each terminal state and caller death using a no-op local adapter. Preserve the ability to retrieve status without preserving the app map.

### 5. The high-level page-fetch body limit is checked after full buffering

**Static confirmation; high priority for predictable upper bounds.**

- `lib/bubble_ex/http.ex:287-304` checks `max_body_length` after `Req.run` returns.
- `lib/bubble_ex/http.ex:547-563` does not pass `bounded_body: true` through high-level helpers.
- `lib/bubble_ex/frontend/fetch.ex:535-545` uses the same post-buffering limit.
- `config/config.exs` defaults to 100,000,000 bytes, which is not a decoded-heap budget.

The low-level HTTP module already has a bounded receiver, but the app/page fetch paths do not enable it (`lib/bubble_ex/http.ex:310-317` gates it behind `bounded_body?: true`, which `build_http_options` never sets). A too-large response is therefore received before rejection. `lib/bubble_ex/http.ex:609-613` treats every HTTP error as retryable, including `:body_too_large`, allowing repeated oversized downloads (default two retries).

**Related uncovered gap: log queries have no body budget at all.** `lib/bubble_ex/logs.ex:333-355` forwards only timeouts to the low-level POST; neither `max_body_length` nor `bounded_body` applies, and the response is fully materialized into JSON and a list (`:368-397`). A large log window or concurrent log consumers can allocate without any configured cap. This differs from finding 5: the 100 MB app cap does not apply to logs.

**Recommendation:** reject oversized responses during reception and do not retry permanent size-limit errors. Handle content encoding deliberately: the existing bounded path requests identity encoding and rejects encoded responses, so enabling it changes compatibility. An encoded-wire limit alone would not bound decompressed data. Avoid flattening previously collected chunks on the rejection path. Test chunked and compressed responses offline.

## Secondary schema and frontend opportunities

These matter only when callers use the corresponding schema/export APIs. Measurements below are synthetic median wall times from three warm runs; they demonstrate scaling, not a production latency forecast.

| Priority / area | Evidence | Recommendation |
|---|---|---|
| High: API-type registry decoding | `db/reader/external_types.ex:86-106,197-241` checks conflicts by decoding all call registries for each newly referenced type, then decodes the selected registry again. A one-registry case with 100 / 200 / 400 distinct referenced definitions took 11.4 / 52.0 / 237.2 ms. | Decode once per resolve call and index definitions/conflicts. Preserve malformed-registry and duplicate-definition semantics. Use a call-local cache, not an unbounded global one. |
| High: relationship lookup | `db/reader.ex:182-202` runs `Enum.find(columns)` per relationship, O(R × C). Whole `Reader.parse` with 1,000 / 2,000 / 4,000 types referencing the last sorted type took 42.3 / 204.1 / 992.7 ms. | Build a primary-key lookup once, preserving custom-type `_id` versus option-set `display` semantics. |
| High allocation opportunity: empty credential-taint check | `frontend/export.ex:55-65` serializes the whole model and flattens output bodies before checking even an empty taint list. `normalize.ex:180-186` keeps the original payload in that model. Static confirmation; no isolated timing. | Fast-path the empty-taint case without changing the nonempty-taint check or any other export validation. |
| Medium: diagnostic accumulation | `frontend/normalize.ex:229,251,299` repeatedly appends to growing diagnostic lists. Wide placeholder-rich trees can copy O(N²) list cells. All-native trees with no diagnostics do not have that cost. | Accumulate reversed chunks and reverse once, preserving diagnostic order. |
| Medium: reusable lookup and repeated coverage walks | `frontend/export.ex:471-474,747-771,807-810` linearly searches reusables, eagerly even for non-instance nodes, and expands pages again for overall coverage. | Guard by node kind, index definitions, and reuse page counts. Preserve lookup precedence, cycle checks and overall coverage semantics. |
| Medium: nested HTML formatting | `frontend/export/html.ex:491-503,676-690` repeatedly flattens and indents descendant output. Synthetic group chains of depth 50 / 100 / 200 took 0.60 / 1.26 / 4.82 ms. | Render with explicit depth and keep iodata until the write boundary. Cost is depth/output-dependent, not quadratic for every tree. |
| Medium: whole-export residency | `frontend/export.ex:269-301` materializes all entries before staging. Result keeps the model, including source payload (`normalize.ex:180-186`), even though model.json strips that payload. | Consider an optional compact result and staged rendering that preserves validation before publication. The raw map is retained/shared, not necessarily deep-copied within a process. |

Lower-priority static opportunities: AppTree appends growing view lists (`app_tree.ex:94-124`) and builds the element-name index twice (`app_tree/splitter.ex:22`, `app_tree.ex:92`). DeepSearch already uses reversed paths and prepended results; its eager `Enum.with_index` is a small allocation opportunity, not a likely first fix.

The secondary scaling harness is `/tmp/bubble_ex_audit_bench.exs`. No schema or renderer replacements were implemented or benchmarked.

## Measurement and rollout guidance

- Establish the deployed library SHA/version and actual entry point first. “Hundreds of pages” could mean repeated `fetch_app` calls, frontend hydration, or asynchronous secret scans; these have different lifecycles.
- Collect input byte count, escape density, parse latency, worker memory, VM binary memory, RSS, active worker count, mailbox length and retained result count. Do not record payload bodies or credentials.
- Include log-query consumers in memory sampling; they run without a byte budget today.
- Distinguish rising post-GC retained memory from temporary peaks and allocator high-water RSS. RSS remaining high alone does not prove a live-data leak.
- Bound caller concurrency and consume results incrementally. Short-lived parse workers help reclaim temporary heaps, but do not solve binaries retained by returned metadata or stored server payloads.
- Start with the decoder, metadata detachment and bounded error values. Fix Server retention if that API is in use. Then enforce HTTP/resource budgets and measure the full workload before tuning secondary traversals.

## Local evidence

Temporary harnesses and outputs live in `/tmp/bubble-ex-perf-audit/` (not permanent project assets):

- `mix run --no-start /tmp/bubble-ex-perf-audit/retention.exs`
- `mix run --no-start /tmp/bubble-ex-perf-audit/parser_isolated.exs`
- `mix test test/bubble_ex/apps/parser_test.exs test/characterization/parser_characterization_test.exs`
- `MIX_ENV=test mix run --no-start /tmp/bubble-ex-perf-audit/candidate_tests.exs`

The candidate module is a renamed copy of `9a34f18:lib/bubble_ex/apps/parser.ex`. No checkout/branch changes were needed. Production traffic and full frontend export were not benchmarked as part of these parser measurements.

## Final test check

The default `mix test` suite completed: **6 doctests, 668 tests, 0 failures, 37 excluded**. Integration and fidelity exclusions remain in effect. This is a baseline test result; no production fixes were applied.

---

# Production investigation: bubbleio.wtf (bubble_wtf)

Investigated September 17, 2026 (UTC), read-only. Sources: Coolify application 23 and deployment history; application PostgreSQL Oban metadata; Docker image, environment whitelist, state and resource settings; Axiom `hetzner` archive. No workloads were triggered, no containers started, and no production settings changed.

## Coverage and evidence limits

Requested window: September 3–17. The archive contains other services throughout that window, but this application's UUID records start September 14 at 14:15. Searching earlier container names containing `wtf` or the application UUID prefix returned no older app records. This is a coverage gap, not proof that no earlier incidents occurred.

No historical memory time series or kernel OOM record was obtained. `sudo -n journalctl -k` failed because a password is required. **OOM is a plausible explanation, not a confirmed diagnosis.** A current container's `OOMKilled=false` cannot establish the cause of deaths of removed containers.

## Deployment correction

| Period | Consumer revision | BubbleEx pin | Relevant behavior |
|---|---|---|---|
| September 14–16, before isolation deployment | `833a33f` | `6c04ccc` | Web and scan work share a BEAM; configured bubble queue concurrency 3. Older span decoder; no effective streaming download budget in this path. |
| Current deployment | `9efa0cb`, `fix/scan-worker-isolation` | `63f282a` | Includes September 16 parser/bounded-download/artifact fixes. Production defaults to web-only role. |

Coolify first recorded a finished deployment of `9efa0cb` at September 16 16:42; later deployments finished September 16 17:14 and September 17 17:13. The current Docker image matches `9efa0cb`. Local consumer main is older than production. The fixes are included through an explicit dependency pin even though the library branch is not merged into its main branch.

## What the logs establish

- **17 exact `Killed` records:** one September 14, fourteen September 15, two September 16.
- **16 same-container kill/restart pairs**, with the endpoint restarting roughly 5–7 seconds later. The remaining September 15 02:19 event belongs to the old container during deployment replacement; do not classify that event as a proven resource failure.
- September 15 10:14:41: an Oban leader check timed out after 5 seconds. At 10:15:07 the process was killed; the endpoint returned at 10:15:12. This supports runtime distress but does not identify whether parsing, an external process, GC, or host-wide contention caused it.
- September 15 logged **25,091 version-scan starts** and **17,273 scanner starts**, peaking around 2,600 version starts/hour. These are starts/attempts, not unique applications or completed scans.
- September 15 logged **922 missing temporary-file errors**; September 16 logged one. Concurrent versions of the same app used the same `/tmp/<app-id>.json` on the old pin. Closely spaced same-ID starts followed by missing-file/zero-byte results match that race. Deployed private random artifact directories fix path sharing. Do not interpret those empty results as successful checks.
- There were **1,927 dynamic-JS discovery errors** over the observed interval (1,406 September 14; 521 September 15). Oban also records DNS, TLS and timeout failures. These are distinct from memory failure, although retries add work.
- No explicit heap-limit or OOM error was found in the sampled app logs or matching Oban error entries. Initial substring matches for `heap`/`killed` were app names, not resource errors, and were discarded.

Oban history showed 41,103 rows whose last attempted_at falls in the requested interval. This is not the total number of attempts. Stored error arrays on those rows occupied approximately 4.9 MB by pg_column_size, with a maximum of 1,295 bytes; this measures database storage, not expanded runtime allocations. A whole-process kill need not leave an Oban error. Historical retry/rescue of individual killed jobs was not traced end-to-end.

## Current operational state

At inspection:

- One healthy application container, current restart count 0, memory about 29 MiB.
- No running separate scan-worker container found.
- No WTF_ROLE override. Deployed production source defaults to `:web`; `ScanRuntime` removes `:bubble` and `:security_scan` queues from this role. One Oban peer and no executing scan jobs corroborate this inference; runtime config was not evaluated.
- **5,987 available jobs on `:bubble`, none executing.** Latest scan attempt September 16 08:21:15; last completed scan's attempt began around 08:21:09.
- No container memory/CPU limit on the web container. The worker compose example's 1536 MiB/1 CPU limits are not deployed resource limits.

**Current health is not a production-load validation of the fix. Scanning stopped before the new revision began consuming any observed scan jobs.** The evidence explains why jobs wait: no scan-role consumer. It does not establish why operations chose not to deploy that role, or that this was accidental. The daily scan scheduler itself uses the removed `:bubble` queue.

## Which library audit findings actually apply

1. **Parser allocation and download budgets:** directly relevant to the historical version-scan path. The existing measured decoder improvement and bounded reception are already in production's dependency pin, but have not been validated under this historical scan workload. Byte limits are not BEAM term-memory limits.
2. **BubbleEx.Server historical payload retention:** not the incident path. Consumer submits work through Oban and calls the library synchronously; it does not submit scans to BubbleEx.Server.
3. **Full payload lifetime:** the security pipeline deliberately needs it through artifact creation, persistence, upload and contact extraction. It returns compact Version/status data, not the full payload. No permanent in-memory full-payload cache was found in that path. Metadata binary detachment remains useful for DBML/schema outputs, but should not be called the proven scan incident cause.
4. **ExternalTypes registry decoding and Reader relationship lookups:** apply to web schema/DBML tools, not standard security scans. Those tools can still run in the web role. Stored-payload reads also buffer S3 objects without a byte cap.
5. **BubbleEx.Logs and frontend export findings:** no callsites in this consumer's scan path. Deprioritize them for this incident.
6. **Temporary-file race:** confirmed historical correctness defect, fixed in deployed pin. Separate from the unconfirmed memory-kill mechanism.

## Conclusion and safe next step

The strongest explanation is resource pressure during combined web/scan batch processing on the old revision, potentially amplified by parser allocation, concurrent full-payload lifetimes, external scanner processes and retries. Logs alone cannot assign peak memory to a particular stage or prove kernel OOM.

There are two separate questions: historical kills, and a currently unconsumed queue. Deploying a worker addresses the latter but does not by itself prove the former fixed.

Before re-enabling scheduled/bulk processing, obtain explicit operational approval and verify the intended scan scope. For resource validation, use a separate resource-limited worker with deterministic synthetic or approved captured inputs, while automatic bulk consumption remains disabled. Measure per-stage latency, BEAM process/binary memory, container RSS and exit reason. Capture kernel/cgroup OOM counters where available. Exercise parser success, malformed/oversized input and timeout behavior without triggering external scans. Only after this validation should operators consider controlled production resumption.

A per-process heap guard is an additional option, not a complete memory boundary: it does not reliably bound off-heap binary storage or external subprocess memory. Container limits and host headroom remain necessary. For this incident, prioritize verification of already-deployed fixes and isolation over unrelated frontend micro-optimizations.

## Status refresh (2026-09-21)

Re-checked production state on September 21; corrections to the September 17 snapshot above:

- `fix/scan-worker-isolation` is **merged to `main`**. Production now runs `main` at `4949cc1` (deployed September 21), including PR #100 (release fixes and "frugal isolated scan scheduling") and PR #101 (Bubble ownership bundle verification). The repository also records the historical Axiom scheduler-gap/restart evidence (commit `0a1c28c`).
- The app container is healthy with explicit `WTF_ROLE=web`. **Still no scan-worker container exists** (only a Sept-16 rollback image in `Created` state), and **zero `bubble` jobs have completed since September 17**.
- The backlog grew from 5,987 to **13,628 available** `bubble` jobs (~1,900/day of scheduler-enqueued work piling up unconsumed).

The library audit (HEAD `1c0fafb`) is unchanged and still valid. The recommended next step is unchanged in substance: validate the merged scan fixes in an isolated, resource-limited worker on a small scoped batch before any bulk resume — and curate the 13,628-job backlog (dedupe by app, drop stale entries) so resumption drains a meaningful queue rather than amplifying duplicates.

## Validation run (2026-09-22) — PASS

With explicit approval, the documented `scan_worker` compose topology ran against the real queue for ~22 minutes (05:41:39–06:03:44 UTC), then stopped per the runbook. Image `4949cc1` (same as web), concurrency 1, caps 1.5 GiB RAM / 1 CPU / 256 pids, `restart: "no"`, no HTTP.

| Metric | Result |
|---|---|
| Job attempts / scan starts | 309 / 309 |
| Completed | +221 (554,246 → 554,467) |
| Cancelled (permanent rejects) | +80, led by 52× HTTP 403 private apps; rest 400/401/missing-header |
| Retryable (transient) | +2 |
| Oversize-budget cancellations | 5 — the new budget path cancelled them permanently instead of retrying or ballooning |
| Worker memory | 346 MiB → **peak 1.085 GiB (72 % of cap)**; cap held; no OOM; no restarts |
| Shutdown | Graceful SIGTERM, exit 0, in-flight job returned to queue |
| Host headroom | min 3,417 MB available; swap untouched by worker (memswap pinned) |
| Web impact | None — healthy throughout, 0 restarts |
| Temp-file races (Sept 15: 922) | **0** — private artifact directories held |
| Crashes in window | 1 `ArgumentError` inside `Wtf.Bubble.Version.scan` (app-side, caught by Oban; worker unaffected) |

Interpretation: the merged fixes survived real production workloads, including five oversized payloads and a peak at 72 % of the memory cap. Failures observed were the expected permanent-reject categories, not resource failures. Throughput at concurrency 1 was ~14 attempts/min, so draining the remaining ~13,300 available jobs would take roughly 16 hours of continuous running (rough estimate).

Limits: one bounded window at concurrency 1; sustained multi-hour behavior (fragmentation, accumulation) and worst-case payloads beyond the observed 1.085 GiB peak remain untested. The worker was left stopped; sustained drain and any backlog curation remain explicit operator decisions (the runbook excludes job deletion from rollout).

## Curation + sustained drain (2026-09-23)

With explicit approval, both remaining steps were executed:

1. **Backlog curation:** 5,714 `available` jobs deleted (5,366 AppScan + 348 VersionScan) for 5,368 apps whose latest attempt since Sept 1 was a permanent reject (403/401/404/400/not-a-bubble-app). Exactly matched the dry-run prediction. Self-healing: the daily scheduler re-enqueues stale apps, so any misjudged pruning recurs at the next 02:00 UTC slot. First deletion attempt used a `USING` cross-join that hit the 120 s statement timeout and rolled back cleanly (no partial state); the retry materialized the dead-app set into a temp table and committed the two deletes separately. Log: `/home/rico/scan-validate/curation.log`.
2. **Sustained drain:** `scan_worker` restarted on the curated queue (~15,134 available) with a host-side watchdog (`/home/rico/scan-validate/watchdog.sh`, PID-verified, survives disconnect) sampling every 5 min for 24 h and auto-stopping the worker on: worker OOM/exit, worker RSS ≥ 1.45 GiB, host headroom < 800 MB, or web health degradation/restart. No auto-restart (per runbook). Throughput at start ≈ 16 jobs/min.

Manual stop: `cd /home/rico/scan-validate && BUBBLE_WTF_IMAGE=<image> WTF_ENV_FILE=/home/rico/scan-validate/worker.env docker compose -p bubble-wtf-scans -f scan-worker.compose.yml stop scan-worker`. Monitoring: `/home/rico/scan-validate/drain-samples.log`. Watchdog covers 24 h; if the queue outlives it, the worker continues unmonitored and the watchdog can be relaunched.

## Evidence artifacts

Private temporary query inputs/results: `/tmp/bubble-wtf-log-investigation/`. Queries include `daily`, `symptoms`, `killed`, `scan-rate`, `scan-errors`, `archive-availability`; deployment, state and Oban summaries were saved alongside them. Raw logs were not added to the repository. The full 1Password response was deleted after authentication; no credentials are included in this report.
