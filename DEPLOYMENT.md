# Deploying a new release

The public release is a signed, **notarized** `Browser.dmg` served from
nathanfennel.com (Next.js on Vercel, auto-deploys `main`). The download button lives at
`/internet` → `src/app/internet/page.tsx` → `/downloads/Browser.dmg`.

## One-time setup

- **Developer ID Application** certificate in the login keychain
  (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
- **Notarization credentials** stored as keychain profile `notary`
  (app-specific password from account.apple.com):

  ```
  xcrun notarytool store-credentials notary \
    --apple-id nathanfennel@gmail.com --team-id EJLR2RPSV2
  ```

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
   notarizes + staples the DMG. Output: `build/release/Browser.dmg`. Takes a few minutes
   (two notarization round-trips to Apple). Override the profile with `NOTARY_PROFILE=name`.

3. **Publish to the website:**

   ```
   cp build/release/Browser.dmg ~/Documents/GitHub/nathanfennel.com/public/downloads/Browser.dmg
   cd ~/Documents/GitHub/nathanfennel.com
   git add public/downloads/Browser.dmg
   git commit -m "Update Browser.dmg to 1.x (build N)"
   git push                     # Vercel auto-deploys main
   ```

   **Also update the version line** in `src/app/internet/page.tsx` — it hardcodes
   "Version 1.x · … · N MB". It drifted from 1.1 to 1.4.3 unnoticed because nothing
   here said to touch it.

   Rollback if needed: `git revert` the commit and push — the previous DMG is in history.

   Verify the CDN actually served the new file — a Ready deployment is not proof, the
   edge can still hand out the old asset for a few minutes:

   ```
   curl -sL https://nathanfennel.com/downloads/Browser.dmg | shasum -a 256
   shasum -a 256 build/release/Browser.dmg      # must match
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
