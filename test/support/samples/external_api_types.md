# Synthetic External API type fixture

`BubbleEx.Test.ExternalApiTypeFixture.app/0` is an author-controlled metadata
fixture for API Connector v2 acceptance tests. It was written from the public
feature contract and contains no copied application identifiers, URLs,
credentials, headers, request parameters, response bodies, or sample values.
Type inference from response samples is forbidden.

The fixture proves:

- active scalar and list database roots, plus a deleted root;
- exact connector/call/type lookup and database-reachable closure;
- text, number, date, Unix-date, and primitive-list descriptors;
- nested, cross-call, reused, and directly recursive references;
- missing display metadata and an explicitly ignored registry member;
- unresolved and malformed roots with fail-soft structured warnings.

Tests derive separate minimal variants for mutually exclusive malformed,
missing-registry, empty-definition, and conflicting-definition states.
