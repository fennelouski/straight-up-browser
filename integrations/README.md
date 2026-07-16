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

Not built. Shell already covers the tools above, so an MCP server only earns its
keep for something that speaks MCP and cannot run a shell command. The server
would wrap the same commands `browser-cli` already exposes.

## Why a real window

Headless browsers lose on the parts that need a person: captcha, 2FA, a login
that wants a human. `browser-cli notify "<message>"` bounces the Dock and brings
the window forward, the person does the thing, and the agent carries on. That
handoff is the point.
