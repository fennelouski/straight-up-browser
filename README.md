# Straight Up Browser

A chromeless `WKWebView` browser for macOS, with a companion iPadOS app. The
page fills the window; tabs live in a thin vertical sidebar that can be resized,
reduced to favicons, or hidden entirely.

## Download

Download the signed and notarized macOS app from
[nathanfennel.com](https://nathanfennel.com). Drag `Browser` to Applications,
launch it, and accept the license agreement on first run.

## What is implemented

- **Tabs and layouts**: vertical tabs, drag reordering, pinning, recently closed
  tabs, groups, saved workspaces, thumbnails, and 2–4 pane splits.
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
- **Privacy controls**: per-session website data stores, cookie inspection and
  deletion, clear-site/session/all-data actions, media permission prompts,
  content blocking, redirect-loop protection, and secure/mixed/insecure
  connection state.
- **Sync**: optional private CloudKit sync for tabs, groups, container metadata,
  and bookmarks. Live page state is a separate opt-in. Incognito data, saved
  workspaces, cookies, website storage, logins, downloads, and extension state
  do not sync.
- **macOS extensions**: load unpacked `WKWebExtension` folders, approve requested
  scopes, open extension popups, control private-tab access, and remove loaded
  extensions.
- **Automation**: an App Intents/Shortcuts surface and an optional CLI for
  navigation, page inspection, JavaScript, interaction, and screenshots.

### Platform scope

The macOS app has the full feature set above. The iPadOS target shares tabs,
containers/incognito, sync, bookmarks, downloads, settings, keyboard commands,
and touch navigation. macOS-only integrations—global hotkeys, the terminal CLI,
AppKit screenshot/window tools, and the unpacked-extension loader—are not
present in the iPadOS build.

Browser does not currently expose passkey/WebAuthn sign-in. Apple gates
third-party browser access behind the
`com.apple.developer.web-browser.public-key-credential` entitlement; without
that entitlement, Browser hides WebAuthn APIs so websites fall back instead of
offering a passkey flow that cannot complete. Browser also does not ship a
password vault or form-autofill database. Website camera and microphone requests
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
| `⌘T` / `⌘N` | New tab |
| `⌘⇧N` | New incognito tab |
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
| `⌘F` | Find on page |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / actual size |
| `⌘⇧L` | Toggle the tab sidebar |
| `⌘⌥\`` / `⌘⌥1` / `⌘⌥2` / `⌘⌥3` | Hidden / minimal / compact / wide sidebar |
| `⌘,` | Settings |

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

## Build and verify

Requirements:

- macOS 15.6 or later for the Mac app
- iPadOS 18 or later for the iPad app
- Xcode 16 or later
- Swift 6

Run the same warning-free gates used by CI and releases:

```bash
./scripts/verify.sh
```

This runs the macOS unit suite, builds both apps in Release, verifies that the
macOS executable is Apple Silicon-only (`arm64`), and builds the macOS UI-test
target. On CI and in `scripts/release.sh`, it also executes the macOS and iPadOS
UI suites. Set `RUN_UI_TESTS=1` locally on a Mac with Developer Mode/UI
automation enabled to run the same executable UI gates. Swift and Clang warnings
are treated as errors, Browser.app line coverage must remain at or above 25%,
and CI failures retain `.xcresult` bundles for diagnosis.

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
coverage. The shared `Browser`, `Browser iOS`, and `Browser UI` schemes are
checked by `.github/workflows/ci.yml`; releases cannot archive until the same
verification script passes.

## License

Proprietary. © 2026 Nathan Fennel. All rights reserved. See [EULA.md](EULA.md).
