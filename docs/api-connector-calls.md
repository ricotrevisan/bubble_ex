# API Connector calls (WTF-533)

A Bubble API Connector call used as an **action** ("Use as: Action") in a
backend or page workflow is lowered to a call of the generated Req client
(`<App>.ApiClients.<API>.<call>`, WTF-374), on the server. Calls used as
**data** (a data source, or inside an expression) are not lowered yet: see
"Not lowered yet".

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
| retries | **none for an action** (every workflow step), whatever its method. A GET Bubble uses as data (for the data calls to come) is retried at most twice, only on a refused connection, a 429 or a 503, waiting what `retry-after` asks but at most 5 s (`:max_retry_delay`) |
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

## Not lowered yet

* **Calls used as data** (a page's or an element's data source, a value
  in an expression): their reads stay residue (`docs/page-data.md`, "an
  API Connector type's field"). They need a page data source that calls
  the client when the page loads (and caches it per page), with the same
  secrets model; their parameters may read page values.
* **Calls whose client is not generated** stay `:api_connector_action`
  residue with the generator's reasons (`detail.reasons`: a public
  parameter in the URL's host (`:host_parameter`), OAuth and other
  authentications, file parameters, raw bodies, query strings in the URL,
  unresolved calls).
* **Defaults and "Allow blank"** of non-private parameters (above).
* **A field of a list of API values** (or through one, `Result of step N's
  items:first item's name`) does not compile yet; nor does an API value
  mixing typed structs and maps.

## Coverage

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
