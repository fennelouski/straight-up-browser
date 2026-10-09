# Newspaper discovery and private idle workers

Status: Accepted — explicitly requested by the user on 2026-10-09.

Newspaper defaults to an image-free Broadsheet with a lead story and an independent
system/light/dark appearance. Layout and presentation preferences remain local;
a reader's explicit layout choice is retained. Settings show layout and paired
light/dark previews. A headline is selected from ready articles by priority,
unread state and recency, or pinned by the reader. Source text is never invented
or replaced by an AI-generated headline.

Discovery is a separate path. The 2026-10-09 follow-up makes visited-page capture,
recent-reading catch-up and visited front-page links default on while preserving
explicit opt-outs; other sources and AI processing remain separately opt-in. It does not change deliberate
Add to Newspaper or workspace research-ledger capture. Visited-page discovery
uses the existing regular-session WebKit document after a dwell; omnibar-prefetch
capture is an independent permission. Incognito and container sessions do not
participate. Explicit excluded hosts cover their subdomains. Discovery requires
HTTPS, removes recognized tracking queries and omits other query-bearing/credential-bearing URLs, localhost/`.local` names
and literal IP destinations,
requires article semantics and substantive multi-paragraph text, and binds
acceptance to a live isolated-world document token before and after extraction.
A same-URL reload invalidates a late result. Automatic captures do not refresh
or overwrite an existing saved article. Document byte/text/block limits apply.

Linked discovery is an independent control. It takes a bounded set of same-site
article links from a visited document, including a front page, without
password/payment forms. It never recursively crawls, uses an ephemeral anonymous
WebKit store with page scripts and autoplay disabled, cancels credential
challenges, preserves default TLS verification, and checks each main-document navigation destination. Embedded frames are blocked
without failing the parent article. A regression test covers the tracking-frame
case, and a separate opt-in live catch-up probe reached the default 24-article
budget from a public publication homepage on this Mac.
Outside foreground catch-up, work is bounded to one load per thirty minutes and
a configurable daily article budget. Foreground catch-up checks up to 96 public
candidates from thirty days of recent visits and open normal tabs in a bounded
pass with a 120-second scheduling deadline and 15-second load deadlines. It may
finish an already-started load after the scheduling deadline. Article budget
defaults to 24, adjustable 1–100; URLs checked in the last day are skipped. Newly
fetched links do not generate another level of links. Opt-outs, Low Power Mode,
cancellation and pressure are checked between loads. The request interval persists across relaunches, and already-saved
articles skip extraction and AI validation. Low Power Mode and memory pressure pause work. Idle execution is optional
on macOS while Browser remains open and inactive, after two minutes without user
input; renewed input or returning to Browser cancels an idle fetch.
iOS does not promise arbitrary loading while suspended.

This ADR extends ADR-0005 only for bounded, optional on-device classification:
one quoted article sample, no tools, no secrets, no network model, a fifteen-second
time budget, and an exact ARTICLE/REJECT result. Unavailability or failure does
not silently fall back to a remote provider. Article content remains untrusted.
The original no-tool condensation boundary is unchanged.

External classification is separately opt-in and macOS-owned. It uses the
configured provider/key/model and the canonical ADR-0004 Run, policy and metering
runtime. Its scope has no capabilities, Pages, files or MCP routes, and budgets
allow one model turn, zero tool calls and a bounded sample/result. Empty Run
scopes exclude implicit memory retrieval, advertised tools and MCP preparation.
Only a successfully completed Run can accept an article. The compact
human-visible objective excludes article text; the configured provider receives
up to 6,000 characters of the candidate. Settings disclose API charges, provider
retention and Run history. No Browser backend participates. Historical runs and
provider boundaries are retained.

Optional cross-device coordination additionally requires browser-data sync.
A private iCloud key-value mailbox contains at most ten bounded candidate URLs
per device and an idle-worker heartbeat. It contains no page HTML, cookies,
credentials, article text or browsing-history corpus. Each device controls its
own sources, exclusions, AI processing and daily budget. Idle worker election
uses a deterministic ordering of fresh heartbeats; stale advertisements expire
in three minutes and links expire in one day. iCloud is eventually consistent:
coordination reduces redundant loads but cannot guarantee exactly-once fetching.
New saved text follows the existing private CloudKit browser-data sync switch,
which requires relaunch. Opting out removes this device's mailbox row.

Weather is independently opt-in and uses native WeatherKit with a reader-chosen
city or current location. Clicking the masthead icon opens a popup; current
location asks for When in Use authorization only after that explicit choice,
then uses a one-shot coarse fix. Existing authorization is reused. Coordinates
stay in memory and are neither logged nor synced. City lookup and forecast
requests go to Apple, not the Browser backend. No IP guess or background location
tracking occurs. Weather and attribution are loaded
together; weather is displayed only after Apple's supplied mark is available,
with its legal data-source link. The reader remains usable when weather fails.
WeatherKit and key-value-store entitlements must be present in signed builds;
WeatherKit also needs the capability enabled on the signing team's App IDs.

Verification includes defaults/independent consent, URL and exclusion policy,
article eligibility, expired/active worker election, theme independence, reader
and settings visual checks, model availability and failure behavior, SDK builds,
and signing/capability validation. Two physical-device coordination and live
WeatherKit require the relevant Apple services; compilation alone does not
prove either service works in production.
