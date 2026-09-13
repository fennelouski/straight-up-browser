# Password-manager verification (2026-09-12)

Run an isolated app with `DERIVED_DATA_ROOT=/tmp/straight-up-credentials-verify ./script/build_and_run.sh --ui-testing`. It uses `com.nathanfennel.Browser.Development`, a separate sandbox, and a bundle-specific Keychain security domain. The development entitlement copy excludes CloudKit and Apple's restricted passkey entitlement; shipping entitlements are unchanged.

Serve this directory on loopback, e.g. `python3 -m http.server 8765 --bind 127.0.0.1 --directory docs/verification`, and open `http://localhost:8765/credential-form.html` in that app. The form prevents navigation and reports only whether the disposable test password matches; it does not send credentials to a server. Use `alice.verify` / `Verify-Only-123!`, then repeat with `bob.verify`. Update Bob to `Verify-Updated-456!`.

Observed in a real Browser window:

- Submit shows a Save banner at the top of the window.
- Save, reload, focus Username, click a saved username: both fields fill, and submitting confirms the exact test password. An identical saved password does not summon another banner.
- Alice and Bob appear together, in sorted order; Bob fills correctly.
- A different password offers Update. After Update and reload, Bob fills the replacement password.
- An unannotated form initially showed no suggestions on username focus. After form-scoped detection was added, the live save/reload/pick/submit flow passed with `carol.verify`.
- The suggestion list initially appeared far below the input. Respecting `WKWebView.isFlipped` removes the double vertical conversion; screenshots confirmed it immediately below the input after the fix.

Keychain checks found that `kSecAttrService` does not namespace Internet Password items: different service strings collide. The vault now uses `kSecAttrSecurityDomain`. Existing unnamespaced items are left untouched and are not automatically imported: the old service attribute cannot reliably establish which app owns an item. A login saved by the earlier implementation may need saving again.

Ad-hoc rebuilds change the app's signing identity and can cause macOS to ask for the login-Keychain password before reading a test credential saved by the previous binary. Deny that prompt and use a fresh test account for the rebuilt binary; do not enter the user's login-Keychain password for this workflow. This was observed during verification.

Remaining scope: full-page fill selection still uses a DOM-order heuristic and is not certified for pages with multiple login forms. Multi-step email-first authentication and shadow-DOM login forms remain unsupported/unverified. The save banner observes form submission, not successful authentication. Never-save, authenticated password reveal, sync, and iOS UI are deferred. The separate `autofillApply` password guard and native right-click menu flattening are retained.

Final automated verification: 41 tests passed, 0 failed, 0 skipped, in `/tmp/straight-up-credential-tests-pass.xcresult`. Suites: `AutofillAgentIsolationTests`, `AutofillClassifierTests`, `AutofillFocusSignalTests`, `AutofillGeometryTests`, `AutofillFlippedGeometryTests`, `SavedCredentialStoreTests`, `CredentialSavePromptTests`, and `CredentialFocusRuntimeTests`. The WebKit test exercises unannotated username focus, verifies the credential-only signal contains no password, and checks a separate form stays on the profile-autofill channel. `bash -n script/build_and_run.sh` and `git diff --check` also passed.

## Save-card, Touch ID, and context-menu pass (2026-09-13)

Same isolated app and loopback form. Because the earlier verification binary had already saved logins for `localhost` and `127.0.0.1`, reading them from a rebuilt (re-signed) binary blocks the main thread on the login-Keychain access dialog; that prompt was denied as the runbook says, and the pass used a fresh host (`http://[::1]:8766/`, served with `--bind ::1`) and fresh accounts. Keystroke automation did not reach the page; paste (`pbcopy` + ⌘V) did.

Observed in a real window:

- Submitting the form shows the new save card above the login fields (never over the Sign in button), with the tab favicon, username, domain, an "Ask for Touch ID before filling" switch, and Never for This Site / Not Now / Save.
- Saving with the switch on stores the Keychain comment flag (`security find-internet-password` shows `icmt = requires-authentication`). After reload, focusing Username offers the login; picking it raises the system "Browser is trying to fill your password" Touch ID / password prompt before anything is filled. Cancelling fills nothing.
- Right-clicking the password field shows "Passwords…" as the first menu item; choosing it opens the system Passwords picker (the "Passwords Is Locked" Touch ID popover), the same as AutoFill → Passwords….
- Found and fixed: the page reported `location.hostname` with brackets for IPv6 literals (`[::1]`) while the fill path used `URL.host` (`::1`), so a saved login was never offered back on such hosts. Real hostnames were unaffected.

Automated: 38 tests in `SavedCredentialStoreTests`, `CredentialSavePromptTests`, `AutofillPreferencesTests`, `CredentialFocusRuntimeTests`, `AutofillFocusSignalTests`, `SemanticPageReferenceTests` pass; macOS and iOS targets build.
