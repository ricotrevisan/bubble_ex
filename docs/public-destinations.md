# Public destination transport (WTF-291)

`BubbleEx.HTTP` is the single fetch seam. `HTTP.Destination` parses the raw URL,
resolves A **and** AAAA within a finite deadline, rejects the entire answer set
if any address is non-public, and selects one numeric address. `HTTP.Transport`
passes that tuple to Mint while retaining the logical URL, HTTP Host, TLS SNI
and certificate verification hostname. It never retries a connection through an
unvalidated address. Each network hop owns a socket in a linked task; completion,
error, timeout or caller termination closes it. There are no destination-derived
atoms, pools or long-lived connections.

Only HTTP/80 and HTTPS/443 are supported. Userinfo, ambiguous numeric hosts,
non-ASCII/invalid DNS labels, trailing dots, zone IDs and other ports fail closed.
Arbitrary public custom domains and CDNs are allowed. DNS errors are distinct
from policy errors; high-level retries remain bounded by the shared deadline.
The conservative classifier follows the IANA IPv4/IPv6 Special-Purpose Address
Registries (https://www.iana.org/assignments/iana-ipv4-special-registry/ and
https://www.iana.org/assignments/iana-ipv6-special-registry/; CSVs checked during
implementation): non-global IPv4 special-use ranges are denied, including
globally-reachable exceptions within those ranges;
IPv6 requires native 2000::/3 and excludes 2001::/23, documentation and 6to4.
Mapped/compatible, NAT64, Teredo, ULA, link-local and multicast are denied.
Update these explicit ranges when IANA allocates new special-use space.

The locked library suite exercises Req 0.5.15 / Mint 1.10.1; the consumer suite
exercises Req 0.7.4 / Mint 1.10.0. Both adapter interfaces are supported.

Req's redirect step is replaced by a guarded step. The existing body/deadline
check runs first, followed by syntax validation, downgrade credential rejection,
cross-origin cookie/auth removal and Req's established 301/302/303 vs 307/308
method semantics. At most ten redirects are permitted; the adapter resolves and
pins every hop anew, with the original deadline. Frontend manual redirect loops
also retain one deadline. `Frontend.SafeUrl.pin_public_http_destination/3`
delegates to this classifier; asset export no longer substitutes the logical URL
with an IP before calling HTTP.

## Proxy profiles and compatibility

`finch: Name` now selects a trusted connection profile in
`config :bubble_ex, :http_profiles, %{Name => mint_connection_options}`. It does
**not** use a named Finch pool; unknown names fail closed. A pool cannot discard
per-request identity. Configure a direct profile as `[]` if a legacy named direct
client must be retained. `:finch` application configuration still selects a name.

HTTPS destinations may use trusted HTTP(S) proxy configuration. Mint >= 1.10 is
an explicit dependency: CONNECT authority is the validated numeric address,
while inner TLS/Host use the logical hostname. Proxy credentials appear only in
CONNECT. Plain HTTP destinations through proxies are rejected (forward proxies
otherwise resolve the original URL themselves). A proxy failure never silently
falls back to direct. A proxy can lie about where it connects; this contract
requires a trusted provider that honors numeric CONNECT. Network egress controls
and provider feasibility are separate deployment checks, not claimed here.

`Req.Test` plugs and adapters set with the **test-only** `put_process_options/1`
remain usable. Their in-memory DNS defaults to a public fixture answer; raw
literal and injected resolver answers still pass production policy. This does
not alter network requests or application-global policy. Socket tests inject a
connector that verifies the validated numeric tuple before mapping it to a
local fixture. Production uses `Mint.HTTP.connect/4`, not that fixture mapping.
TLS fixture certificates are signed by a test CA; no `verify_none` is needed.

## Scope / evidence

Built from `wtf-290-pp-http-date-pin` (31386b5), not current library main.
Callers covered: Apps entry/live/test/dedicated pages, dynamic scripts, JSON,
plugins/marketplace metadata, enrichment endpoints, contributors, logs, frontend
fetch/export assets and fonts. They all call `BubbleEx.HTTP`; no dependency
sources are patched. Public HTTP tuple results and high-level budget contracts
are retained. Production topology, token rotation and duplicate landing fetch
removal are not included.

Offline verification: `mix test` includes policy matrices, mixed-family DNS,
resolver cancellation, rebind pinning, redirect/auth/method rules, discovered
private scripts, CA-verified TLS/Host/SNI, wrong certificates, numeric CONNECT,
proxy credential separation, socket closure and existing budget regressions.

Safe deployment verification: inspect `HTTP.Destination.pin/3` with an explicit
resolver for private/mixed answers (no socket), then perform a single bounded
`HTTP.fetch_page/2` against an operator-controlled public Bubble/custom-domain
URL (`max_retries: 0`, `total_timeout: 5000`, `max_body_length: 64000`). Inspect
only status/error category and logical URL, never body or proxy config. Do not
probe internal endpoints. A controlled proxy endpoint can record numeric CONNECT
and origin TLS identity without logging proxy authorization.
