# Deploying a new release

The public release is a signed, **notarized** `Browser.dmg` served from
nathanfennel.com (Next.js on Vercel, auto-deploys `main`). The download button lives at
`/internet` → `src/app/internet/page.tsx` → `/downloads/Browser.dmg`.

Installed copies also auto-update via **Sparkle**: the app checks
`https://nathanfennel.com/downloads/browser-appcast.xml` on launch and installs silently
in the background (`SUEnableAutomaticChecks` + `SUAutomaticallyUpdate` in
`Browser-Info.plist`) — no dialog, it's just live after the next relaunch. "Check
for Updates…" in the app menu (Straight_Up_BrowserApp.swift) triggers the same
check on demand.

## One-time setup

- **Developer ID Application** certificate in the login keychain
  (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
- **Notarization credentials** stored as keychain profile `notary`
  (app-specific password from account.apple.com):

  ```
  xcrun notarytool store-credentials notary \
    --apple-id nathanfennel@gmail.com --team-id EJLR2RPSV2
  ```

- **Sparkle EdDSA signing key**, in this Mac's Keychain (item "Private key for
  signing Sparkle updates", service `https://sparkle-project.org`, account
  `ed25519`) — `scripts/release.sh` uses it via
  `scripts/sparkle-bin/generate_appcast` to sign every appcast entry, and every
  installed copy of the app checks the signature against the public half baked
  into `Browser-Info.plist` (`SUPublicEDKey`). **This key must never change** —
  swapping it breaks auto-update for everyone already installed, since their
  copy would reject an appcast signed by a different key. It only exists on
  this Mac; back up the Keychain item somewhere durable
  (`security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w`
  prints it, if you need to restore it on a new machine — treat the output as a
  secret, don't paste it anywhere).

## Each release

1. **Bump the version.** In Xcode (target *Browser* → General), or in
   `Straight Up Browser.xcodeproj/project.pbxproj`:
   - `CURRENT_PROJECT_VERSION` (build number) — bump **every** release, so a changed
     binary is distinguishable in crash reports.
   - `MARKETING_VERSION` — bump **every** release too. The About panel no longer shows
     the build number in parentheses, so the marketing version is the only thing users
     can see; two releases sharing one would be indistinguishable to them.

2. **Build the notarized DMG:**

   ```
   ./scripts/release.sh
   ```

   Archives → exports Developer ID → notarizes + staples the app → builds, signs,
   notarizes + staples the DMG → generates + EdDSA-signs the Sparkle appcast.
   Output: `build/release/Browser.dmg` and `build/release/browser-appcast.xml`. Takes a
   few minutes (two notarization round-trips to Apple). Override the profile
   with `NOTARY_PROFILE=name`.

3. **Publish to the website:**

   ```
   cp build/release/Browser.dmg ~/Documents/GitHub/nathanfennel.com/public/downloads/Browser.dmg
   cp build/release/browser-appcast.xml ~/Documents/GitHub/nathanfennel.com/public/downloads/browser-appcast.xml
   cd ~/Documents/GitHub/nathanfennel.com
   git add public/downloads/Browser.dmg public/downloads/browser-appcast.xml
   git commit -m "Update Browser.dmg to 1.x (build N)"
   git push                     # Vercel auto-deploys main
   ```

   The appcast is what makes already-installed copies auto-update — skipping it
   means new installs get 1.x but existing users never hear about it.

   **Also update the version line** in `src/app/internet/page.tsx` — it hardcodes
   "Version 1.x · … · N MB". It drifted from 1.1 to 1.4.3 unnoticed because nothing
   here said to touch it.

   Rollback if needed: `git revert` the commit and push — the previous DMG is in history.

   Verify the CDN actually served the new file — a Ready deployment is not proof, the
   edge can still hand out the old asset for a few minutes:

   ```
   curl -sL https://nathanfennel.com/downloads/Browser.dmg | shasum -a 256
   shasum -a 256 build/release/Browser.dmg      # must match
   curl -sL https://nathanfennel.com/downloads/browser-appcast.xml | grep sparkle:version
   ```

4. **Commit + tag the app source** so the shipped binary is reproducible:

   ```
   cd "~/Documents/GitHub/Straight Up Browser"
   git commit -am "Release 1.x (build N)"
   git tag v1.x-N && git push --tags
   ```

## Verify

Download from nathanfennel.com/internet, open the DMG, drag to Applications, launch.
Gatekeeper should accept it with no warning (the stapled ticket works offline). Do a
quick smoke test — open **Settings**, right-click a tab — before considering it shipped.

On an older installed copy, use **Browser → Check for Updates…** to confirm Sparkle
finds the new version against the live appcast (don't rely only on the automatic
background check — that's on a delay).
