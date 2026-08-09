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
| Built-in browser agent | Native `⇧⌘A` side panel with a bounded tool loop, visible tool steps, cancellation, persisted conversations, and explicit capability authorization |
| Bring your own AI / local models | Direct OpenAI and OpenRouter support, arbitrary OpenAI-compatible endpoints, Ollama, and LM Studio; provider secrets stay in Keychain |
| External app integrations | Generic Streamable HTTP MCP connections with dynamic tool discovery and optional Keychain bearer tokens; OAuth-only services work through their MCP remote bridge rather than a vendor-owned connector proxy |
| Cowork with browser and files | Six file tools scoped to a user-selected security-scoped folder; path/symlink containment, UTF-8 and size limits, and recoverable Trash deletion |
| Scheduled tasks | Daily, every-N-hour, and every-N-minute tasks; hidden-page execution, run/stop controls, bounded agent steps, and the latest 15 local results |
| Audit and replay | Append-only JSONL session/tool timelines plus post-action page frames, scrubber, step controls, and autoplay; stored only in the app container |
| Human handoff | Real visible pages for login, captcha, 2FA, and consequential confirmations; CLI `notify` can foreground the browser |
| Local privacy | No Browser telemetry or hosted agent proxy. Model requests go directly to the configured provider; MCP/browser audit data stays on disk |

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

The native side-panel agent uses the same primitives and additionally exposes a
page-load wait plus its scoped cowork-file and connected-app tools.

## Engine/platform boundary

The remaining implementation differences follow directly from WebKit/macOS
rather than the agent feature surface:

- Chrome extensions cannot run in WebKit. Straight Up Browser loads unpacked
  `WKWebExtension` packages and exposes the corresponding WebKit feature set.
- Chromium/CDP-specific debugging, emulation, and profile-import internals do
  not exist in WebKit; BrowserOS itself lists several debugging/performance
  tools as future work rather than part of its 53-tool browser catalogue.
- Browser cannot expose passkeys until Apple grants the third-party-browser
  WebAuthn entitlement, and it does not attempt to decrypt another browser's
  password vault. Bookmarks can be imported normally.

These boundaries do not change the agent's ability to observe, interact with,
export from, parallelize, schedule, or replay work in the live browser.
