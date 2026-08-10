# Browser 2 uses one bounded Run runtime and native loopback OAuth

Status: Accepted

Browser 2 consolidates built-in, scheduled, MCP, and delegated agent execution
around one canonical tool catalogue, durable Run/Step store, policy gate, and
resource meter. The public BrowserOS MCP visibility profile remains exactly 53
tools. Native-only tools for waits, Cowork transactions, delegation, memory,
and WebKit signals use separate visibility metadata rather than changing that
compatibility surface.

An `AgentRun` is the unit of execution and evidence. Every effect is resolved to
its concrete Page/browser Session, Cowork path, or MCP identity, admitted by the
shared budget, authorized by a recorded policy permit, executed once, and
followed by a structured result. Child Runs receive only subsets of parent
authority and budget; Page mutation requires an exclusive lease. Provider,
page, file, and MCP content remains untrusted observation and never grants
authority.

Remote MCP authorization uses standards discovery and OAuth authorization code
flow with S256 PKCE. Browser presents the authorization request with
`ASWebAuthenticationSession` and receives the redirect through a one-shot
`NWListener` bound only to IPv4 `127.0.0.1` on an OS-assigned ephemeral port.
The listener validates the exact method, callback path, Host and port, OAuth
state, request size, and timeout before code exchange, then closes. The app's
`com.apple.security.network.server` entitlement exists for this loopback
listener; it is not a general inbound service. The MCP authorization server must
pre-register Browser as a public native client and permit the documented
loopback path with an ephemeral port.

OAuth codes and PKCE verifiers are transient. Provider keys, bearer tokens, and
OAuth tokens stay in device-only Keychain items and are absent from settings,
Runs, logs, exports, and CloudKit. Connection trust binds endpoint, negotiated
identity/capabilities, tool-schema digest, auth mode, and effective scopes.
Changing one invalidates prior grants; revocation prevents calls locally before
best-effort server revocation completes.

MCP mutation retry identity belongs to one logical invocation, not merely its
arguments. The idempotency key derives from the execution permit digest and the
persisted invocation Step ID. A refresh-and-retry after one 401 therefore uses
the same HTTP header and MCP `_meta` value, while a later deliberate invocation
with identical arguments receives a different key.

## Considered options

- **Keep separate agent loops and audit formats** — rejected because entry
  points could drift in schema, authority, limits, recovery, and evidence.
- **Expand or rename the public 53-tool MCP profile** — rejected because native
  growth must not silently break BrowserOS-compatible clients.
- **Custom URL-scheme OAuth callback** — rejected because native-app OAuth
  servers commonly standardize on loopback redirects, and the redirect would
  not prove possession of an exact one-shot local listener.
- **Fixed loopback port** — rejected because it creates collision and port
  squatting risk. The operating system selects a fresh port for each attempt.
- **Open a normal browser Tab and poll for completion** — rejected because it
  weakens the system authentication boundary and does not provide a validated
  redirect receiver.
- **Use only the permit/argument digest as an idempotency key** — rejected
  because two intentional identical mutations would collapse into one logical
  operation.
- **Vendor connector proxy or dynamic client registration** — rejected for the
  2.0 scope. Browser connects directly to standards-compliant endpoints using a
  pre-registered public native client ID.

## Consequences

- All agent entry points must preserve the Run, policy, and metering lifecycle;
  an executor cannot add an unrecorded fast path.
- A hard limit produces an explicit limit Step before execution stops. Unknown
  provider usage/cost remains unknown and cannot be fabricated.
- The network-server entitlement and listener code are security-sensitive and
  must stay narrowly scoped to ephemeral loopback OAuth tests and production
  callbacks.
- MCP refresh may retry a mutation at most once and only with the same logical
  invocation key. Ambiguous non-idempotent failures are not replayed.
- macOS owns this OAuth and automation surface. iPadOS may retain synced safe
  definitions but does not manufacture support for macOS-only execution.
- Release acceptance must separately verify the exact 53-tool snapshot,
  loopback rejection cases, secret redaction, trust invalidation, revocation,
  idempotency behavior, signing entitlements, and the full application gates.
