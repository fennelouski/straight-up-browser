# AI tooling security and privacy

## Security objective

An agent may observe and manipulate the user's real signed-in web state, local
files, and connected services. Its authority must come from browser settings and
the user's current approval—not from model output, page text, an MCP tool
description, or a previous run.

The desired property is **bounded agency**: the user can predict the maximum
effect of a run, inspect what happened, stop it, and delete the resulting local
record without exposing unrelated browser data.

## Trust boundaries

| Boundary | Treat as | Required control |
|---|---|---|
| Model endpoint | External processor that sees the submitted context | Explicit provider configuration, TLS, Keychain secret, context minimization |
| Web page and DOM | Hostile input that may contain prompt injection | Separate instructions from observations; never derive authority from content |
| External MCP server | Third-party code and service principal | Connection identity, per-tool policy, scoped auth, visible data-egress warning |
| MCP/CLI client | Another local process running as the user | Owner-only IPC plus existing capability switches and audit identity |
| Cowork folder | User-approved local scope containing potentially sensitive data | Security-scoped bookmark, canonical-path and symlink containment, write approval |
| Browser managers and WebKit | Privileged in-process executor | Main-actor isolation, validated targets, no direct model access |
| Run/audit store | Sensitive local evidence | Owner-only permissions, redaction, retention controls, no CloudKit by default |

## Threat model

The design must address at least these threats:

1. **Indirect prompt injection.** A page, PDF, file, email, or MCP result tells
   the model to ignore the user and exfiltrate data or perform an action.
2. **Confused deputy.** A low-risk observation supplies data to a higher-risk
   external tool without the user understanding the cross-boundary transfer.
3. **Over-broad approval.** Consent for one host, file, or tool silently applies
   to another target or future run.
4. **Target substitution.** The DOM changes between observation, approval, and
   action, so a click or submit affects a different element.
5. **Cross-Session leakage.** Content or cookies from one `BrowserSession`
   influence a run operating in another isolation container.
6. **Malicious MCP metadata.** Tool names/descriptions misrepresent effects,
   collide with built-in names, or return oversized/secret-laden results.
7. **File escape.** Traversal, aliases, hard links, or symlinks move a Cowork
   operation outside the approved root.
8. **Secret persistence.** API keys, authorization headers, form values, or
   page content leak into logs, screenshots, diagnostics, or sync.
9. **Unattended escalation.** A scheduled run waits for or implicitly grants an
   approval that would require an attended user.
10. **Resource exhaustion.** A provider or tool loop consumes unbounded time,
    tokens, storage, Pages, downloads, or external requests.

Out of scope: defending a user who intentionally grants broad authority to a
malicious model endpoint, OS compromise, and weaknesses inside WebKit or macOS.
The UI must still make those grants understandable and revocable.

## Authority model

Authority is the intersection of four layers:

1. **Static capability** — Security settings enable a class such as page read,
   interaction/JavaScript, screenshots, file access, or external MCP.
2. **Run scope** — the run records allowed Page handles, origins,
   `BrowserSession` identifiers, Cowork root, MCP connections, budgets, and
   whether a human is present.
3. **Invocation decision** — the policy engine evaluates the concrete resolved
   target and arguments immediately before execution.
4. **Destination enforcement** — WebKit, path containment, MCP auth scopes, and
   service APIs constrain the actual operation.

A broad layer never compensates for a missing narrower layer. For example,
enabling interaction globally does not authorize a scheduled run to submit a
purchase, and a model saying an action is safe does not bypass path containment.

## Risk classes

| Class | Typical operations | Default behavior |
|---|---|---|
| Observe | List Pages, snapshot, read DOM, list Cowork files | Allow only within run scope; mark sensitive sources |
| Navigate | Open/focus/close a Page, load a URL, scroll | Allow attended; restrict origins and Page count for schedules |
| Mutate local | Fill form, alter bookmarks/history, write or move a file | Allow if explicitly requested and policy-scoped; otherwise approval |
| External effect | Submit/send/publish, upload, download, call mutating MCP tool | Require contextual approval unless the run definition names the exact effect and target |
| Destructive/financial/auth | Delete durable data, purchase, change permissions, expose credentials | Always attended confirmation; deny for scheduled runs by default |
| Prohibited | Read Keychain secrets, export cookies/tokens, bypass captcha/2FA, disable security controls | Do not expose a tool |

Observation is not automatically harmless: reading a banking page and passing
it to an external MCP tool is data egress. Policy evaluates the information
flow as well as each tool in isolation.

## Approval design

An approval request shows:

- the run and requesting model;
- exact tool and server identity;
- human-readable effect and normalized arguments;
- target origin, Page title, `BrowserSession` label, file path, or service;
- what data leaves the device;
- whether the target changed since the last observation;
- available scopes: allow once, allow this exact target for this run, or deny.

“Always allow” is not offered from an invocation dialog. Persistent grants live
in Settings, where they can show and revoke their complete scope.

Approvals expire, bind to an invocation digest, and are invalidated when the
resolved origin, element identity, file canonical path, MCP server identity, or
arguments change. The run releases Page leases while waiting.

Scheduled runs cannot display a modal and continue as if approved. They record
`waitingForHuman`, notify the user, and stop or expire according to policy.
Opening the task later creates an attended resume that revalidates all targets.

## Prompt-injection controls

- System/developer instructions, user requests, and tool observations remain
  separate typed message parts in the provider-neutral transcript.
- Every observation is labeled with its source: origin, file path, or MCP
  connection/tool. Do not concatenate it into system instructions.
- Tool results cannot add capabilities, change budgets, or approve another
  tool. Such text remains untrusted content.
- Before data crosses from one source to another destination, policy evaluates
  the transfer and the UI describes it when approval is required.
- The agent should prefer minimal reads. Snapshot a relevant subtree or read a
  requested file instead of sending an entire DOM or folder tree.
- Do not claim prompt injection can be solved by a prompt. Enforcement lives in
  typed scopes, policy, target resolution, and destination controls.

## Browser and Page isolation

- Resolve every PageHandle to a live Tab immediately before acting.
- Record its window ID, Tab ID, URL origin, and `BrowserSession` ID in the
  invocation context.
- A run that creates an incognito Page must not persist its page content,
  screenshot frames, URL, form values, or extracted text unless the user opts
  in for that run. Metadata should be minimized and deleted at completion.
- Cross-Session reads require an explicit run scope; background discovery must
  not sweep every container just because `list_pages` can enumerate them.
- Element references include a document/navigation generation. Reject stale
  references instead of falling back to a coincidentally matching selector.
- Captcha, login, passkey, and 2FA flows use visible human handoff. The agent
  must not imitate or bypass those controls.

## Cowork safety

Retain the current security-scoped bookmark and recoverable Trash deletion, and
add these invariants for future tools:

- canonicalize the root and target after resolving symlinks at the time of each
  operation;
- reject a target on another volume or outside the root, including through
  aliases and hard-link policy where detectable;
- never accept absolute paths from the model for scoped tools;
- preview overwrites and structured-file mutations as a diff;
- use atomic replace for writes and preserve the previous version as a
  recoverable artifact until the run's retention window expires;
- apply byte, file-count, recursion, and decompression limits;
- treat file content as untrusted input and redact it from ordinary logs.

## MCP connection safety

- Pin a connection record to normalized HTTPS endpoint and server identity.
  Loopback HTTP is allowed for local bridges; other cleartext HTTP is rejected.
- Use MCP capability negotiation and protocol-version checks. An incompatible
  server fails closed.
- Namespace model-visible names, but display the original server/tool identity
  during approval and replay.
- Sanitize descriptions and schemas as untrusted metadata. Enforce local size,
  depth, and name limits.
- Store bearer and OAuth refresh tokens only in Keychain. Never include tokens
  in connection exports, run records, errors, or model context.
- Record the effective OAuth scopes and make reauthorization/revocation
  explicit.
- A changed endpoint, server identity, tool schema, or OAuth scope invalidates
  grants made for the prior connection version.

## Data handling and retention

Classify persisted data before writing it:

| Data | Default storage | Sync default | Logging |
|---|---|---|---|
| Provider/MCP secrets | Keychain | Never | Never |
| Run metadata and policy decisions | Local run store | Off | IDs/status only |
| Prompts and model text | Local run store | Off | Never |
| DOM/file/MCP content | Referenced local artifact when needed | Never | Never |
| Replay frames | Local run artifacts | Never | Path/size only |
| Schedule definitions | Local settings | Off until AI-014 | Name/status only |
| User-approved memory | Local scoped memory store | Off | IDs/scope only |

Users need controls to delete one run, one conversation, all agent history, all
memory, and all data for one MCP connection. Retention settings should include
never, 24 hours, 7 days, 30 days, and until manually deleted. Deletion must
remove indexes, artifacts, frames, and orphaned temporary files.

Diagnostic export is opt-in, previewable, and redacted by default. It replaces
URLs with origins where possible, removes query strings and fragments, omits
content bodies and screenshots, and never exports secrets.

## Resource limits

Every run has hard limits for model turns, tool calls, elapsed time, output
bytes, open background Pages, artifact bytes, and optional provider cost.
Child runs consume the parent's budget. Provider retries use bounded backoff and
do not repeat a non-idempotent tool invocation.

Hitting a limit creates a terminal or waiting step with a clear reason. It must
not be reported as successful completion.

## Required security tests

Before a feature may execute tools, tests must demonstrate:

- prompt text in a page or file cannot grant a capability;
- a stale or substituted target invalidates approval;
- scheduled destructive and financial actions stop for a human;
- symlink/path traversal cannot escape Cowork scope;
- secrets and sensitive payloads are absent from logs and diagnostic export;
- grants do not cross origins, browser Sessions, MCP identities, or runs;
- cancellation prevents the next action and records a terminal state;
- incognito content is not retained under the default policy;
- size and step limits fail closed without freezing the browser.
