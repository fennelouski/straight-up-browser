# Straight Up Browser CLI

Control the running browser from the terminal.

## Build

```bash
./build-cli.sh          # produces ./browser-cli-tool
```

## Requirements

The browser must be **running with its window open**. The app registers its
command handlers when the window appears, so a fully background launch won't
respond.

## Commands

| Command | What it does |
|---|---|
| `open <url>` | Navigate the active tab to a URL |
| `search <query>` | Search for a query |
| `new` | Create a new tab |
| `close` | Close the active tab |
| `tabs` | Print open tabs as JSON |
| `get [url\|current]` | Print the current page's data as JSON |

### Examples

```bash
./browser-cli-tool open https://example.com
./browser-cli-tool search "swift concurrency"
./browser-cli-tool new
./browser-cli-tool tabs
./browser-cli-tool get current
```

`tabs` returns:

```json
{
  "tabs": [
    { "title": "Example Domain", "url": "https://example.com/", "active": true }
  ]
}
```

`get` returns the page's `url`, `title`, `html`, `text`, `links`, `images`, and
`metaTags`:

```bash
./browser-cli-tool get current | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])"
```

## How it works

The app creates a named pipe (FIFO) at:

```
~/Library/Application Support/Straight Up Browser/cli.pipe
```

with owner-only permissions (`prw-------`). Filesystem permissions *are* the
authentication — only your user account can send commands. The CLI writes one
command per line to that pipe.

Commands that return data (`get`, `tabs`) pass a response filename; the app
writes the JSON result into its own response directory
(`.../Straight Up Browser/responses/`), which the CLI reads and then deletes.
The app only writes inside that directory — it will not accept an arbitrary
path from the pipe.

You can also drive it from plain shell, one command per line:

```bash
echo "open https://example.com" > ~/Library/Application\ Support/Straight\ Up\ Browser/cli.pipe
```
