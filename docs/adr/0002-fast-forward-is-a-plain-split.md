# A fast-forwarded pane is a plain tab in a plain split

Fast Forward (turning a destination-shaped search like "download slack" into a side-by-side
split where the results stay left and the resolved page opens right) is built entirely out of
existing pieces. The destination pane is an ordinary `Tab`; the arrangement is an ordinary
Split created through the one sanctioned door, `TabManager.toggleSplitMembership`. Nothing about
the pane is marked, flagged, or special-cased in the tab model — `FastForward` holds the only
record that a given pane was machine-opened, in a side table keyed by tab id, and that record
exists solely to score the accept/strike verdict when the pane closes.

## Considered Options

- **A distinct "assistant pane" type** (a `Tab` subtype or a flag on `Tab`) — rejected. It would
  leak a transient, per-window concept into the SwiftData schema and the CloudKit record type, for
  no behavior the plain-tab model doesn't already give us. A fast-forwarded pane should back/forward,
  close, join or leave the split, and sync exactly like any other tab, because it _is_ one.

- **Intent captured by threading a callback out of the omnibar** — rejected in favor of parsing the
  query back out of the search URL (`FastForward.searchQuery(from:)`) at `didCommit`. The URL is the
  one place every entry point already converges: the omnibar, the CLI, App Intents, the global
  omnibar, and Google's own in-page search box all end at a `?q=`/`?p=` URL. One parser covers them
  all; a callback would cover only the one that has it wired.

- **Learning stored in SwiftData** — rejected for the same reason ADR-0001 rejected persisting splits.
  What Fast Forward learns ("this Mac's user keeps / dismisses this guess") is per-machine telemetry
  with no meaning on another device. It lives in local JSON next to `DownloadManager`'s file history
  (`~/Library/Application Support/Straight Up Browser/fast-forward.json`), not in the synced store.

## Consequences

- Everything that already handles a tab or a split handles a fast-forwarded pane unchanged. The only
  new coupling is three one-line calls into existing seams: `didCommit`/`didFinish` in
  `WebView.Coordinator`, and `closeTab` in `TabManager`.
- The safety of auto-firing rests on the split _adding_ rather than replacing: the results pane always
  holds exactly what the user searched for. Anything that changes Fast Forward to navigate the search
  tab itself, or to open without the split, breaks that guarantee and must be reconsidered here.
- The on-device model (FoundationModels, macOS 26) is pure upside behind a runtime `#available` fence
  and its own default. The regex verb table must always stand alone, because the deployment target
  (macOS 15.6) cannot run the model branch at all.
- If Fast Forward's learning is ever wanted across a user's devices, that is a new synced entity plus a
  privacy decision (it records what you searched and where you went), not an evolution of the local file.
