---
name: browser
description: Drive a real macOS browser window (Straight Up Browser) from the terminal with browser-cli — open pages, read them with snapshot, click/type/run JavaScript, screenshot, and hand off to a human for captchas or logins. Use when a task needs a real browser: checking a live page, filling a form, working behind a login, or verifying a deployed site.
---

# Browser

`browser-cli` drives a real macOS browser window. Every command prints JSON to
stdout and exits 0 on success; errors print `{"error":"..."}` to stderr and exit
1. The app launches automatically if it isn't running.

## Read the real docs first

```sh
browser-cli docs
```

That prints the full, self-contained agent guide: every command, its JSON
schema, and the usual patterns. It ships with the binary, so it is the source of
truth. This file is only the pointer.

## The loop

```sh
browser-cli open --new https://example.com
browser-cli wait
browser-cli snapshot                            # title, text, CSS selectors
browser-cli click '#more-info' && browser-cli wait
browser-cli snapshot                            # observe what changed
```

`snapshot` is how you see a page cheaply: a compact outline with selectors for
everything interactive, not a megabyte of raw HTML. Reach for `get` only when
you genuinely need the full page JSON (html, text, links, images, meta).

Interacting: `click <selector>`, `type <selector> <text>`, `js <code>`.
Use `click --real` when a page needs a genuine mouse event (enable it first in
Settings > Security).

## Hand off to the human

When you hit a captcha, a login, or 2FA, do not guess. Ask:

```sh
browser-cli notify "Please solve the captcha, then leave the window open"
```

Then poll until they're done and continue:

```sh
browser-cli js 'document.querySelector(".g-recaptcha") === null'
```

It is a real window, so a person can take over and hand it back.

## Notes

- Commands act on the ACTIVE tab. `browser-cli tabs` lists tabs (1-based
  `index`); `browser-cli switch <index>` targets another.
- `browser-cli wait [seconds]` blocks until the page finishes loading. Use it
  after anything that navigates, before you snapshot.
- If `browser-cli` isn't on PATH, it ships inside the app bundle:
  ```sh
  sudo ln -sf "/Applications/Browser.app/Contents/Helpers/browser-cli" /usr/local/bin/browser-cli
  ```
