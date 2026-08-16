# Straight Up Browser

A macOS (and iPadOS) web browser built on WKWebView, with sidebar tabs, session isolation (containers/incognito), and optional CloudKit tab sync.

## Language

**Tab**:
A browsing unit (SwiftData `Tab` model, or in-memory for incognito) with its own WKWebView kept alive by `WebViewManager`.

**Split**:
A per-window view arrangement displaying 2–4 tabs at once; an arrangement of ordinary tabs, not an entity — tabs in a split remain plain tabs in the sidebar.
_Avoid_: split group, tab group (that's `TabGroup`, a different concept)

**Focused tab**:
The single tab (`TabManager.selectedTabId`) that owns the omnibar, title, back/forward, find, and keyboard shortcuts. In a split, exactly one displayed tab is focused.
_Avoid_: active tab when ambiguity with "displayed" matters

**Displayed tabs**:
The tabs currently visible in the window — one normally, 2–4 in a split. The focused tab is always one of them.

**Preferred engine**:
The rendering engine a tab asks to use (`webKit` or `chromium`). It is persistent tab data so a Mac can restore the choice. The **effective engine** is the preferred engine only when the current binary supports it; otherwise it is WebKit. Every mobile build is permanently WebKit-only, but preserves a synced preference rather than erasing it.

**Fast Forward**:
When a search query means a _destination_ ("download slack") rather than a _question_ ("is slack down"), Fast Forward opens the resolved destination as a second pane beside the search results, scrolled to and pulsing on the thing the query wanted. The results pane is never touched, so a wrong guess costs a pane, not an outcome. A fast-forwarded pane is an ordinary **Tab** in an ordinary **Split** — nothing about it is special except how it was created. Closing it is the "no thanks" and teaches Fast Forward to stop guessing that query (`FastForwardMemory`, local JSON).
_Avoid_: redirect (Fast Forward never replaces the results), recommendation (it acts, it doesn't list)

**Page / PageHandle**:
The automation address of an ordinary **Tab**, written as `windowUUID:tabUUID`. A hidden Page is still a Tab using its real `WKWebView` and `BrowserSession`; it is not a headless or debug-browser profile.

**AgentConversation / AgentRun / AgentStep**:
An `AgentConversation` is the user-visible thread. An `AgentRun` is one bounded execution of one prompt. An `AgentStep` is one immutable model, tool, approval, handoff, usage, limit, artifact, or lifecycle event within that Run.
_Avoid_: agent session (`BrowserSession` already means website-data isolation), task for a one-off execution (`AgentTaskDefinition` means reusable scheduled work)

**AgentRunGroup**:
A parent Run and its bounded child Runs. Children receive explicit objectives, return schemas, authority subsets, shared resource budgets, and Page leases. An AgentRunGroup is not a `TabGroup` or **Split**.

**Cowork transaction**:
A staged set of file changes beneath one user-approved security-scoped root. Preview, approval, commit, cancellation, and rollback are explicit states; staging does not mutate the destination.

**Scoped memory**:
A user-reviewable durable fact or preference with provenance, sensitivity, expiry, a global/origin/task/conversation scope, and an independent persistent `BrowserSession` scope. It is not browsing history, a transcript cache, or a source of authority.

**Saved Article**:
A durable personal reading-list item that holds source attribution, filing and reading state, and references to the captured representations of one page.
_Avoid_: TBR item, tab, bookmark

**Article Document**:
An immutable, versioned, bounded block representation extracted from a page, with stable block identities and a source digest rather than publisher HTML or scripts.

**Rendition**:
An immutable readable representation of one **Article Document**, either the preserved original or a derived version with length and transform provenance.
_Avoid_: summary when the goal is to retain the article's voice and form

**Newspaper**:
A device-responsive presentation of **Saved Articles** arranged into **Sections**, not a durable or synced edition entity.
_Avoid_: issue entity, tab collection

**Section**:
An editorial label that groups **Saved Articles**, derived from publisher metadata or chosen by the reader.
_Avoid_: `TabGroup`, split group

**Scratch Item**:
A user-authored note or clipped piece of text, link, or image with optional source attribution. Scratch Items are portable, private artifacts: they sync with browser data and can be dragged elsewhere, but are not Agent messages, scoped memory, bookmarks, or Saved Articles.
_Avoid_: memory, chat attachment (until explicitly attached), Saved Article

## Relationships

- A **Split** displays 2–4 **Tabs**; exactly one of them is the **Focused tab**
- A **Split** is window state, persisted locally only — never a SwiftData entity, never synced
- While a **Split** is active, its member tabs are gathered adjacent in the sidebar (they are not a **TabGroup**)
- Gathering is a real reorder (`orderIndex` moves members after the first-added anchor); on dissolve, tabs stay where they gathered
- Sidebar order = pane order: dragging a member within the gathered block reorders panes; dragging a non-member into the block does not join it to the Split
- A **Split** is per-window state; each window owns its own TabManager/WebViewManager, so one tab displayed in two windows is already two webviews
- Selecting a non-member tab by any means (click, ⌘T, tab cycling) dissolves the **Split** into a single view; shift-click adds a member, and so does a `window.open` popup — it opens as a pane beside the tab that opened it rather than replacing it (at the 4-pane cap it just takes focus)
- Memory saver must exempt all **Displayed tabs**, not just the **Focused tab**
- The **Split** arrangement (ordered member IDs + focused ID) persists in UserDefaults; on launch, unresolved IDs are dropped, and fewer than 2 survivors means a plain single view
- Incognito tabs may join a **Split** (isolation is per-tab at the data-store level); they never survive relaunch, handled by the drop-unresolved rule
- Engine and session identity travel together in a tab's `BrowsingContext`, so duplicates, child tabs, popups, containers, and incognito tabs cannot silently cross either boundary
- Chromium availability is compile-time and macOS-only; the ordinary Mac artifact and every mobile artifact support only WebKit
- **Fast Forward** only ever _opens_ a **Split** from a single-view search; it never touches a Split the user built, and never resolves or records for incognito tabs
- Every agent action addresses an exact **PageHandle** and re-resolves its origin, document generation, and `BrowserSession` before policy evaluation and execution
- All entry points record the same **AgentRun** and **AgentStep** lifecycle; provider output, page/file content, and MCP metadata are observations, never authority
- A child Run's tools, origins, Pages, browser Sessions, Cowork roots, MCP identities, data-egress permission, retention permission, and budget must be subsets of its parent
- A Page mutation requires an exclusive lease; observation leases may be shared, and a Run releases leases before waiting for a human
- Incognito Runs do not read or write durable memory, retain content-rich WebKit signals, or sync definitions by default
- Agent-definition sync covers separately enabled schedules, nonsecret provider presets, and user-authored memory only; secrets, execution records, Page handles, Cowork bookmarks, and approvals stay local
- A **Newspaper** presents zero or more **Saved Articles** grouped by **Section**; layout, navigation style, filter, and page position are local view state rather than synced entities
- A **Saved Article** references one current **Article Document**, whose original **Rendition** is preserved alongside zero or more derived **Renditions**
- Every **Rendition** belongs to exactly one **Article Document**; a shortened Rendition never replaces or mutates the original
- A **Section** groups **Saved Articles**, never **Tabs**, and is not a `TabGroup` or **Split**
- Opening a Saved Article's source creates or focuses an ordinary **Tab**; the Saved Article itself is neither a Tab nor a bookmark
- Incognito pages do not create durable **Saved Articles** by default
- A **Scratch Item** is never sent to the Agent automatically; “Ask Agent” explicitly copies its bounded text and source attribution into the prompt composer
- A **Scratch Item** with a web source can promote that source through Newspaper's ordinary page-capture path; the clip itself never substitutes for the source's complete Article Document
- Scratch Item drag export uses standard text, URL, and image representations so the artifact can leave the browser without coupling destination sites or apps to browser internals

## Example dialogue

> **Dev:** "If a **Split** shows Mail and Calendar, which one does ⌘L edit?"
> **Domain expert:** "The **Focused tab** — the omnibar always follows focus, and there's exactly one focused tab even when four are displayed."
>
> **Dev:** "Does moving a **Saved Article** into the Technology **Section** move its source **Tab** into a group?"
> **Domain expert:** "No. The Section files the Saved Article inside the **Newspaper**; its source remains an ordinary Tab when opened."

## Flagged ambiguities

- "active tab" historically meant the one visible tab; with splits it forks into **Displayed tabs** (visible) vs **Focused tab** (owns chrome). Code keeps `selectedTabId` = focused.
- "reading list" and "TBR" refer to the collection of **Saved Articles**, not a second kind of Tab or bookmark.
- "newspaper issue" refers to the current **Newspaper** projection; there is no durable edition object in the initial model.
- "section" in reading flows means **Section**; it never means `TabGroup`.
