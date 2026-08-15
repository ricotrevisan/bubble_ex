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

**Database diagram**:
A DBML representation of an app's data schema, including its data types, fields, and relationships.
_Avoid_: Data schema, payload

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

**Finding**:
A value reported by a secret scan together with its detector, location, encoding, confidence, and verification status.
_Avoid_: Confirmed secret, vulnerability

**Verified finding**:
A finding whose credential validity has been confirmed against the relevant external service.
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
A problem recorded while building the normalized frontend model, such as an unsupported element. Distinct from a secret-scan finding.
_Avoid_: Finding, error

**Binding**:
A lossless record of an unresolved expression, condition, workflow, custom state, API action, or plugin slot. Bindings stay on their element node; the bindings manifest is a derived index.
_Avoid_: Placeholder, expression AST

**Export finding**:
An export-time diagnostic keyed back to a normalized reference. Severity is blocking, warning, or info. A leaked credential is blocking and fails the export.
_Avoid_: Secret-scan finding (unless wrapping one), normalization diagnostic

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
