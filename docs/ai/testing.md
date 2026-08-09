# AI tooling testing strategy

Agent tests must verify effects and authority, not just that a model produced a
plausible sentence. Provider responses should be deterministic fixtures; live
paid-model tests are optional smoke tests and never the only gate.

## Test layers

### Pure contract tests

Run without WebKit or network access:

- render the canonical catalogue to built-in function tools and MCP `tools/list`;
- validate every accepted/rejected argument fixture against JSON Schema;
- normalize provider streaming fixtures into identical model events;
- exercise run-state transitions, recovery, budgets, and cancellation;
- evaluate policy matrices for attended/scheduled, origin, browser Session,
  Cowork path, external MCP identity, and risk class;
- encode/decode every persisted type and migrate the oldest supported fixture;
- verify redaction and retention calculations.

Golden fixtures should be human-readable JSON under a dedicated test-fixture
directory. Changing a golden file requires a compatibility note in the pull
request.

### Executor integration tests

Use existing browser managers with local deterministic pages:

- resolve stable Page handles across multiple windows and browser Sessions;
- observe, navigate, fill, click, wait, download, and handle dialogs;
- invalidate element references after navigation or DOM replacement;
- confirm hidden Pages do not steal focus;
- enforce Page read/write leases and cancellation;
- exercise Cowork containment with nested symlinks, aliases, Unicode paths,
  large files, and atomic overwrite recovery;
- run a fake MCP server for initialize, tool discovery, streaming responses,
  schema changes, authentication failures, timeouts, and oversized results.

Tests use loopback servers and temporary directories. They never depend on a
public website or a developer's Keychain.

### Run-engine scenario tests

A scripted provider fixture emits text, tool calls, retries, malformed calls,
and usage events. Cover complete stories:

1. attended read-only research succeeds;
2. risky form submission pauses, is approved once, and resumes;
3. denial returns a tool result and the run continues or ends honestly without
   claiming the denied effect happened;
4. prompt injection asks for an out-of-scope file and policy denies it;
5. cancellation during provider streaming prevents tool execution;
6. app interruption leaves a recoverable run and explicit resume continues;
7. scheduled work requiring approval becomes `waitingForHuman` without a modal;
8. provider timeout/retry never repeats an already executed mutation;
9. a child run exhausts the shared budget and all siblings stop cleanly;
10. incognito execution retains no content under default policy.

Assert stored steps, policy decisions, effects in the fake page/service, and
the final run status for every scenario.

### UI and accessibility tests

Verify the user can:

- distinguish running, waiting, stopped, interrupted, failed, and succeeded;
- inspect the target and data egress before approving;
- deny, cancel, resume, and delete with keyboard-only navigation;
- review provider/tool identity and cost/usage;
- scrub replay and identify the exact step associated with a frame or artifact;
- configure retention and revoke MCP connections/memory;
- use VoiceOver labels for tool calls, approval choices, progress, and errors.

No UI test should require a real provider. Launch arguments inject the scripted
adapter and an isolated store.

## Compatibility gates

AI-001 establishes a checked-in catalogue snapshot. CI must fail when:

- a stable tool disappears or changes required arguments without a major tool
  version and migration;
- built-in and MCP renderings disagree;
- the BrowserOS-compatible catalogue no longer contains exactly the documented
  53 tools unless the parity document is intentionally revised;
- a compatibility alias maps to more than one canonical tool;
- a tool lacks risk, capability, input schema, output schema, or implementation
  routing metadata.

Additive optional properties are compatible. Description improvements are
compatible but still reviewable because model behavior can change.

## Failure and recovery matrix

Each new provider, tool category, or persistence feature should cover:

| Failure | Expected result |
|---|---|
| Browser window or Page disappears | Structured target-not-found result; no fallback to another Page |
| Navigation replaces the document | Old element references fail stale |
| Provider stream truncates | Run fails or retries before any uncommitted action |
| MCP server changes schema | Trust version changes; prior grants do not apply |
| Approval expires | Invocation is cancelled, not silently retried |
| App terminates mid-write | Previous file or atomic new file remains valid |
| App terminates mid-run | Run becomes interrupted on recovery |
| Disk full / store unavailable | Execution stops before unrecorded risky actions |
| Budget exhausted | Terminal limit event and no further calls |
| User cancels | Provider, wait, tool, and child work receive cancellation |

## Performance budgets

Measure with deterministic fixtures and record regressions:

- catalogue render and policy decision: less than 10 ms at p95;
- append a metadata-only step: less than 20 ms at p95 without blocking the
  main actor;
- panel first token display: no additional buffering beyond provider delivery;
- compact snapshot on the standard fixture: less than 500 ms;
- run-history list: less than 200 ms for 1,000 runs using indexes only;
- cancellation acknowledgement: less than 250 ms for waits and provider calls
  under local test control.

These are engineering budgets, not promises about remote model or website
latency.

## Verification workflow

During development, run the narrow unit/integration target first. Before merge:

```bash
./scripts/verify.sh
```

Security-sensitive changes also require manual inspection of a redacted
diagnostic export and the app's Application Support directory to confirm file
permissions, retention, and absence of Keychain values. A provider or MCP
change should be tested against a loopback fixture plus one opt-in real endpoint
outside CI.
