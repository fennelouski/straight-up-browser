# Straight Up Browser

A chromeless `WKWebView` browser for macOS, iPhone, and iPad. The
page fills the window; tabs live in a thin vertical sidebar that can be resized,
reduced to favicons, or hidden entirely.

## Download

Download the signed and notarized macOS app from
[nathanfennel.com](https://nathanfennel.com). Drag `Browser` to Applications,
launch it, and accept the license agreement on first run.

## What is implemented

- **Tabs and layouts**: vertical tabs, drag reordering, pinning, recently closed
  tabs, groups, saved workspaces, thumbnails, and 2–4 pane splits on macOS and
  iPad.
- **Browsing sessions**: normal tabs, persistent isolated containers, and
  in-memory incognito sessions. New tabs inherit the current session.
- **Navigation tools**: popup and global omnibars, configurable search engine,
  history/bookmark suggestions, find on page, zoom, hard reload, page
  translation, reader mode, print, and PDF export.
- **Bookmarks and history**: a searchable Library for opening, editing,
  organizing, deleting, importing, and exporting bookmarks, plus searchable
  browsing history with per-URL removal and clear-all.
- **Media and downloads**: per-tab muting, a download manager, upload/download
  history, and visible/full-page/element/window screenshots.
- **Form autofill**: saved profiles of names, contact details, and postal
  addresses. Focusing a recognized field offers what you've saved, and one pick
  fills every matching empty field on the page. Never fills passwords or payment
  cards, never writes without an explicit pick, off in incognito unless you opt
  in, and excludable per site. `⌘⌥A` turns it off entirely.
- **Privacy controls**: per-session website data stores, cookie inspection and
  deletion, clear-site/session/all-data actions, media permission prompts,
  content blocking, redirect-loop protection, and secure/mixed/insecure
  connection state.
- **Sync**: optional private CloudKit sync for tabs, groups, container metadata,
  bookmarks, and autofill profiles. Live page state is a separate opt-in. Incognito data, saved
  workspaces, cookies, website storage, logins, downloads, and extension state
  do not sync.
- **macOS extensions**: load unpacked `WKWebExtension` folders, approve requested
  scopes, open extension popups, control private-tab access, and remove loaded
  extensions.
- **Automation**: an App Intents/Shortcuts surface and an optional CLI for
  navigation, page inspection, JavaScript, interaction, and screenshots. The
  bundled MCP server preserves the exact 53 BrowserOS-compatible browser tools,
  stable per-window Page handles, and parallel hidden Pages.
- **Built-in AI agent**: a permission-gated side panel with streaming adapters
  for OpenAI-compatible Chat Completions, OpenAI Responses, Anthropic Messages,
  and Gemini generateContent, plus direct OpenAI, OpenRouter, Ollama, LM Studio,
  and custom endpoint presets. Provider keys stay in Keychain.
- **Durable and bounded runs**: conversations, runs, steps, approvals, usage,
  artifacts, and replay evidence share one local run store. Hard limits cover
  turns, tool calls, time, Pages, model-result bytes, downloads, artifacts, and
  optional provider tokens or known cost.
- **Agent tools**: semantic WebKit references and observable waits reject stale
  targets; opt-in WebKit signals expose supported navigation, console, dialog,
  and download events without claiming Chromium/CDP data.
- **Cowork and app integrations**: file changes are staged as previewable,
  rollback-capable transactions inside one user-approved folder. Streamable
  HTTP MCP connections support explicit trust, bearer credentials, and OAuth
  2.1 with PKCE through the system authentication session.
- **Scheduled and delegated work**: saved tasks have provider, scope, catch-up,
  overlap, retention, and budget policies. A parent run may delegate bounded
  child runs with least-privilege authority, shared budgets, and Page leases.
- **Memory, diagnostics, and sync**: scoped memory is reviewable and off by
  default. Metrics and redacted diagnostics stay local. Schedule definitions,
  nonsecret provider presets, and user-authored memory can each opt in to the
  user's private CloudKit database; credentials and execution content never
  sync.

### Platform scope

Browser 2.0.1 gives macOS the full agent execution and automation surface above.
The universal iPhone/iPad app shares tabs, groups, workspaces,
containers/incognito, navigation and find,
translation, Reader Mode, Fast Forward, bookmarks/history, downloads,
print/PDF, page captures, cookie and browsing-data controls, sync, settings,
keyboard commands, touch navigation, and the agent-definition sync choices.
Its compact controls are rotation-aware; iPhone intentionally remains
single-pane, while iPad supports 2–4 panes and an optional tab rail that follows
the short edge of the app window. It can retain agent definitions it cannot
execute, displays why schedules are unavailable, and offers local review of
sensitive synced memory without creating a mobile execution path. See the
[mobile deployment guide](IOS_DEPLOYMENT.md) for the development and acceptance work. The
iPhone/iPad target is not part of the public website download.
Global hotkeys, the terminal CLI, full scheduled automation, AppKit
screenshot/window tools, Sparkle updater UI, and the unpacked-extension loader
remain macOS-only.

Browser does not currently expose passkey/WebAuthn sign-in. Apple gates
third-party browser access behind the
`com.apple.developer.web-browser.public-key-credential` entitlement; without
that entitlement, Browser hides WebAuthn APIs so websites fall back instead of
offering a passkey flow that cannot complete. Browser also does not ship a
password vault: form autofill covers saved names, contact details, and postal
addresses only, never passwords or payment cards. Website camera and microphone requests
use WebKit's permission prompt, and remembered per-site choices can be reviewed
or revoked in Privacy settings. Private tabs never persist permission choices.

## Default keyboard shortcuts

Shortcuts can be changed or replaced with a browser preset in Settings. These
are the defaults:

| Shortcut | Action |
|---|---|
| `⌃Space` | Show omnibar |
| `⌥Space` | Global omnibar from any app (macOS) |
| `⌘L` / `⌘K` | Open location / quick open |
| `⌘⌥K` | Open a fresh tab from Quick Open |
| `⌘⇧H` / `⌘⇧K` | Show keyboard shortcuts |
| `⌘T` / `⌘N` | New tab (`⌘N` always creates a fresh tab) |
| `⌘⇧N` | Save the current page to Newspaper |
| `⌘⌥N` | Scratch Pad |
| `⌘⌥⇧N` | New incognito tab |
| `⌘W` | Close current tab |
| `⌘⇧T` | Reopen last closed tab |
| `⌘R` / `⌘⇧R` | Reload / hard reload |
| `⌘⌥⇧R` | Reload all tabs |
| `⌘[` / `⌘]` | Back / Forward |
| `⌃Tab` / `⌃⇧Tab` | Next / Previous tab |
| `⌘1`–`⌘9` | Switch to tab N |
| `⌘O` | Show all tabs |
| `⌘D` | Add or remove bookmark |
| `⌘⇧B` | Show bookmark Library |
| `⌘Y` | Show history Library |
| `⌘⇧J` | Show Downloads |
| `⌘⌥R` | Reader mode |
| `⌘⌥A` | Turn autofill on or off |
| `⌘F` | Find on page |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / actual size |
| `⌘⇧L` | Toggle the tab sidebar |
| `⌘⌥\`` / `⌘⌥1` / `⌘⌥2` / `⌘⌥3` | Hidden / minimal / compact / wide sidebar |
| `⌘,` | Settings |
| `⌘/` | Browser Help |
| `⌥Click` / `⇧Click` a link | Open in a split pane / save to Newspaper |

Back and forward also use the standard trackpad or screen-edge gestures.

## Command-line interface

The helper ships inside the macOS app bundle:

```bash
sudo ln -sf "/Applications/Browser.app/Contents/Helpers/browser-cli" /usr/local/bin/browser-cli
```

CLI automation is **off by default**. Enable it in **Settings → Security → CLI
Automation**, then enable page reading, JavaScript/interaction, screenshots, or
real input only when needed. Real clicks additionally require the macOS
Accessibility permission.

```bash
browser-cli open https://example.com && browser-cli wait
browser-cli snapshot
browser-cli click '#more-info' && browser-cli wait
browser-cli screenshot page.png
browser-cli notify "Please solve the captcha"
```

Commands use an owner-only named pipe at
`~/Library/Application Support/Straight Up Browser/cli.pipe`. The pipe limits
transport to the current user; the in-app capability switches authorize what
those processes may do. See [CLI_USAGE.md](CLI_USAGE.md), or run
`browser-cli docs`.

AI tools that speak MCP can connect without another download or daemon:

```bash
browser-cli install-mcp all       # Codex and/or Claude Code when installed
browser-cli mcp-config            # generic stdio configuration
```

MCP uses the same in-app authorization switches as CLI automation. Its events
join the durable local Agent Run timeline and replay store in the browser's
Application Support directory. Page content and screenshots are not uploaded
by Browser itself.

Open the sparkle button or press `⇧⌘A` for the built-in agent. Settings has one
Agent pane grouping the model provider and Keychain credential, Cowork folder,
scheduled tasks, trusted MCP integrations, timeline/replay, approvals and hard
budgets, child-run limits, memory controls, local diagnostics, WebKit signal
opt-ins, and agent-definition sync. See
[BrowserOS parity](docs/browseros-parity.md) for the compatibility map and the
[AI tooling guide](docs/ai/README.md) for the 2.0 architecture, security model,
feature contracts, and verification requirements.

## Build and verify

Requirements:

- macOS 15.6 or later for the Mac app
- iOS or iPadOS 18 or later for the universal mobile app
- Xcode 16 or later
- Swift 6

Run the warning-free macOS gate used by the notarized release:

```bash
./scripts/verify.sh
```

This runs the macOS unit suite, compiles the universal mobile app in Release,
verifies that the macOS executable is Apple Silicon-only (`arm64`), and builds
the macOS UI-test target. GitHub-hosted Actions are intentionally disabled;
verification runs locally and `scripts/release.sh` repeats the gates before
archiving. Set
`RUN_UI_TESTS=1` locally on a Mac with Developer Mode/UI automation enabled to
run the executable UI gates. Swift and Clang warnings are treated as errors,
and Browser.app line coverage must remain at or above 25%.

The mobile App Store gate is separate and exercises the universal app on both
form factors:

```bash
./scripts/verify-ios.sh
```

See [IOS_DEPLOYMENT.md](IOS_DEPLOYMENT.md) for simulator/device acceptance,
signing, archiving, and App Store Connect preparation.

For a standalone release build:

```bash
xcodebuild -project "Straight Up Browser.xcodeproj" \
  -scheme Browser -configuration Release build
```

To produce the signed, notarized DMG, run `./scripts/release.sh`. It runs
`scripts/verify.sh` before archiving. Credential and publishing setup is in
[DEPLOYMENT.md](DEPLOYMENT.md).

## Architecture

- **Web views**: one `WKWebView` per live tab, owned by `WebViewManager`; memory
  saving can release eligible background views while preserving restoration
  state.
- **Models**: SwiftData stores tabs, groups, sessions, and bookmarks. Incognito
  tabs and their website data stores are memory-only.
- **Navigation**: WebKit's back-forward list is authoritative.
  `BrowsingHistoryStore` is the durable, local-only visit list used by the
  Library and omnibar; private visits are excluded.
- **Isolation**: each normal/container/incognito session is assigned the
  appropriate persistent or ephemeral `WKWebsiteDataStore`.
- **Window chrome**: `WindowManager` hides the title bar and traffic lights
  while retaining a titled window for dragging, focus, and fullscreen.
- **Automation**: the CLI uses named-pipe IPC into the same notification-based
  command paths as menus and App Intents, after capability authorization.
- **Logging**: `Logger` wraps `os.Logger`; inspect output in Console.app.

## Tests and release policy

Core navigation, sessions, cleanup, extension permissions, downloads, security
state, accessibility, Library behavior, and WebKit integration have automated
coverage. GitHub-hosted Actions are intentionally disabled. Run
`scripts/verify.sh` for macOS changes and `scripts/verify-ios.sh` for the
universal mobile app; each archive script reruns its own local gate.

## License

Proprietary. © 2026 Nathan Fennel. All rights reserved. See [EULA.md](EULA.md).
