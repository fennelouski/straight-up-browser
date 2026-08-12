# AI tooling testing strategy

Agent tests must verify effects and authority, not just that a model produced a
plausible sentence. Provider responses should be deterministic fixtures; live
paid-model tests are optional smoke tests and never the only gate.

This file defines required coverage. It intentionally does not claim that the
current release gates passed; record commands and results in the release handoff
only after they actually run.

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
- validate Run Group authority/budget subset rules, depth/fan-out ceilings,
  handoff schemas, lease conflicts, and shared-ledger arithmetic;
- rank memory deterministically with origin/task/conversation and persistent
  browser-Session scopes, then verify expiry and non-enumerating deletion;
- encode only the definition-sync allowlist and resolve revision/tombstone
  conflicts without leaking forbidden fields.

Golden fixtures should be human-readable JSON under a dedicated test-fixture
directory. Changing a golden file requires a compatibility note in the pull
request.

Load them with `TestFixture.data(_:)`, which reads from the test bundle — the
synchronized test folder copies `Straight Up BrowserTests/Fixtures/` in
automatically. Never read a fixture from the source tree via `#filePath`: the
test host is sandboxed without a Documents entitlement, so a checkout under
`~/Documents` makes the read wait on a TCC prompt it cannot display. The test
then dies at its time limit as "Time limit was exceeded", which reads as a hung
test and points nowhere near the real cause.

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
  schema changes, authentication failures, timeouts, and oversized results;
- drive a real ephemeral `127.0.0.1` OAuth callback fixture through discovery,
  S256 PKCE, state validation, token exchange, refresh, 401 retry, revocation,
  and exact logical-invocation idempotency;
- stage/preview/commit/cancel/rollback Cowork transactions and prove that
  interrupted commits leave either the complete prior or new file;
- feed WebKit-native navigation, TLS, console, dialog, and download events into
  bounded Page/Run buffers and assert unsupported CDP fields remain unsupported.

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
11. a child-created hidden Page never steals focus and is closed by group
    cancellation without closing user-owned Pages;
12. a synced task remains inactive until local provider, MCP, Cowork,
    browser-Session, capability, and scheduled-policy dependencies pass.

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
- disable each sync category with keep-local and delete-cloud choices, cancel
  the decision, re-enable it, and revoke a locally authorized schedule;
- review a synced sensitive memory item before it becomes retrievable;
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

The native built-in profile may contain more than 53 tools. The compatibility
gate counts only the BrowserOS MCP visibility profile and separately checks that
native additions do not collide with its public names.

## Failure and recovery matrix

Each new provider, tool category, or persistence feature should cover:

| Failure | Expected result |
|---|---|
| Browser window or Page disappears | Structured target-not-found result; no fallback to another Page |
| Navigation replaces the document | Old element references fail stale |
| Provider stream truncates | Run fails or retries before any uncommitted action |
| MCP server changes schema | Trust version changes; prior grants do not apply |
| MCP mutation receives one 401 | Refresh once and retry with the same invocation key; never replay again automatically |
| Approval expires | Invocation is cancelled, not silently retried |
| App terminates mid-write | Previous file or atomic new file remains valid |
| App terminates mid-run | Run becomes interrupted on recovery |
| Disk full / store unavailable | Execution stops before unrecorded risky actions |
| Budget exhausted | Terminal limit event and no further calls |
| User cancels | Provider, wait, tool, and child work receive cancellation |
| Synced schedule lacks a local dependency | Definition remains visible but is not installed as runnable work |
| Sync category is disabled with cloud deletion | Monotonic tombstones publish; usable local payload remains available for opt-in re-publication |
| Incognito signal scope ends | Content-rich buffered signals are cleared |

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

For changes to the universal iPhone/iPad app, also run its independent local
release gate:

```bash
./scripts/verify-ios.sh
```

That gate builds generic device and simulator products, runs mobile contract
tests, and executes compact UI smoke coverage on both form factors. Neither
gate uses GitHub-hosted Actions.

Security-sensitive changes also require manual inspection of a redacted
diagnostic export and the app's Application Support directory to confirm file
permissions, retention, and absence of Keychain values. Inspect the private
CloudKit codec or captured fixture to confirm its field allowlist. A provider
or MCP change should be tested against a loopback fixture plus one opt-in real
endpoint outside CI.

For Browser 2.0, the focused suites cover catalogue compatibility, Run store and
legacy import, policy, provider adapters/transport, semantic references and
waits, timeline/replay, schedules, MCP trust/loopback OAuth/integration, Cowork
transactions, Run Groups, memory, observability, WebKit signals, definition
sync, and Agent Settings. The release owner must still run the full macOS test
suite, Release builds, UI-build gates, security-policy validation, signing,
notarization, and published-artifact checks before changing feature status to
**Complete**.

## Browser 2.0 macOS acceptance record

This historical acceptance run covered the macOS 2.0.0 distribution. On
2026-08-10 it produced the following evidence before source integration and
signing:

- all 420 macOS unit/integration tests passed with warnings as errors;
- `Browser.app` line coverage was 44.96% against the 25% floor;
- Thread Sanitizer passed 418 tests in one run, and the two instrumentation-
  sensitive Run Group cases passed in a focused TSAN rerun after their sleep-
  based overlap probe was replaced by a bounded two-child rendezvous;
- macOS Release built as arm64-only, including `browser-cli`, and reported
  version 2.0.0 build 55;
- the universal mobile Release target compiled with warnings as errors,
  confirming that the shared safe-definition code remained buildable; mobile
  shipping acceptance was outside that historical macOS gate;
- CI, release, security, exact-53-tool, focused migration/recovery/privacy,
  loopback OAuth/MCP, Cowork, settings, and replay policy gates passed.

The macOS UI target compiled, including the Agent-pane grouping assertion. The
pre-release executable UI attempt did not initialize because the host Xcode UI
automation service timed out while enabling automation mode; no application
test or assertion ran. The exact tagged release gets one final macOS UI attempt
inside `release.sh`. If the host service remains unavailable, record that
infrastructure result alongside the successful compiled UI contract and direct
app smoke check rather than treating it as an application failure.

The independent iPhone/iPad release acceptance is enumerated in the
[roadmap](roadmap.md#iphone-and-ipad-release-acceptance) and the
[mobile deployment guide](../../IOS_DEPLOYMENT.md). It includes executable
UI/accessibility checks on both form factors, real-device and private-CloudKit
round trips, App Store signing/provisioning, TestFlight upgrade, and separate
release approval. None is implied by the macOS notarized DMG.
