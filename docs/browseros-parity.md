# BrowserOS AI parity

This map tracks the AI/browser functionality advertised by BrowserOS and
BrowserOS neo as checked on 2026-08-09 against BrowserOS source commit
`5ddb0f`. Straight Up Browser keeps its WebKit-native architecture and reuses
the user's real tabs, sessions, cookies, and windows—there is no debug browser
or automation-only profile.

## Agent surfaces

| BrowserOS capability | Straight Up Browser implementation |
|---|---|
| Browser MCP for Codex, Claude Code, Cursor, and other clients | Bundled dependency-free stdio MCP server; `browser-cli install-mcp codex`, `claude`, or `all`, plus `mcp-config` for every other client |
| 53 browser tools | The same 53-tool functional catalogue: 8 navigation/page, 8 observation, 14 interaction, 3 file/export, 5 window, 5 tab-group, 6 bookmark, and 4 history tools |
| Real signed-in browser | Commands route into the live `WKWebView` instances and their existing session data stores |
| Parallel agents/background tabs | Stable `windowUUID:tabUUID` page IDs, background/hidden pages and windows, and per-request routing; focus is never required to address a page |
| Built-in browser agent | Native `⇧⌘A` side panel with streaming model output, visible tool and approval steps, cancellation, durable conversations/Runs, scoped memory, and hard resource budgets |
| Bring your own AI / local models | Direct OpenAI, OpenRouter, Ollama, LM Studio, and arbitrary OpenAI-compatible endpoints, plus normalized OpenAI Responses, Anthropic Messages, and Gemini generateContent adapters; provider secrets stay in Keychain |
| External app integrations | Generic Streamable HTTP MCP with bounded discovery/calls, collision-safe dynamic tool names, explicit trust versions, Keychain bearer/OAuth tokens, and OAuth 2.1 + S256 PKCE through `ASWebAuthenticationSession` and a one-shot ephemeral `127.0.0.1` callback |
| Cowork with browser and files | File tools scoped to a user-selected security-scoped folder, with path/symlink/alias/hard-link containment, bounded staging, preview and approval, atomic commit, retained prior versions, and rollback |
| Scheduled tasks | Editable daily/interval tasks with captured provider, browser, MCP, Cowork, budget, timeout, catch-up, overlap, notification, and retention policies; hidden-page execution remains limited to times when Browser can run |
| Multi-agent delegation | Bounded child Runs with explicit contracts, least-privilege authority, shared parent budgets, Page read/write leases, hidden child-created Pages, cancellation propagation, and structured handoff |
| Audit and replay | One append-oriented Agent Run timeline for attended, scheduled, MCP, and child execution, with approval/usage/limit/artifact events, replay frames, redaction, retention, deletion, and local diagnostic export |
| Scoped memory | Opt-in, reviewable facts and preferences scoped by origin/task/conversation and persistent browser Session, with provenance, sensitivity review, expiry, independent deletion, and no incognito use by default |
| WebKit-native signals | Bounded, run-scoped observation/waits for supported navigation, TLS, console, dialog, and download lifecycle data; console text and diagnostic text are separately opt in, and unavailable CDP details are explicitly unsupported |
| Definition sync | Separately opt-in private CloudKit sync for schedule definitions, nonsecret provider presets, and user-authored memory; local dependency/policy gates prevent imported definitions from executing automatically |
| Human handoff | Real visible pages for login, captcha, 2FA, and consequential confirmations; CLI `notify` can foreground the browser |
| Local privacy | No Browser telemetry or hosted agent proxy. Model requests go directly to the configured provider; metrics, Run evidence, replay, and redacted diagnostics stay on device unless the user explicitly exports them |

## Browser automation catalogue

The MCP server exposes these BrowserOS-compatible tools:

- Navigation/pages: `get_active_page`, `list_pages`, `navigate_page`,
  `new_page`, `new_hidden_page`, `show_page`, `move_page`, `close_page`
- Observation: `take_snapshot`, `take_enhanced_snapshot`, `get_page_content`,
  `get_page_links`, `get_dom`, `search_dom`, `take_screenshot`,
  `evaluate_script`
- Interaction: `click`, `click_at`, `hover`, `focus`, `fill`, `clear`,
  `check`, `uncheck`, `select_option`, `press_key`, `drag`, `scroll`,
  `upload_file`, `handle_dialog`
- Export/files: `save_pdf`, `save_screenshot`, `download_file`
- Windows: `list_windows`, `create_window`, `create_hidden_window`,
  `close_window`, `activate_window`
- Groups: `list_tab_groups`, `group_tabs`, `update_tab_group`,
  `ungroup_tabs`, `close_tab_group`
- Bookmarks: `get_bookmarks`, `create_bookmark`, `remove_bookmark`,
  `update_bookmark`, `move_bookmark`, `search_bookmarks`
- History: `search_history`, `get_recent_history`, `delete_history_url`,
  `delete_history_range`

The native side-panel agent uses the same primitives and adds canonical tools
for observable waits, staged Cowork transactions, delegated Runs, scoped
memory, WebKit signals, and trusted connected apps. Those additions do not
alter the public names or required arguments of the compatibility catalogue:
the bundled browser MCP profile remains exactly 53 tools.

## Engine/platform boundary

The remaining implementation differences follow directly from WebKit/macOS
rather than the agent feature surface:

- Chrome extensions cannot run in WebKit. Straight Up Browser loads unpacked
  `WKWebExtension` packages and exposes the corresponding WebKit feature set.
- Chromium/CDP-specific debugging, emulation, and profile-import internals do
  not exist in WebKit; BrowserOS itself lists several debugging/performance
  tools as future work rather than part of its 53-tool browser catalogue.
- `WKWebView` exposes main-navigation, delegate, download, dialog, and injected
  console observations, not a complete subresource request waterfall. Missing
  CDP-style request IDs, cache internals, bodies, and timing details are
  returned as unsupported rather than synthesized.
- Browser cannot expose passkeys until Apple grants the third-party-browser
  WebAuthn entitlement, and it does not attempt to decrypt another browser's
  password vault. Bookmarks can be imported normally.
- macOS owns agent execution, external MCP OAuth, scheduled automation, Cowork,
  and child-run Page control. iPhone and iPad can sync, retain, and review safe
  definitions but never attempt macOS-only execution. A receiving Mac must
  still satisfy its own provider, MCP, Cowork, browser-Session, capability, and
  policy gates before it can materialize runnable work.

On macOS, these WebKit boundaries do not change the agent's ability to observe,
interact with, export from, parallelize, schedule, or replay work in the live
browser.

The implementation architecture and release-acceptance contract are documented
in the [AI tooling guide](ai/README.md).
