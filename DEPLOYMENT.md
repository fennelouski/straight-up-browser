# Deploying a new release

The public release is a signed, **notarized** `Internet.dmg` served from
nathanfennel.com (Next.js on Vercel, auto-deploys `main`). The download button lives at
`/internet` → `src/app/internet/page.tsx` → `/downloads/Internet.dmg`.

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
     binary is distinguishable (About window, crash reports).
   - `MARKETING_VERSION` — bump for user-facing releases (e.g. `1.1` → `1.2` for a feature).

2. **Build the notarized DMG:**

   ```
   ./scripts/release.sh
   ```

   Archives → exports Developer ID → notarizes + staples the app → builds, signs,
   notarizes + staples the DMG. Output: `build/release/Internet.dmg`. Takes a few minutes
   (two notarization round-trips to Apple). Override the profile with `NOTARY_PROFILE=name`.

3. **Publish to the website:**

   ```
   cp build/release/Internet.dmg ~/Documents/GitHub/nathanfennel.com/public/downloads/Internet.dmg
   cd ~/Documents/GitHub/nathanfennel.com
   git add public/downloads/Internet.dmg
   git commit -m "Update Internet.dmg to 1.x (build N)"
   git push                     # Vercel auto-deploys main
   ```

   Rollback if needed: `git revert` the commit and push — the previous DMG is in history.

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
