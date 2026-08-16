# Chromium is an optional macOS build capability

Straight Up Browser remains a WebKit browser unless a dedicated macOS build is
compiled with `CHROMIUM_ENABLED` and packages a Chromium runtime. Chromium is
never linked into or advertised by iPhone or iPad builds. A tab stores a
`preferredEngine`, while `effectiveEngine` resolves that preference against the
capabilities of the running binary and safely falls back to WebKit.

## Why preference and availability are separate

Engine identity is tab data; engine availability is application data. Keeping
them separate has three useful consequences:

- existing tabs and old CloudKit records default to WebKit without migration;
- a Chromium-preferred Mac tab can sync to a mobile device and open there with
  WebKit without mobile ever loading Chromium;
- the mobile round trip preserves the preference, so the tab can use Chromium
  again when it returns to a capable Mac.

The raw SwiftData field is optional (`nil` means WebKit), matching the existing
forward-compatible pattern used by session and memory-policy fields.

## Creation and inheritance

`BrowsingContext` carries both session identity and preferred engine. Any tab
created from another tab—new tab, duplicate, popup, container child, or
incognito child—must inherit that context. This prevents two independent forms
of isolation from drifting apart as engine support is implemented.

Changing an existing live tab's engine is not part of this decision. A future
UI should initially duplicate the URL into the other engine, because live DOM,
form, navigation, media, and storage state cannot be transferred faithfully.

## Packaging boundary

`CHROMIUM_ENABLED` is deliberately checked together with `os(macOS)`. Copying
the build flag to a mobile target cannot enable Chromium. The normal release
must not define it or link Chromium. A future enhanced artifact may define it,
but only after it supplies an engine runtime behind the browser-surface
boundary and passes the shared behavior suite.

No Chromium framework, downloader, UI, or second release channel is introduced
by this ADR. Those remain separate implementation and deployment decisions.
