# Driving Browser for screenshots

How to launch the macOS app, populate it, drive its UI, and capture clean
window screenshots — the process used to build the gallery + recursive hero on
the `straight-up-browser` blog post. Two tiny Swift helpers live next to this
file; everything else is `screencapture`, `browser-cli`, and `git`.

## ⚠️ Read first: the app shares your real data

The Debug build writes its SwiftData store to
`~/Library/Application Support/default.store` (`-wal`, `-shm`) — **the same
store as your everyday tabs, groups, and bookmarks**, and it syncs over CloudKit
if Tab Sync is on. Opening tabs or changing settings while driving it
**overwrites your real session**. Always back up first, restore after.

```sh
# BACK UP (app can be running)
BK=~/Documents/browser-tabs-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK" && cp ~/Library/Application\ Support/default.store* "$BK"/
```

```sh
# RESTORE (quit the app FIRST — gracefully, never pkill)
osascript -e 'tell application "Browser" to quit'   # waits for SwiftData to release the store
sleep 2
cp "$BK"/default.store* ~/Library/Application\ Support/
open <path-to>/Browser.app                          # relaunch to confirm
```

`pkill`/force-quit can corrupt the store (black window on next launch). Only
quit via the AppleEvent above (or the menu). The tab-bar *mode* is a
UserDefaults preference, not in the store, so restoring the store won't reset
it — flip it back by hand (see shortcuts below).

## Permissions

The controlling terminal needs **Screen Recording** (for `screencapture` to see
window contents) and **Accessibility** (for CGEvent keystrokes to reach the
app). System Settings → Privacy & Security. If a capture comes back as just the
wallpaper, or keystrokes do nothing, that's the missing grant.

## Helpers

Compile once:

```sh
swiftc winid.swift  -o winid     # prints the largest on-screen window id for an app
swiftc keypost.swift -o keypost  # posts one CGEvent keystroke to the frontmost app
```

- `./winid Browser` → e.g. `23091`
- `./keypost <keycode> [cmd,opt,shift,ctrl]` → e.g. `./keypost 20 opt,cmd` sends ⌥⌘3

US keycodes used here: `` ` ``=50, `1`=18, `2`=19, `3`=20, `h`=4, `k`=40, `r`=15,
`n`=45, `a`=0, `s`=1, esc=53.

## Capture a clean window

Region capture (`-R`) grabs whatever is on top. Use **window-id** capture — it
grabs the window's own content even when occluded:

```sh
WID=$(./winid Browser)
screencapture -o -l "$WID" shot.png    # -o = no drop shadow
```

Recompute `WID` after any relaunch/reload; the id changes.

## Driving the UI

Open tabs with the bundled CLI (no page-load needed for favicons — background
tabs fetch them):

```sh
CLI="<path-to>/Browser.app/Contents/Helpers/browser-cli"
"$CLI" open --new https://example.com
"$CLI" tabs            # JSON list
```

UI states are keyboard shortcuts. Activate the app first (`open "$APP"`) so it's
frontmost, then `keypost`:

| State | Shortcut | keypost |
| --- | --- | --- |
| Hide tab bar | ⌥⌘` | `keypost 50 opt,cmd` |
| Minimal (favicons) | ⌥⌘1 | `keypost 18 opt,cmd` |
| Compact | ⌥⌘2 | `keypost 19 opt,cmd` |
| Wide | ⌥⌘3 | `keypost 20 opt,cmd` |
| Omnibar | ⌘K | `keypost 40 cmd` |
| Shortcut cheat sheet (toggle) | ⇧⌘H | `keypost 4 shift,cmd` |
| Hard reload (bypass cache) | ⇧⌘R | `keypost 15 shift,cmd` |
| Select tab 1 | ⌘1 | `keypost 18 cmd` |

The cheat sheet is a **toggle** — Escape does not close it (the WKWebView has
focus); press ⇧⌘H again. Leave ~0.6s between activate, keypost, and capture.

## Recursive (Droste) hero

Each pass makes the blog's hero image show the browser showing the blog, one
level deeper:

1. Capture the wide view → resize (`sips -Z 1920 in.png --out out.png`) →
   copy over `nathanfennel.com/public/images/blog/browser/01-wide.png`.
2. Commit + push. Vercel rebuilds the whole site even for one image (~2–4 min).
3. Poll the live asset until its `Content-Length` changes (same URL, new bytes):
   ```sh
   curl -sI https://nathanfennel.com/images/blog/browser/01-wide.png | grep -i content-length
   ```
4. Hard-reload the blog tab (⇧⌘R) so it fetches the new hero, then re-capture.
5. Repeat. Two baked levels already read as infinite; each further level is
   pixel-sized.

## Web-side notes

- Screenshots: `nathanfennel.com/public/images/blog/browser/*.png` (PNG keeps the
  cheat-sheet text crisp; `sips` on this Mac has no webp).
- Gallery component: `src/components/blog/browser-gallery.tsx`, registered in
  `src/components/blog/mdx-content.tsx`, used as `<BrowserGallery />` in the MDX.
- Verify before pushing to the production site: `PORT=3987 npm run dev` and fetch
  `/blog/straight-up-browser` for a 200.
