# BubbleEx

BubbleEx is the domain of inspecting authorized Bubble.io applications and translating their exposed application data into useful structural, security, and operational information.

## Access and identity

**Authorized app**:
A Bubble app that the operator owns or has explicit permission to inspect.
_Avoid_: Target, victim app

**Bubble app**:
An application built and hosted on Bubble.io that can be inspected through its public or authenticated surfaces.
_Avoid_: Project, website

**Bubble ID**:
The identifier Bubble assigns to an app and exposes in Bubble URLs and application data.
_Avoid_: App ID, app name, slug

**App URL**:
A URL through which a Bubble app is reachable, either on a Bubble-owned domain or a custom domain.
_Avoid_: Bubble ID, endpoint

**App version**:
A separately accessible version of a Bubble app, such as live, test, or development.
_Avoid_: Release, deployment, environment

**Dedicated instance**:
A Bubble hosting environment reserved for dedicated capacity rather than shared Bubble hosting.
_Avoid_: Dedicated app, private app

**Bubble session**:
An authenticated Bubble browser session represented by a session cookie and used to access protected Bubble data such as application logs.
_Avoid_: Login, API key

## Application structure

**App payload**:
The structured application definition exposed through a Bubble app's generated assets. It can contain the app's metadata, data model, plugins, workflows, and other configuration.
_Avoid_: Page HTML, HTTP response, app attributes

**Dynamic bundle**:
The generated JavaScript asset that contains a Bubble app's serialized app payload.
_Avoid_: App payload, source code

**API endpoint**:
A Bubble app route that exposes metadata, application data, or a workflow operation through Bubble's API surface.
_Avoid_: App URL, web page

**Object endpoint**:
An API endpoint that exposes records belonging to one Bubble data type.
_Avoid_: Metadata endpoint, workflow endpoint

**Workflow endpoint**:
An API endpoint that invokes an API workflow defined by a Bubble app.
_Avoid_: Object endpoint, page workflow

## Data model

**Data schema**:
The normalized description of a Bubble app's data types, fields, and relationships.
_Avoid_: Database, app payload, DB map

**Data type**:
A Bubble-defined record shape whose instances hold application data.
_Avoid_: Table, model, object

**Option set**:
A Bubble-defined finite collection of named choices that can be referenced by app data.
_Avoid_: Enum, data type

**API data type**:
A record shape inferred from data supplied by an external API rather than defined as an app data type.
_Avoid_: Data type, endpoint

**Field**:
A named value belonging to a data type, option set, or API data type.
_Avoid_: Column, property, attribute

**Relationship**:
A typed connection between data types inferred from a field that references another type.
_Avoid_: Association, foreign key

**Model**:
The typed, stack-neutral description of one app version's data (`BubbleEx.Model`): data types, their fields and built-in fields, option sets, API Connector types and privacy rules, each field with its content type. It records what Bubble has, keyed by Bubble IDs; display names are attributes, and deleted definitions are kept and flagged. Target stacks map from it and own every target-language name.
_Avoid_: Schema, Ash model, normalized model

**Ash project**:
The Ash version of a Model as plain data (`BubbleEx.Target.Ash.Project`): resources, attributes, relationships, enums, typed structs and diagnostics, derived by `BubbleEx.Target.Ash.map/3`. Renderers only print it.
_Avoid_: Schema, generated code

**Name map**:
The per-app record of which target name each Bubble ID was given, locked at first generation so caption edits in Bubble do not rename code.
_Avoid_: Naming option, alias table

**Content type**:
The Bubble type of a field's value in the model: a scalar, file reference, structured value, a reference to a data type, option set or API type (resolved or not), or an opaque value kept verbatim. Stated in Bubble's terms, never a target's.
_Avoid_: Column type, Ash type

**Database diagram**:
A DBML representation of an app's data schema, including its data types, fields, and relationships.
_Avoid_: Data schema, payload

**Privacy rule**:
A data type's condition-scoped grant of view, search, attachment, auto-binding and per-field visibility permissions. The `everyone` rule applies when no other rule matches.
_Avoid_: Policy, RLS rule, permission

**Expression AST**:
The typed, stack-neutral tree of a Bubble expression (sources, field chains, operators). It describes Bubble semantics only; target stacks compile from it.
_Avoid_: Rendered text, binding, Ash expression

**Expression IR**:
The compiled, stack-neutral form of a typed expression AST (`BubbleEx.Expression.IR`): a small closed vocabulary (comparisons, boolean operators, field paths, list membership, context inputs, …) with Bubble semantics and Bubble IDs. Target stacks compile it to their own code, or report a diagnostic.
_Avoid_: Ash expression, compiled code, AST

**Context input**:
A value an expression reads from where it runs rather than from data: an element's state, a parent group's or cell's thing, a page's thing, a workflow parameter or a previous step's result. Typed from the element tree and workflow; a target binds it (an argument, an assign).
_Avoid_: Scope, variable, binding

**Diagnostic**:
BubbleEx's own report that it could not read, parse, model or render part of an app faithfully (`BubbleEx.Diagnostic`). It has a registered code, a severity (how much the owner should care), an outcome (the data was preserved, degraded or unresolved), a stage, a subject of Bubble IDs and a JSON pointer into the source. It disappears as the tool improves; it is not a statement about the app. In expressions, the unmodeled source is always kept verbatim in a raw node.
_Avoid_: Error, model finding, warning

**Symbol index**:
A derived, disposable lookup of every symbol (data type, field, option, page, element, workflow, action, API call, privacy rule) in one app version and the reference edges between them, keyed by Bubble IDs only. It answers "who reads or writes this field" by lookup rather than search.
_Avoid_: Database, model, search index

**Symbol**:
One named definition in the symbol index, identified by its kind and the Bubble IDs that locate it (e.g. a field by its data type and field ID). Display names are attributes, never identity.
_Avoid_: Node, entity, name

**Reference**:
A directed edge from one symbol to another that it reads, writes, calls, types or grants access to.
_Avoid_: Dependency (the inverse view), link, relationship (reserved for data-schema relationships)

**Model finding**:
A proposed improvement to an app's data model, found by a deterministic analyzer from the symbol index (`BubbleEx.Finding`), e.g. a denormalized sort field that could be derived. It has a registered kind and category (a *decision* for the owner, or a performance *hint*), a subject of Bubble IDs, evidence, a stack-neutral proposal, a confidence, a stable ID and a proposal hash that changes when the proposal does. Unlike a diagnostic it is a statement about the app, not about the tool.
_Avoid_: Diagnostic, secret finding, recommendation

**Execution class**:
Where a workflow's actions run: client only, server backed, or mixed.
_Avoid_: Workflow type, backend/frontend

## Ecosystem

**Plugin**:
A Bubble extension that contributes reusable elements, actions, or capabilities to Bubble apps.
_Avoid_: Package, dependency, integration

**Contributor**:
A person or organization identified by Bubble as the maker of a plugin.
_Avoid_: App contributor, collaborator, user

## Security and operations

**Secret scan**:
An inspection of an app payload for values that may grant access to external systems or protected data.
_Avoid_: App scan, vulnerability scan

**Secret finding**:
A value reported by a secret scan together with its detector, location, encoding, confidence, and verification status.
_Avoid_: Confirmed secret, vulnerability

**Verified secret finding**:
A secret finding whose credential validity has been confirmed against the relevant external service.
_Avoid_: High-confidence finding

**Application log**:
A Bubble-generated record of application activity, including workflow execution, API traffic, database operations, scheduled tasks, and plugin output.
_Avoid_: Audit log, server log

**Log filter**:
A set of criteria that selects application logs by message category, app, app version, or time range.
_Avoid_: Search, query

## Frontend export

**Normalized frontend model**:
The versioned, serializable description of one app version's pages, reusable definitions, styles, and source references produced by a pure payload-to-model transformation.
_Avoid_: App payload, page HTML, DOM

**Normalization diagnostic**:
A problem recorded while building the normalized frontend model, such as an unsupported element. Distinct from a secret finding.
_Avoid_: Finding, error

**Binding**:
A lossless record of an unresolved expression, condition, workflow, custom state, API action, or plugin slot. Bindings stay on their element node; the bindings manifest is a derived index.
_Avoid_: Placeholder, expression AST

**Export finding**:
An export-time diagnostic keyed back to a normalized reference. Severity is blocking, warning, or info. A leaked credential is blocking and fails the export.
_Avoid_: Secret finding (unless wrapping one), normalization diagnostic

**Coverage**:
Per-page and overall counts of resolved versus unresolved bindings and native versus placeholder elements.
_Avoid_: Correctness score, quality gate

**Exporter ID**:
A deterministic identity for a normalized node within one app version, derived from app-version identity, entity kind, map key, and source path.
_Avoid_: Bubble ID, CSS class

**Frontend export package**:
The on-disk portable unit of HTML, CSS, hashed public assets, the normalized model, bindings, export findings, coverage, and MANIFEST.
_Avoid_: App tree, page HTML file

**Placeholder element**:
A dimension-preserving stand-in for an unsupported, plugin, or out-of-slice node, accompanied by an export finding and binding.
_Avoid_: Unsupported error, skipped node

**Frozen case**:
A parity-tested page whose committed Bubble references are the only thing we call visually correct. Case-correct means that case passed the fidelity gates; an app export is never “correct.”
_Avoid_: Screenshot test, visual regression suite, golden file


**Browser capture**:
Private rendered DOM/resource input for one anonymous URL at a declared viewport,
locale, DPR, and browser version. It is separate from the normalized app-data
model and has not passed the publication credential gate.

**Browser snapshot package**:
An inert HTML/CSS/resource export of a browser capture, with local assets and
capture provenance. It retains the observed initial appearance; it does not
reconstruct responsive behavior or Bubble workflows. Snapshot findings describe
capture/resource omissions rather than unresolved app-data bindings.

**Paired snapshot benchmark**:
An immutable browser capture and its independently measured DOM/PNG reference,
locked before export. Passing describes the named page, viewport, browser state,
and fixed checks; it is not a claim of complete application correctness. The
historical app-data frozen cases remain separate.
