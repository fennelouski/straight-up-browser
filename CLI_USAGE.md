# Browser CLI

Control the browser from the terminal — built so an AI agent can drive it
end-to-end (navigate, read pages, click, type, screenshot) and hand off to a
human when needed (captcha, 2FA). `browser-cli docs` prints a self-contained
agent guide; this file is the human-oriented version.

## Install

The tool ships inside the app bundle. Put it on your PATH once:

```bash
sudo ln -sf "/Applications/Browser.app/Contents/Helpers/browser-cli" /usr/local/bin/browser-cli
```

For development, `./build-cli.sh` still produces a standalone `./browser-cli-tool`.

## Contract

- Every command prints JSON to **stdout** (`{"ok":true,...}`) and exits **0**
  on success.
- Errors print `{"error":"..."}` to **stderr** and exit **1**.
- If the browser isn't running, any command **launches it automatically** and
  waits for it to come up. (First-ever launch shows a EULA a human must accept.)
- Commands act on the **active tab** — `switch` first to target another tab.
- Acks mean "accepted", not "page loaded" — follow navigation with `wait`.

## Commands

| Command | What it does |
|---|---|
| `open [--new] <url>` | Navigate the active tab (`--new`: open a new tab) |
| `search <query>` | Web-search the query |
| `back` / `forward` / `reload` | History navigation / reload |
| `wait [seconds]` | Block until the page finishes loading (default 15s); prints final url/title |
| `new` / `close` | Create / close the active tab |
| `tabs` | Print open tabs as JSON (1-based `index`) |
| `switch <index>` | Make tab `<index>` active |
| `snapshot` | Compact plain-text outline: URL, title, interactive elements with CSS selectors, page text — the cheap way for an agent to "see" the page |
| `screenshot [--full-page] [--clipboard] [--shared] [path]` | Save a PNG of the active tab (default `./screenshot.png`). `--full-page` captures the whole scrollable document instead of just the visible viewport; `--clipboard` also copies it to the system clipboard; `--shared` also drops a copy in the app's Shared Screenshots folder (Settings → Screenshots) |
| `get [url\|current]` | Full page JSON (`html`, `text`, `links`, `images`, `metaTags`); with a URL it loads offscreen without touching your tabs |
| `js <code>` | Run JavaScript in the active tab; prints `{"ok":true,"result":...}` |
| `click <selector>` | Click an element (JavaScript click) |
| `click --real <selector>` | Genuine mouse event at the element's screen position — counts as a user gesture. Opt-in: Settings → Security → CLI Automation, plus a one-time macOS Accessibility grant |
| `type <selector> <text>` | Set an input's value natively and fire `input`/`change` (framework-managed inputs update) |
| `notify <message>` | Bounce the Dock, focus the window, show the message — "agent needs a human" |
| `focus` | Bring the browser window to the front |
| `help` | Command overview |
| `docs` | Full agent-oriented guide (markdown to stdout) |

### The agent loop

```bash
browser-cli open --new https://example.com
browser-cli wait
browser-cli snapshot                          # see the page + selectors
browser-cli click '#more-info' && browser-cli wait
browser-cli snapshot                          # observe the result
```

### Human handoff (captcha etc.)

```bash
browser-cli notify "Please solve the captcha, then leave the window open"
# poll until the human is done, then continue:
browser-cli js 'document.querySelector(".g-recaptcha") === null'
```

## Wiring it into an AI tool

`browser-cli docs` is self-contained, so any agent that can run a shell command
needs nothing installed. For Claude Code, one command teaches it the browser
exists:

```bash
browser-cli install-skill        # writes ~/.claude/skills/browser/SKILL.md
```

See [integrations/](integrations/README.md) for notes on Codex, Gemini CLI,
Cursor, and why there's no MCP server.

## How it works

The app creates a named pipe (FIFO) at:

```
~/Library/Application Support/Straight Up Browser/cli.pipe
```

with owner-only permissions (`prw-------`). Filesystem permissions *are* the
authentication — only your user account can send commands. The CLI writes one
command per line to that pipe; structured payloads (`js` code, selectors) are
base64-encoded so anything survives the line protocol.

Every command passes a response filename; the app writes the result into its
own response directory (`.../Straight Up Browser/responses/`) — JSON, or raw
PNG for `screenshot` — which the CLI reads and deletes. The app only writes
inside that directory; it will not accept an arbitrary path from the pipe.

You can also drive it from plain shell, one command per line:

```bash
echo "open https://example.com" > ~/Library/Application\ Support/Straight\ Up\ Browser/cli.pipe
```

## Build

The Xcode build compiles and signs the helper into
`Browser.app/Contents/Helpers/browser-cli` automatically (Run Script phase
"Build browser-cli helper"). For a quick standalone binary:

```bash
./build-cli.sh          # produces ./browser-cli-tool
```
