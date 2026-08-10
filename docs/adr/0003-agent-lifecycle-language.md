# AI executions are Runs, not browser Sessions

Status: Accepted

Straight Up Browser already uses **Session** for a website-data isolation
container. A `BrowserSession` determines the `WKWebsiteDataStore` and therefore
cookie/storage boundaries for normal, persistent container, and incognito Tabs.
MCP also uses the word session for parts of its transport lifecycle, while an
AI UI may casually call a conversation or execution a session.

AI lifecycle code uses three distinct terms:

- `AgentConversation` is the user-visible thread of prompts and responses.
- `AgentRun` is one bounded execution of one prompt, including model calls,
  tools, approvals, and a terminal or interrupted status.
- `AgentStep` is one immutable event inside a Run.

`BrowserSession` remains reserved for browsing-data isolation. A run records
which Browser Sessions its Page targets belong to, but never owns or replaces
them. `MCPConnection` names stored remote endpoint configuration; a short-lived
MCP transport session stays an implementation detail and must be qualified as
such when exposed in logs or types.

## Considered options

- **AgentSession for an execution** — rejected because permission rules such as
  “cross-session access” would become dangerously ambiguous: they could refer
  to crossing website-data containers or merely continuing an AI execution.
- **Task for every execution** — rejected because `AgentTaskDefinition` already
  describes reusable scheduled work, while Swift concurrency also uses `Task`.
- **Conversation as execution** — rejected because one conversation can contain
  many prompts/runs, retries, or resumed interrupted work.

## Consequences

- Persistence, UI labels, analytics, and APIs must prefer Conversation, Run,
  and Step even if a provider calls its own object a session or thread.
- Migration code may read legacy directories such as `agent-conversations/`
  and `agent-audit/`, but new stores use run-oriented names.
- Authorization scopes bind to a Run and concrete targets. Browser Session ID
  remains an independent dimension in that scope.
- A multi-agent parent is an `AgentRunGroup`; it is not a TabGroup,
  browser Session, or Split.
