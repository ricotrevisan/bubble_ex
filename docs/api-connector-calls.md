# API Connector calls (WTF-533)

A Bubble API Connector call used as an **action** ("Use as: Action") in a
backend or page workflow is lowered to a call of the generated Req client
(`<App>.ApiClients.<API>.<call>`, WTF-374), on the server. A call used as
**data** ("Get data from an external API", in a page's data source) is
page data, made with the same client by the page's LiveView: see "Calls
used as data".

```elixir
{:ok, model} = BubbleEx.Model.build(app)
{:ok, clients} = BubbleEx.Target.ApiClients.map(model)
# 1. Stack-neutral: an API Connector action is an `:api_call` step.
{:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
{:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
# 2. Bound to the clients (without `api_clients:` the step is residue).
{:ok, workflows} =
  BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Acme", api_clients: clients)

{:ok, pages} =
  BubbleEx.Target.Elixir.FrontendWorkflows.map(lowered, project,
    namespace: "Acme", frontend: frontend, backend: workflows, api_clients: clients)

# 3. Printed with the clients (render refuses workflows that call
#    clients it is not given).
{:ok, files} =
  BubbleEx.Target.Phoenix.render(project,
    name: "Acme", api_clients: clients, workflows: workflows, frontend_workflows: pages, ...)
```

## What the export says, and what is kept

An API (`settings.client_safe.apiconnector2.<API>`) has a shared
authentication (none, a private key in a header or in the URL, basic auth;
OAuth, JWT and custom tokens are residue) and shared headers and
parameters. Each call has a method, a URL with `[parameters]`, headers, a
JSON or form body with `<parameters>`, parameters (each private or not,
with a value), "Use as" (`publish_as`: action or data), "Include errors in
response and allow workflow actions to continue" (`wrap_error`) and the
response shape Bubble initialized (`types`: field IDs, response paths and
types).

The Model (`BubbleEx.Model.Connector`) keeps names, locations and the
`private` flag of parameters, a leak-safe request template (structure and
placeholders, `BubbleEx.Model.ConnectorRequest`), `wrap_errors` and the
response shape. It resolves every call's own return type as an API type
(`BubbleEx.Model.ExternalType`), besides those data fields store. **No
value that could be a credential is kept**: parameter values, header
values, URL user info and response samples are never read.

An action sets a call's parameters in members named after the parameter's
key: `headers_<key>`, `params_<key>` (query string and other parameters),
`url_params_<key>` and `body_params_<key>`. The lowering
(`BubbleEx.Workflows.Lowering.api_call/6`) keeps the non-private ones, by
the parameter's Bubble ID, as expressions. A member naming a private
parameter (or one since removed) is not sent, as in Bubble: a private
value is never a value of a step or a page. The step's condition and a
debugger breakpoint are the action's other members; anything else is
`:unsupported_option` residue.

## Semantics

| | Generated |
|-|-----------|
| where it runs | always on the server: a backend workflow's body, or a page workflow's step in its LiveView process (`BubbleWorkflows.api/2`, which the browser only triggers: no value of the call is sent to or from the browser). Calls Bubble runs in the browser run on the server too |
| parameters | the step's values of the call's non-private parameters, by the client's argument names; a thing is its Bubble ID, a date its text (UTC) |
| secrets | the API's key, basic auth, private headers and parameters, and every literal of the request that is not structure: environment variables only (below) |
| result | "Result of step N" is the response as the client decoded it: a typed struct when a data field stores the API type (`Ash.TypedStruct`, `External.*`), else a typed map (Bubble field ID => the value at its response path, cast to the field's type: text, number, yes/no; a date from ISO 8601 text; other types as decoded). An expression reading a field compiles to that read (`BubbleEx.Target.Elixir`) |
| a non-2xx response | the step fails and the workflow stops, as in Bubble: `{:api_call, {:status, status}}` |
| with "Include errors in response" | the step succeeds whatever the status: on a 2xx `returned_an_error` is no, otherwise yes with `error`'s `status_code`, `status_message` (the HTTP reason phrase) and `body` (the response text), Bubble's own result fields |
| a transport error (timeout, refused connection) | the step fails, with or without "Include errors in response" |
| timeouts | 30 s to receive, 10 s to connect, and a 30 s deadline for the whole call, retries and redirects included (`:deadline`; then `:deadline_exceeded`), per API in the configuration |
| retries | **none for an action** (every workflow step), whatever its method. A GET Bubble uses as data is retried only on a refused connection, a 429 or a 503, waiting what `retry-after` asks but at most `:max_retry_delay`; on a page's data path at most once, at most 1 s (below) |
| response size | at most 10 MB read (`:max_body_bytes`), decompressed included: the clients ask for no compression, and inflate a gzip or deflate body only up to the limit (`{:body_too_large, limit}`); a truncated body, more than one encoding (in one `content-encoding` header or several: the app needs Req 0.7.4, which keeps them all) or another encoding is an error (`{:decode, :content_encoding}`) |
| addresses | the host is Bubble's or the owner's (an environment variable), never a step's or a page's value: a call whose host or port has a public parameter, or whose `Host` header is a public parameter, is residue (`:host_parameter`; any port placeholder is `:dynamic_port`). Before each request and redirect the host is resolved and refused (`{:blocked_address, _}`) when an address is loopback, private, link-local (cloud metadata), carrier-grade NAT, multicast or reserved (documentation and benchmarking ranges, IPv4-mapped and -translated IPv6, local-use NAT64, Teredo, site-local, and 6to4 or well-known NAT64 of a refused IPv4 address), unless the owner configured it (the `:base_url`'s origin, e.g. a development `localhost`, or `allow_private_addresses: true`). The request then connects to the address checked (DNS rebinding cannot move it), the host kept in the `Host` header, TLS's SNI and certificate verification. Each pinned host gets a Finch instance, and each address it resolves to a pool in it, none ever stopped: bounded by the hosts Bubble and the owner define (redirects to other hosts are refused) and the addresses they resolve to. A `plug: nil` or `plug: false` is no plug: the request is checked |
| path segments | percent-encoded; a value that is exactly `.` or `..` is `%2E` / `%2E%2E`, never a step up the path |
| redirects | not followed (an error) unless configured, and never to another host (`{:redirect_refused, status, location}`): see `<App>.ApiClients` |
| logging | the clients never log (`retry_log_level: false`); a failed step logs the status or the error's kind, never a body, a header or a secret |
| rate limiting | none, as in Bubble |

## Secrets

* **Names, never values.** Each secret is an environment variable named
  from the API's and the call's generated names under `BUBBLE_API_`
  (`BUBBLE_API_PAYMENTS_API_KEY`, `BUBBLE_API_PAYMENTS_CREATE_CHARGE_SIGNING`;
  the full table is in `BubbleEx.Target.ApiClients`). Nothing of Bubble's
  values is generated, printed or tested: generated request-shape tests use
  stubs derived from the names (`env-...`).
* **One place they come from.** The generated `config/runtime.exs` reads
  them at boot (`config :app, App.ApiClients, env: %{name => System.get_env(name)}`);
  the clients read only that (`Application.fetch_env/2`), never the system
  environment directly, never the export. Tests pass their own (`env:`).
* **Fail closed.** A call whose variables are not set (or empty) is
  refused before anything is sent, with a typed error,
  `<App>.ApiClients.MissingEnvError`, naming them. A workflow step that
  makes it is **refused**: the workflow stops (`{:api_env_missing,
  %{step, names}}`) and an error naming the variables is logged; on a page
  the browser gets the "This action isn't available yet." notice.
* **The owner's list.** `.env.example` names every variable (no values),
  the README says how to set them, and `mix bubble.api_env` lists the ones
  that are not set (exit status 1 when any is: usable as a boot check).
* **Private parameters never reach the browser**: they are not values of a
  step, the page never holds them, and the call runs on the server.
* **Secrets go only where the owner points them.** A call whose host has a
  public parameter (`https://[tenant].example.com`, or `https://[host]/`)
  is not generated: a step or a page could send the API's key to any host
  (SSRF). A private parameter in the host is the owner's environment
  variable. A port placeholder (`https://api.example.com:[port]/`) is
  never generated (`:dynamic_port`, and `:host_parameter` when public).
  The address check above is defence in depth; the request connects to
  the address it checked rather than resolving the host again (WTF-534),
  so a DNS answer that changes in between (rebinding) cannot move it.
* **What can still carry them.** With "Include errors in response", an
  API that echoes a request's secrets in its error body puts them in the
  step's result, as in Bubble. Finch's telemetry events carry each
  request's headers: do not attach handlers that record them.
* **Renamed in WTF-533.** The variables gained the `BUBBLE_API_` prefix
  (`.wtf/api_clients.json` version 2); `mix bubble.api_env` prints each
  missing one with its old name (`was PAYMENTS_API_KEY`).

## Calls used as data

"Get data from an external API" (`GetDataFromAPI`, with its `provider`
`apiconnector2.<API>.<call>` and the parameter values it sets in members
named like an action's) is an expression source:
`BubbleEx.Expression.Ast.ApiData`, typed as the call's response
(`BubbleEx.Model.call_result_type/3`: its API type, or a list of it when
Bubble initialized a list) and compiled to the IR `:api_data` with the
values of the call's **non-private** parameters only. A member naming a
private parameter is not a value, as for an action.

On a page it is **page data** (`docs/page-data.md`), never anything else:

| | Generated |
|-|-----------|
| where it runs | on the server, **off the page's LiveView process**: the page's data loader (`<Web>.BubbleData.api/5`) returns what the page has (a cached response, the result of a call that just ended, else the last value shown, empty at first) and starts the call in a task (`<App>.ApiClients.Data`); when it ends, the page reads again only the sources reading that call. A slow API never blocks a mount, a render or an event. The browser never sees the call, its secrets or its response, only what the page shows |
| typed reads | a group's or repeating group's source of the call's type; `:first item`, `:item #`, `:count` and other list operators over a list response; "Current cell's" and "Parent group's" fields (`_api_c2_...`), a list field included (`tags:count`); a field over a list of API values maps over its items |
| parameters | page values (inputs, custom states, URL, cells, the current user...), compiled like any page value; private ones only from the environment |
| reloads | a source reading the call is in the page's dependency graph: its parameters' inputs are its `inputs`, so changing one reads again only what reads it (narrowed reloads, WTF-475) |
| deduplication | the same call with the same values is made **once per read of the page's data** (`once/3`), however many sources (and surfaces) read it, and not again while it is in flight |
| in a repeating group's cell | a call whose values are the same in every cell is made once; one whose values read the cell (or a per-cell scope) would run once per cell and is `:page_data_in_cell` residue (`detail.kind` `"api_data"`), like a search that cannot be batched |
| a failure | the call's value is empty (nil): a non-2xx response (without "Include errors in response"), a timeout or the data deadline (`:deadline_exceeded`), a body that does not decode or is too large, a task that crashed (`:crashed`). Logged once per call with the status or the error's kind only; no page notice; never cached. With "Include errors in response" an error is the call's value instead, its `error`'s `body` (the response text) included: **that body can reach the page** if the page shows it, as in Bubble |
| secrets not set | the call is never sent (`MissingEnvError`) and reads as empty; the log names the missing variables, never a value |
| developer markers | with `config :app, :bubble_dev_markers, true` (dev only) an element outside a cell whose own source reads a failed call has `data-bubble-api-error` with the same text (`<Web>.Bubble.api_error/3`) |
| data access | page data needs the workflows' `data_access: true` opt-in: with it off, a page makes no call |
| retries and limits | at most **1 retry** (a refused connection, a 429 or a 503), waiting at most **1 s**; an **8 s** deadline (under the LiveView's 10 s join timeout); responses of at most **1 MB** |

### Cost model

A data call is a request to someone else's API, paid with the owner's
credentials whoever opens the page. The defaults
(`<App>.ApiClients.Data`, all in `config :app, <App>.ApiClients.Data`):

| | default | key |
|-|---------|-----|
| a response shared by every page (mounts, change notifications, other users, other pages) | 30 s | `:ttl` |
| calls never shared | those with "Include errors in response", and any `{module, function}` listed | `:no_cache` |
| calls a page makes (a token bucket); past it the page keeps what it has and logs once, then reads again when a token is back | 10 per 10 s | `:budget` |
| calls a page has in flight | 4 | `:max_concurrency` |
| calls in flight per API (client module), all pages together | 20 | `:max_in_flight` |
| a data call's deadline, retries, retry delay, response size | 8 s, 1, 1 s, 1 MB | `:deadline`, `:max_retries`, `:max_retry_delay`, `:max_body_bytes` |
| cached responses kept (past it, the expired ones go, then all) | 10,000 | `:max_entries` |

So a keystroke burst costs at most the budget, a mount within the TTL
costs nothing, and a change notification does not call again within it
(failures are not cached: the next read calls again, within the budget).

### Privacy

**An API response bypasses Ash and its policies.** A data call is made
with the owner's credentials (the environment's keys) for any actor who
can open the page, an anonymous visitor included, as in Bubble: what it
returns is shown to them, whatever privacy rules the app's data types
have. Only the `data_access` opt-in gates it: with it off no page makes
a call; with it on, nothing else does.
Do not point a data call at an API returning what not every visitor of
the page may see.

A call whose client is not generated (or a render without
`api_clients:`) leaves its source `:api_connector_data` residue
(`detail.call`); `Target.Phoenix.render/2` refuses page data reading the
clients without them. An `:api_data` value anywhere else (a text binding,
a condition, a workflow's value) is not compiled yet
(`elixir:an API Connector call outside page data`).

Bubble's registry may key a type without `api.apiconnector2.` (its own
`ret_value` form, `<API>.<call>.<type>`): the Model resolves both.

## Unverified Bubble behavior

* **A non-private parameter an action leaves empty.** Bubble may send the
  value set in the API Connector (its default) unless "Allow blank" is
  checked. Here an unset parameter is not sent (in a JSON body: `""` inside
  quotes, `null` outside): defaults are never copied from the export, as
  they may be credentials. Not replayed.
* **Parameter text in a body.** Bubble pastes a parameter's text into the
  body. Here a value inside quotes is a JSON string (escaped: a quote in it
  cannot break the body, which it can in Bubble). Outside quotes, a text
  that is a JSON number, yes/no or null is that value; any other text, an
  object or array included (`{"$ne": null}`), is a JSON string; a list
  value (an expression of a list type) is a JSON array.
* **Redirects.** Whether Bubble follows a redirect, and with which
  headers, is not known: here none is followed unless the owner
  configures it.
* **"Include errors in response".** The result's fields (`returned_an_error`,
  `error`'s `status_code`, `status_message`, `body`) are read from the
  types registry Bubble initializes for such calls; `status_message` is
  the HTTP reason phrase here, and a transport error still fails the step.
  Not replayed.
* **Retries and timeouts.** Bubble's own timeouts and retries are not
  known; the defaults above are this target's.
* **Dates in parameters** are sent as text in UTC, as the backend
  converts them (replay 2026-10-07 measured URL parameters and workflow
  responses only).
* **A response field typed `date`** is read from ISO 8601 text; a number
  (a Unix time) is not converted.
* **Caching of calls used as data.** Bubble is reported to cache
  identical data calls; for how long, across which users and pages, is
  not known. Here a response is shared by every page for 30 s (`:ttl`),
  never one with "Include errors in response", never a failure. Not
  replayed.
* **A failed data call.** Bubble shows the element empty and, as far as
  known, no notice; here the value is nil, logged, with a developer
  marker. What Bubble shows of a partial or non-JSON body is not known.
* **A data call per cell.** Bubble may run a call whose values read the
  cell once per cell; here such a source is residue (`page_data_in_cell`).

## Not lowered yet

* **Calls used as data outside a page's data sources** (a text binding,
  a condition, a workflow's value, a backend workflow): not compiled
  (above). Nor a call whose values read a repeating group's cell.
* **Calls whose client is not generated** stay `:api_connector_action`
  residue with the generator's reasons (`detail.reasons`: a public
  parameter in the URL's host (`:host_parameter`), OAuth and other
  authentications, file parameters, raw bodies, query strings in the URL,
  unresolved calls).
* **Defaults and "Allow blank"** of non-private parameters (above).
* **An API value mixing typed structs and maps** does not compile yet.

## Coverage

### Private fixture app (test version), 2026-10-14, calls used as data

Counts only (the snapshots under `test/support/*/counts/`). Two causes
move them: the Model now reads the API types Bubble keys without
`api.apiconnector2.` (most of the app's registries; before, 5 opaque
types, now 307 resolved with 2,956 fields, `typed_responses` 0 to 106),
and "Get data from an external API" is lowered as page data. With the
types read, 12 data fields that held a `json_value` hold typed structs
now, and 11 `call_metadata_inconsistent` warnings appear: a type
defined by one call's registry and returned by another (`ret_value`
differs), read as defined. The loader writes such a field leniently
(`Load.Convert`'s `{:external, parts}`: unknown members dropped, a
mistyped one empty with a `:load` issue, a value that is not an object
empty): a row never fails on it. Checked with the encoding only; the
private app's rows are not exported here, so no row was loaded.

| | before | after |
|-|--------|-------|
| expressions: unresolved accessors / of them on an API type | 1,342 / 227 | 1,123 / 8 |
| expressions: untyped "Result of step N" | 348 | 76 |
| expressions compiled to IR / to Elixir (of 19,716) | 17,376 / 16,256 | 17,798 / 16,668 |
| page data sources reading a data call (13 `GetDataFromAPI` nodes in 8 expressions; the rest are text values and workflow values) | 3 residue | 1 wired; 2 `:api_connector_data` (their calls have a public host parameter, no client) |
| page data sources wired | 2,832 | 2,839 |
| page steps / workflows native IR | 2,866 / 1,316 | 2,912 / 1,327 |
| page steps / workflows generated whole | 2,571 / 923 | 2,610 / 927 |
| backend steps / workflows generated whole | 1,235 / 127 | 1,315 / 132 |
| structural: generated subjects | 811 | 820 (`residue:api_connector_action` 18 to 31: workflows whose values now compile stop at a call with no client instead) |

Data calls in text bindings and workflow values (5 expressions) stay
`elixir:an API Connector call outside page data`.

### Private fixture app (test version), 2026-10-11

Counts only (`test/support/target/workflows/counts/private-app.json`,
`test/support/target/phoenix/counts/private-app.frontend_workflows.json`,
`test/support/verify/counts/structural.private-app.json`).

| | before | after |
|-|--------|-------|
| API Connector calls with a generated client | 167 of 172 | 120 (47 have a public parameter in their URL's host: `:host_parameter`, below) |
| backend steps that are API Connector calls | 113 residue | 35 residue (28 call a host-parameter API, 7 other calls not generated: file parameters, a URL query string, a raw body), 78 lowered: 46 with every value compiled to IR, 25 generated whole |
| page steps that are API Connector calls | 30 residue | 24 residue (their calls are not generated, mostly host parameters), 6 lowered: 3 with every value compiled to IR, 1 generated whole |
| backend steps: native IR / generated whole | 1,758 / 1,210 | 1,804 / 1,235 |
| backend workflows: native IR / generated whole | 343 / 123 | 352 / 127 |
| page steps: native IR / generated whole | 2,863 / 2,570 | 2,866 / 2,571 |
| page workflows: native IR / generated whole | 1,315 / 923 | 1,316 / 923 |
| structural: generated subjects | 807 | 811 (`residue:api_connector_action` 40 → 18) |

The 47 host-parameter calls put an account- or tenant-specific value in
the host (`https://[tenant].example.com/...`) from a non-private
parameter. They lower once the owner makes that parameter private in
Bubble (its value is then an environment variable), or edits the
generated code; until then a workflow calling one stays residue.

What still stops the lowered calls is their values, not the calls: on
the backend, page data other than the current date and the app version
(`elixir:unbound_input:page_data`), fields of `:first item`, uncompiled
expressions (`expr_uncompiled:raw` and others) and "Result of step N" of
a step whose result is still not typed (a plugin action, a call whose
API type the Model cannot read); on pages, inputs the page does not
track (`unavailable_input`) and the same expression gaps. 28 calls' actions set a member no non-private
parameter of the call has (a private parameter, or one since removed):
not sent. Calls used as data (the 99 field reads of `docs/page-data.md`
and 13 data sources) are not lowered yet.
