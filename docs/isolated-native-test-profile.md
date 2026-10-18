# Isolated native acceptance profile

This is an explicit macOS test mode for synthetic native-controls acceptance. It is an app-owned resource boundary, not an operating-system sandbox or a substitute for release/runtime verification. Ordinary launches and ordinary component tests keep their existing defaults and injected stores.

Launch the exact candidate executable directly in a fresh instance with:

```
Browser.app/Contents/MacOS/Browser -isolatedTestProfile acceptance-<fresh-UUID> -ApplePersistenceIgnoreState YES
```

The identifier accepts 1–64 ASCII letters, numbers, hyphens and underscores, and cannot begin with a hyphen. Missing, duplicate, attached `=value`, unsafe or unavailable profiles exit 78 before production-store fallback. Every run requires a new identifier: existing roots and nonempty private defaults domains are rejected. The process owns a 0700 directory and exclusive 0600 lock under the app-writable temporary directory:

```
<temporaryDirectory>/Browser Isolated Test Profiles/<identifier>/
```

Do not assume `/tmp` for the signed sandboxed app. Obtain the actual path from the process's app-writable temporary directory or the nonsecret manifest. Do not select another process just because its bundle identifier is Browser's shipping identifier. The release owner must preserve the running production instance and protect LaunchServices registration/default handlers separately.

## Resources

All 286 app `@AppStorage` declarations and app-owned standard-defaults origins resolve through `BrowserProfile`. Its private suite is `com.nathanfennel.Browser.IsolatedTest.<identifier>`. Existing explicit component-test injections stay unchanged without the flag. The profile routes Application Support, caches, documents, downloads, file/history JSON, session interaction state, windows, layout recipes and Theme Authority to owned locations. SwiftData uses memory-only configurations with CloudKit `.none`. DocumentStore receives a local root before any ubiquity resolution or metadata query. A private-resource error never selects a production resource.

Every app-created WebKit configuration is prepared behind a scene barrier. Normal and container jars are separate, process-owned nonpersistent stores. Deny-first resource rules allow only loopback, bundled and owned-profile fixtures. Navigation also checks resolved file containment. Page JavaScript and automatic script popups are disabled; local plain HTML links, target=_blank, GET forms and downloads remain the intended fixture surface. Native isolated-world app DOM scripts are separate from page JavaScript. Native URLSession requests are rejected, including loopback; there is no native persistent cache, cookie or credential store.

Sparkle is not constructed. CLI listeners, pipes and external automation are disabled, and even static response writers reject profile mode. The private CLI namespace is reported for verification but should contain no live pipe. Credential Keychain entry points return unavailable before SecItem calls; Contacts/biometry/location/Focus access, cloud checks/sync, background scheduler activation, discovery/prefetch, extension handoffs, provider/model inference, translation downloads and external OAuth listeners are disabled. The native resource inventory check is a source guard audit, not a claim that every runtime branch executed.

External URL/file Apple events, system file choosers, imports/exports, screen capture and external-app/Finder handoffs are disabled. App-owned clipboard actions use a named private pasteboard. Acceptance must use synthetic typed input; OS text-editing services and external drag/drop are outside acceptance coverage. No credentials, cookies, history contents or production URLs/titles belong in receipts.

## Identity and manifest lifecycle

Every browser/auxiliary scene is gated and labelled `ISOLATED [<identifier>]`, with accessibility identifier `isolated-test-profile-label`. Window titles contain the same profile marker. Agent/integration scenes and the external-agent Settings pane display an unavailable view before constructing their integration UI. Auxiliary scene restoration is disabled only in explicit profile mode.

`isolation-manifest.json` is atomically written inside the owned root. Schema 1 includes:

- `mode`: `isolated-native-test`; `identifier`; `pid`; `ready`.
- `bundleIdentifier`, `version`, `build`, `executableSHA256`: actual running bundle/executable identity.
- `storage`: absolute root, private defaults suite, applicationSupport, caches, documents, downloads, webKitRules, history, downloadHistory, theme, CLI namespace/pipe/responses, manifest path.
- Nonsecret policy descriptions for WebKit, native network, page JavaScript, SwiftData/cloud, Keychain, IPC, clipboard and external integration/file boundaries.

The initial manifest has `ready=false`. Only successful private WebKit rule preparation advances it to `ready=true`; scene content remains inert on preparation failure. Normal termination invalidates readiness. After a crash the retained file may be stale: the harness must verify that its PID is live and identifies the exact candidate executable, profile argument and hash. `ready=true` describes preparation, not test success.

Before GUI interaction, verify the live candidate PID, executable SHA, identifier, full manifest hash, every owned path, nonpersistent mode and visible marker. Bind those identities to the native-controls receipt and separately hash production-preservation sentinels. Do not relabel manual checks as XCTest. The helper's source-only native-controls schema does not itself demonstrate acceptance.

## Coverage and remaining gates

The source harness executes actual policy/context/network/store code, including private fixture sentinels, invalid-startup subprocesses, nonpersistent jar identity and actual WebKit rule preparation/readiness invalidation without a view or window. The full app/test bundle compile checks integration, but does not launch Browser. Full hosted native tests, exact signed-build profile startup, deny-first rule compilation, preservation sentinels and actual native-controls acceptance remain the Air owner's gates. Actual XCTest UI execution remains unproven; its prior failures were runner infrastructure timeouts with zero app UI tests, not a demonstrated app regression or a proven system permission cause.

Synthetic acceptance excludes live sites/calls, page JavaScript, WebAuthn/credentials, live API/provider inference, external services, cloud sync, native network and production continuity. This profile must not be used to infer those behaviors. Preserve the original production process, tabs, profile and files; no install/restart, permission changes, credential handling or publication is authorized by starting this mode.

## Local checks

```
python3 scripts/check-isolated-profile-boundaries.py
scripts/verify-isolated-profile.sh
```

The existing v2 policy harnesses compile the real profile dependency without enabling the process-global flag. Native UI launch helpers add a fresh profile identifier; a separate app bundle identity is still required when using XCTest to avoid its application lifecycle operations targeting production Browser.
