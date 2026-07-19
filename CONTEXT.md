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

## Relationships

- A **Split** displays 2–4 **Tabs**; exactly one of them is the **Focused tab**
- A **Split** is window state, persisted locally only — never a SwiftData entity, never synced
- While a **Split** is active, its member tabs are gathered adjacent in the sidebar (they are not a **TabGroup**)
- Gathering is a real reorder (`orderIndex` moves members after the first-added anchor); on dissolve, tabs stay where they gathered
- Sidebar order = pane order: dragging a member within the gathered block reorders panes; dragging a non-member into the block does not join it to the Split
- A **Split** is per-window state; each window owns its own TabManager/WebViewManager, so one tab displayed in two windows is already two webviews
- Selecting a non-member tab by any means (click, ⌘T, popup, tab cycling) dissolves the **Split** into a single view; only shift-click adds a member
- Memory saver must exempt all **Displayed tabs**, not just the **Focused tab**
- The **Split** arrangement (ordered member IDs + focused ID) persists in UserDefaults; on launch, unresolved IDs are dropped, and fewer than 2 survivors means a plain single view
- Incognito tabs may join a **Split** (isolation is per-tab at the data-store level); they never survive relaunch, handled by the drop-unresolved rule

## Example dialogue

> **Dev:** "If a **Split** shows Mail and Calendar, which one does ⌘L edit?"
> **Domain expert:** "The **Focused tab** — the omnibar always follows focus, and there's exactly one focused tab even when four are displayed."

## Flagged ambiguities

- "active tab" historically meant the one visible tab; with splits it forks into **Displayed tabs** (visible) vs **Focused tab** (owns chrome). Code keeps `selectedTabId` = focused.
