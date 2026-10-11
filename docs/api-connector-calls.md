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
| timeouts | 30 s to receive, 10 s to connect (per API in the configuration) |
| retries | GET and HEAD only, up to 2, on transport errors and transient statuses (408, 429, 500, 502, 503, 504); never a POST, PUT, PATCH or DELETE |
| redirects | not followed (an error) unless configured: see `<App>.ApiClients` |
| logging | the clients never log; a failed step logs the status or the error's kind, never a body, a header or a secret |

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

## Unverified Bubble behavior

* **A non-private parameter an action leaves empty.** Bubble may send the
  value set in the API Connector (its default) unless "Allow blank" is
  checked. Here an unset parameter is not sent (in a JSON body: `""` inside
  quotes, `null` outside): defaults are never copied from the export, as
  they may be credentials. Not replayed.
* **Parameter text in a body.** Bubble pastes a parameter's text into the
  body. Here a value inside quotes is a JSON string (escaped: a quote in it
  cannot break the body, which it can in Bubble), and outside quotes the
  JSON its text is (`3`, `true`), else a string.
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
  residue with the generator's reasons (`detail.reasons`: OAuth and other
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
| backend steps that are API Connector calls | 113 residue | 7 residue (their clients are not generated: 5 file parameters, 1 query string in the URL, 1 raw body), 106 lowered: 64 with every value compiled to IR, 35 generated whole |
| page steps that are API Connector calls | 30 residue | 0 `:api_connector_action`; 17 with every value compiled to IR, 1 generated whole |
| backend steps: native IR / generated whole | 1,758 / 1,210 | 1,822 / 1,245 |
| backend workflows: native IR / generated whole | 343 / 123 | 357 / 129 |
| page steps: native IR / generated whole | 2,863 / 2,570 | 2,880 / 2,571 |
| page workflows: native IR / generated whole | 1,315 / 923 | 1,318 / 923 |
| structural: generated subjects | 807 | 813 (`residue:api_connector_action` 40 → 2) |

What still stops the lowered calls is their values, not the calls: on
the backend, page data other than the current date and the app version
(`elixir:unbound_input:page_data`, 22 steps), fields of `:first item`
(12), uncompiled expressions (`expr_uncompiled:raw` and others, about
30), and "Result of step N" of a step whose result is still not typed (a
plugin action, a call whose API type the Model cannot read: 11); on pages,
inputs the page does not track (`unavailable_input`, 17) and the same
expression gaps (13). 28 calls' actions set a member no non-private
parameter of the call has (a private parameter, or one since removed):
not sent. Calls used as data (the 99 field reads of `docs/page-data.md`
and 13 data sources) are not lowered yet.
