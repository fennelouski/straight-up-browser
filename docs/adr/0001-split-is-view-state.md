# A Split is window view state, not a persistent entity

Split view (2–4 tabs displayed side by side in one window) is modeled as per-window view state on `TabManager` — an ordered list of member tab IDs plus the focused ID, persisted to UserDefaults — not as a SwiftData model. Member tabs remain ordinary tabs; the split is an arrangement of them, and it never syncs.

## Considered Options

- **Arc-style persistent split groups** (a SwiftData entity like `TabGroup`, restorable and CloudKit-synced) — rejected. Syncing an arrangement raises questions with no good answers: what a split means on iPhone, what happens when a member tab is closed on another device in openClose mode, and every CloudKit attribute constraint for a concept that is fundamentally "what this window happens to be showing." View state keeps the SwiftData schema untouched and lets incognito tabs (memory-only, never persisted) join splits for free — unresolved member IDs are simply dropped at restore.

## Consequences

- `selectedTabId` keeps meaning "the focused tab" (owns omnibar, title, ⌘F/⌘W/zoom); a split adds "displayed tabs" as a superset. Anything that treats *selected* as *the only visible tab* must be checked — the known case is memory saver (`ContentView.handleMemoryPressure`), which must exempt all displayed tabs, not just the focused one.
- Selecting any non-member tab (click, ⌘T, popup, tab cycling) dissolves the split; only shift-click adds members. There is deliberately no "background split" — a split that isn't displayed doesn't exist.
- If saved/synced split groups are ever wanted, that's a new entity plus migration, not an evolution of this state.
