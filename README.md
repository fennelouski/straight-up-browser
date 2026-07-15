# Straight Up Browser

A chromeless web browser for macOS. No toolbar, no title bar — the page fills
the window. Tabs live in a thin vertical sidebar you can hide entirely.

## Download

Just want to try it? Download the notarized app from
[nathanfennel.com](https://nathanfennel.com) — no build required. Drag
`Browser` to Applications, launch it, and accept the license agreement on
first run.

## Features

- **No chrome**: no toolbar, no title bar, no traffic lights. Web content runs
  edge to edge, maximizing vertical space.
- **Vertical tabs**: a left sidebar (resizable, and hideable with `⌘⇧L`) instead
  of a horizontal tab strip that eats page height.
- **Popup omnibar**: `⌃Space` to navigate or search; it appears over the page and
  gets out of the way.
- **Global omnibar**: `⌥Space` from *any* app summons a floating omnibar over
  whatever you're doing — search or enter a URL and it opens in a new tab.
- **Command-line interface**: drive the running browser from the terminal.

### Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌃Space` | Show omnibar |
| `⌥Space` | Global omnibar, from any app (configurable in Settings) |
| `⌘L` | Show omnibar (Open Location) |
| `⌘T` / `⌘N` | New tab |
| `⌘W` | Close current tab |
| `⌘⇧T` | Reopen last closed tab |
| `⌘R` | Reload page |
| `⌘⇧R` | Reload all tabs |
| `⌘[` / `⌘]` | Back / Forward |
| `⌃Tab` / `⌃⇧Tab` | Next / Previous tab |
| `⌘1`–`⌘9` | Switch to tab N |
| `⌘⇧L` | Toggle the tab sidebar |
| `⌘⌥\`` / `⌘⌥1` / `⌘⌥2` / `⌘⌥3` | Tab bar: hidden / minimal / compact / wide |
| `⌘D` | Bookmark current page |
| `⌘,` | Settings |

Back and forward also work with the standard two-finger trackpad swipe.

## Command Line Interface

Full browser control from the terminal, designed for AI agents: navigate,
snapshot, click, type, screenshot, and hand off to a human when needed. See
[CLI_USAGE.md](CLI_USAGE.md), or run `browser-cli docs` for the complete
agent-oriented guide. The tool ships inside the app bundle:

```bash
sudo ln -sf "/Applications/Internet.app/Contents/Helpers/browser-cli" /usr/local/bin/browser-cli

browser-cli open https://example.com && browser-cli wait
browser-cli snapshot                        # compact page outline + selectors
browser-cli click '#more-info' && browser-cli wait
browser-cli screenshot page.png
browser-cli notify "Please solve the captcha"
```

The browser launches automatically if it isn't running. Commands travel over
an owner-only named pipe at
`~/Library/Application Support/Straight Up Browser/cli.pipe` — filesystem
permissions are the authentication, so only your user can send commands.

## Building the Application

```bash
xcodebuild -project "Straight Up Browser.xcodeproj" -scheme Browser -configuration Release build
```

To produce the signed, notarized DMG for distribution, run
`./scripts/release.sh` (one-time credential setup is documented in the
script header).

## Architecture

- **WebView**: `NSViewRepresentable` wrapper around `WKWebView`. One `WKWebView`
  per tab, owned by `WebViewManager`; the container shows the active one.
- **Tabs**: SwiftData `@Model`. SwiftData *is* the session store — tabs and the
  active selection persist across launches with no parallel JSON copy.
- **Navigation**: `WKWebView`'s own back-forward list is the single source of
  truth. A tab's `historyStrings` is only a visit log for omnibar suggestions.
- **Window chrome**: configured in exactly one place (`WindowManager`), which
  hides the title bar and traffic lights while keeping the window `.titled` so
  dragging, focus, and fullscreen keep working.
- **CLI**: named-pipe IPC into `NotificationCenter`.
- **Logger**: thin wrapper over `os.Logger` (view in Console.app).

## Future Development Roadmap

### 🚀 High Priority Features

#### Tab Management
- [x] Tab state persistence across app restarts (SwiftData)
- [x] Tab reordering with drag and drop
- [ ] Tab pinning (keep important tabs at front)
- [x] Recently closed tabs (Cmd+Shift+T to reopen)
- [x] Tab groups/workspaces
- [ ] Tab thumbnails/previews

#### Navigation & History
- [ ] Enhanced history management with timestamps
- [ ] History search and filtering
- [x] Forward/back trackpad gestures
- [x] URL validation and security warnings
- [x] Auto-complete in omnibar (history + bookmarks)
- [x] Multiple search engine support (Google/DuckDuckGo/Bing/Yahoo)

#### User Interface
- [ ] Omnibar animations and transitions
- [ ] Find-in-page functionality (Cmd+F)
- [ ] Page zoom controls (Cmd+/-)
- [ ] Reader mode toggle
- [ ] Full-screen optimizations
- [ ] Dark/light mode support

### 🔧 Medium Priority Features

#### Bookmarks & Organization
- [ ] Bookmark management system
- [ ] Bookmark folders and organization
- [ ] Bookmark sync across devices
- [x] Import/export bookmarks (Chrome, Edge support; Safari/Firefox in progress)
- [ ] Quick bookmark access in omnibar

#### Privacy & Security
- [ ] Cookie management
- [ ] Tracking protection
- [ ] Ad blocking/content blockers
- [ ] HTTPS Everywhere enforcement
- [ ] Password management
- [ ] Form auto-fill

#### Performance
- [ ] Page preload for faster navigation
- [x] Memory management for multiple tabs (closed tabs release their WKWebView)
- [ ] Cache management
- [ ] Background tab throttling
- [x] Session restoration across restarts

### 🛠️ Developer Features

#### CLI Integration
- [x] CLI commands: open, search, new, close, tabs, get (page data)
- [ ] JavaScript injection capabilities
- [ ] Cookie inspection and management
- [ ] Network request monitoring
- [ ] Extension API for CLI plugins

#### Extensions & Customization
- [ ] Browser extension system
- [ ] Theme customization
- [ ] Keyboard shortcut customization
- [ ] User script support
- [ ] Custom CSS injection

#### Advanced Features
- [ ] Developer tools integration
- [ ] WebRTC and media controls
- [ ] Download manager
- [ ] Print preview and customization
- [ ] Touch Bar support
- [ ] Notification integration

### 🐛 Bug Fixes & Edge Cases

#### Tab Handling
- [x] Proper handling of closing last tab (resets to a clean New Tab)
- [ ] Tab state during app minimization
- [x] Memory cleanup when tabs are closed
- [ ] URL encoding/decoding edge cases

#### Navigation
- [x] Handling of invalid URLs gracefully
- [x] Redirect loop detection
- [x] Mixed content warnings
- [ ] SSL certificate validation display

#### UI/UX
- [ ] Keyboard focus management
- [ ] Window resizing edge cases
- [ ] High DPI display support
- [ ] Accessibility improvements

### 📚 Documentation & Testing

#### Testing
- [ ] Unit tests for core functionality
- [ ] UI tests for critical user flows
- [ ] Performance benchmarking
- [ ] Memory leak detection

#### Documentation
- [ ] API documentation for CLI
- [ ] Extension development guide
- [ ] User manual and tutorials
- [ ] Contributing guidelines

## Requirements

- macOS 15.0+
- Xcode 16+
- Swift 6+

## Contributing

See the TODO comments throughout the codebase for specific implementation details and requirements for each feature.

## License

Proprietary. © 2026 Nathan Fennel. All rights reserved. See [EULA.md](EULA.md).
