# Newspaper editorial styles and personal clippings

Status: Accepted — requested by the user on 2026-10-09.

Newspaper is still a projection of the private Saved Article library. Thirty
original publication styles express editorial traditions through typography,
palette, mastheads and recommended paper. They do not use publisher names,
logos or claim affiliation. Existing layout and font choices are retained.
Style, format, system/light/dark appearance and paper are independent controls.

Cover & Contents projects a lead story as a magazine cover with an inside
table of contents. Flipbook uses the bounded page reader with loose-sheet transitions. Story Feed
uses stacked visual stories. Newsstand presents article covers, and Eclectic
chooses newspaper, magazine or reading-card presentations from image availability,
reading length and section/title cues. Classification is a local presentation
heuristic; it does not rewrite headlines or invent source text. Every format
opens the same attributed saved document. Preferences remain device-local,
while documents follow the existing private CloudKit browser-data sync switch.

Paper is drawn as deterministic tiled vectors in a SwiftUI Canvas. No large
texture assets or animation timers are required. Readers can override the
recommended texture and strength. Native transitions include subtle unequal
compression and movement across both axes. Duration can be zero and spring
motion disabled; system Reduce Motion takes precedence.

Visible covers honor the photo limit. Images are fetched with ephemeral,
credential-free requests, bounded to 8 MiB and downsampled to 1,200 pixels.
Redirects reject unsupported schemes, credentials and literal/local destinations;
TLS keeps default verification. At most three workers and a 48 MiB / twelve-entry
memory cache bound work. Optional foreground isolation uses Apple Vision locally,
without any provider or Browser backend; Low Power Mode suppresses isolation.
The supplied photograph stays behind the masthead and a successfully isolated
subject can overlap it. Failure leaves the ordinary photograph or vector cover.
Photos and cutouts are not newly promised as durable offline assets.

First-open preparation happens only when Newspaper is opened. With no explicit
style, the device's existing region/language and image availability choose a
recommendation. No location permission, GPS, IP service, account lookup or new
network request is used. The recommendation can be disabled before opening,
and selected styles are never silently replaced. A progress indicator covers
preparation. An absolutely empty first edition can receive bundled, attributed
excerpts of the author's Browser launch post and support page. This fallback
can be disabled; it is added once, never repeatedly replenished after deletion,
and never substitutes for already-saved or in-progress articles. Foreground
recent-reading catch-up runs before this fallback is considered.

Personal shopping clippings are a separate opt-in, not an ad service. After a
regular-tab dwell, explicit JSON-LD Product metadata can supply a bounded name
and source URL. Password/payment forms, incognito/container sessions and excluded
destinations are ineligible. A document token and URL bind the observation;
consent is checked again before storage. At most twelve clippings stay on this
device for thirty days. Disabling collection clears them; display and clearing
are independent controls. No account, purchase, payment or price data is collected,
no endorsements or offers are invented, and nothing is sent to advertisers,
CloudKit or a model provider. Cards identify themselves as personal clippings
and can link to related saved reading via title matching. Existing separately
consented linked discovery may consider same-site article links from a product
page, with ADR-0009's fetch budget and article validation. There is no automatic
shopping search across the web or affiliate rewriting.

Validation covers first-open defaults/choice preservation, empty-library fallback
and deletion, shopping consent/bounds/expiry/exclusions, shared Mac/iOS builds,
cover/contents/newsstand/feed/page navigation, theme previews and narrow-phone
rendering. Physical two-device synchronization remains the existing service-level
validation limitation; it is not established by simulator or election tests.

Edition naming is a separate collapsed settings section. A manual masthead is
always available. AI naming is explicitly requested and previews the exact
bounded JSON context and destination before invocation. Saved sections are the
only enabled contextual source by default; saved headlines, device name, device
region and recent site hosts are independently selected. A name/nickname is
entered by the reader, never obtained from contacts. Hosts exclude credential,
local and excluded destinations; no URL paths, queries, page contents, passwords,
GPS or IP lookup are included. Context is transient. A chosen title alone is
persisted on this device; it does not change editorial style or rewrite articles.

Apple Intelligence uses Foundation Models on supported Mac/iOS devices and never
silently falls back to an API. Mac readers may explicitly select their connected
provider. They preview its actual model and destination, and opt into up to two
bounded, tool-free requests: twelve candidates, then an optional ranking of that
same pool. The task-only fast-model choice uses reviewed Luna IDs for OpenAI or
OpenRouter; other provider/local/custom choices retain their selected model.
Provider changes invalidate the preview; AI disablement/cancellation stops work.
Names must pass length/character validation, are displayed for selection, and
are never silently applied. Incognito retention rules keep personal prompts and
responses out of durable agent content while retaining redacted run/usage metadata
for the actual provider/model/pricing. iOS presently exposes on-device naming;
the existing connected-provider agent configuration is Mac-only. Tests substitute
responses to exercise budgets and selection without billable inference. A separate
opt-in live Apple Intelligence probe generated and shortlisted names from sample
sections on this Mac; the subject-isolation fixture also exercises Apple Vision.
Connected-provider naming reuses the existing tested agent transports; it has
not made a billable live request during this release verification.

The publication gallery opens directly from a collapsed section, without a
second “browse” label/control. Mac settings search expands a matching collapsed
section before highlighting its destination.

Ink and Broadsheet are continuous print sheets: no article card borders, inset
panels, frosted backgrounds or drop shadows. Broadsheet flows stories into one
to four balanced columns, separated by restrained hairline rules, adapting to
measured available width. Section headings group related stories. The whole
edition, including the masthead, scrolls. Horizontal two-finger gestures turn
pages; large chevrons at the viewport edges fade until the pointer approaches
(or accessibility focus reaches them). Each sheet turn varies its bow, rotation
and lift slightly; the duration, spring setting and Reduce Motion controls apply.
The close control remains in the viewport’s upper-right corner. Mastheads and date lines are centered/compact; section choices
and reading controls are unboxed text. Article actions and status notes follow
the same understated print treatment. Magazine frames belong only to the relevant
cover traditions; other cover edges are hairlines. Mac Newspaper hides its title
bar chrome while preserving native window controls, resizing and a draggable
masthead background. Preview thumbnails use the same column-rule vocabulary.
