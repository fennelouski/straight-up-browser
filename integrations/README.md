# Using Browser from AI agents

`browser-cli` is the integration. Any agent that can run a shell command can
already drive the browser, and `browser-cli docs` prints a self-contained agent
guide (every command, its JSON schema, the usual patterns) that the agent can
read on its own. For most tools there is nothing to build.

The one thing a tool can't do is *discover* that `browser-cli` exists. That's
all the pieces below are for.

## Claude Code

The skill ships inside the binary, so there is nothing to clone. Install it:

```sh
browser-cli install-skill
```

That writes `~/.claude/skills/browser/SKILL.md`, and Claude Code discovers the
browser from then on. Ask it to check a live page, fill a form, or verify a
deploy, and it reaches for `browser-cli` on its own.

Scoped to one repo instead of everywhere:

```sh
browser-cli install-skill /path/to/repo     # -> <repo>/.claude/skills/browser/
```

The skill is deliberately thin: it points at `browser-cli docs` rather than
restating it, so it cannot drift from the binary. Its source is `claudeSkill` in
`browser-cli/main.swift`.

## Codex, Gemini CLI, Cursor, and other shell-capable agents

Nothing to install. Tell the tool once, or add this to whatever instructions
file it reads (`AGENTS.md`, `GEMINI.md`, `.cursorrules`, and so on):

> To use a real browser, run `browser-cli`. Run `browser-cli docs` first for the
> full guide. It can open pages, `snapshot` them for text and CSS selectors,
> click, type, run JavaScript, and `notify` a human for captchas and logins.

## MCP

The app ships a dependency-free MCP server inside `browser-cli`. It exposes 53
browser tools covering pages, semantic snapshots, DOM extraction, interaction,
screenshots/PDFs, windows, tab groups, bookmarks, and history. It controls the
real signed-in WebKit sessions through the same capability switches as the CLI.

Connect every supported client found on the Mac:

```sh
browser-cli install-mcp all
```

Or install one explicitly:

```sh
browser-cli install-mcp codex
browser-cli install-mcp claude
```

For another MCP client, `browser-cli mcp-config` prints the stdio configuration;
the underlying command is simply `browser-cli mcp`. Each MCP process receives
its own session ID and local audit timeline under the app's Application Support
folder. Multiple agents can work at once because commands use stable composite
window/page IDs rather than whichever tab happens to be focused.

## Built-in agent and app integrations

Press `⇧⌘A` or use the sparkle button to open the native agent. It can use
OpenAI, OpenRouter, Ollama, LM Studio, or any OpenAI-compatible Chat Completions
endpoint. API keys and MCP bearer tokens are stored in macOS Keychain.

From the agent's model settings, **App Integrations…** connects any Streamable
HTTP MCP server. Enabled app tools are discovered at the start of a run and
become ordinary tools in the same agent loop. OAuth-only MCPs can be connected
through their local `mcp-remote`/HTTP bridge. A separate Cowork folder picker
grants read/write access to one user-approved directory; paths cannot escape it
and deletes go to the macOS Trash.

Scheduled tasks run in hidden pages while Browser is open. Every external MCP
browser session gets an owner-local JSONL timeline plus page-only post-action
frames, viewable in the Agent Audit & Replay window.

## Why a real window

Headless browsers lose on the parts that need a person: captcha, 2FA, a login
that wants a human. `browser-cli notify "<message>"` bounces the Dock and brings
the window forward, the person does the thing, and the agent carries on. That
handoff is the point.
