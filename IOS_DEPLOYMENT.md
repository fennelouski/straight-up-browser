# iPhone and iPad deployment

`Browser iOS` is one universal app for iPhone and iPad. It has its own build
number, signing/export path, App Store Connect record, screenshots, TestFlight
acceptance, and release approval. A successful macOS DMG does not certify the
mobile binary.

The mobile app shares the safe browsing/session/sync core with macOS. Agent
execution, scheduled work, MCP, OAuth, Cowork, and the CLI remain macOS-only.
Mobile may sync, retain, and review allowlisted definitions, but it never
materializes or executes a schedule.

## Current release identity

- Marketing version: **2.0.0**
- Mobile build: **23**
- Bundle identifier: `com.nathanfennel.Straight-Up-Browser`
- Minimum OS: iOS/iPadOS 18.0
- Device families: iPhone and iPad
- CloudKit container: `iCloud.com.nathanfennel.Straight-Up-Browser`

The build number must be greater than every build already uploaded for version
2.0.0. Confirm that in App Store Connect before exporting the final candidate;
if 23 is already present, increment only the mobile target and its test targets.

## Apple Developer portal setup

Before the first archive, the explicit App ID must have these capabilities and
new profiles generated after every capability change:

1. iCloud with CloudKit and the exact container above.
2. Push Notifications.
3. Background Modes / remote notifications. The app plist declares
   `remote-notification`; SwiftData/CloudKit uses silent pushes to converge
   changes in the background.
4. The managed default-browser entitlement, requested through Apple, if Browser
   is to appear in **Settings → Apps → Default Apps → Browser App**. Source
   already registers `http`/`https` and routes warm and cold incoming URLs
   directly. Add `com.apple.developer.web-browser` to the mobile entitlements
   only after Apple grants it and the regenerated profiles contain it.

Promote the development CloudKit schema to Production before TestFlight or App
Store use. App Store builds can access only Production. Verify the SwiftData
record types and the `AgentDefinition` type/fields in CloudKit Console. Its
`category` field must be queryable so each separately opted-in definition
category is filtered by CloudKit before download. Never reset the production
environment to resolve a migration problem.

## Local automated gate

Run on the release Mac; GitHub Actions are deliberately disabled:

```bash
./scripts/verify-ios.sh
```

The script builds Release for generic device and simulator architectures,
checks the compiled icon, privacy manifest, Info.plist contracts, URL
registration, CloudKit declaration, and arm64 executable, runs focused mobile
unit tests with coverage/timeouts, then runs the compact UI smoke suite on an
iPhone and iPad simulator. Override simulator names or IDs when needed:

```bash
IPHONE_SIMULATOR_NAME="iPhone SE (3rd generation)" \
IPAD_SIMULATOR_NAME="iPad mini (A17 Pro)" \
./scripts/verify-ios.sh
```

Use both the minimum supported iOS 18.x runtime and the current iOS 26.x
runtime before release. Keep `.xcresult` evidence under
`~/Library/Caches/straight-up-browser/ios-verification`.

## Signed archive and IPA

From a clean, committed source revision:

```bash
./scripts/archive-ios.sh
```

This reruns the local gate, allows Xcode to refresh automatic provisioning,
creates `build/ios-release/Browser-iOS.xcarchive`, exports an App Store Connect
IPA without uploading it, verifies the signature and embedded profile, and
requires Production CloudKit plus production push entitlements. The export
preserves the checked-in build number instead of allowing Xcode to mutate it.

Do not upload an IPA if the export cannot prove:

- `get-task-allow = false`;
- the exact application and iCloud container identifiers;
- `com.apple.developer.icloud-container-environment = Production`;
- `aps-environment = production`;
- version 2.0.0 and the intended unique mobile build;
- `PrivacyInfo.xcprivacy` at the app-bundle root;
- an App Store icon and `ITSAppUsesNonExemptEncryption = false`.

Upload through Xcode Organizer only after inspecting the archive, or change the
export destination deliberately for a one-time upload. The checked-in script
never uploads by itself.

## Simulator and physical acceptance

Minimum release matrix:

| Device | OS | Required coverage |
|---|---|---|
| iPhone SE (3rd generation) | latest iOS 18.x | smallest layout, rotation, AXXXL, touch targets |
| current Pro/Pro Max iPhone | current iOS | navigation, tabs, incoming URLs, permissions, downloads, offline/relaunch |
| iPad mini | latest iPadOS 18.x | compact iPad, rotation, narrow multitasking widths |
| iPad Pro 13-inch | current iPadOS | splits, keyboard, Stage Manager/Split View, AXXXL |

Before submission, install the exported/TestFlight build on Nathan’s physical
iPhone and iPad. Do not use another person’s paired device. Perform:

- clean install and upgrade from the exact last public mobile build;
- normal/container cookie isolation and incognito terminate/relaunch
  non-retention;
- VoiceOver, AXXXL, keyboard, touch, rotation lock, multitasking, camera and
  microphone allow/deny/revoke, downloads, print/share sheets, and offline
  recovery;
- Mac ↔ iPhone ↔ iPad private-CloudKit round trips for browser data and all
  three definition categories, including cancel, keep-local, delete-cloud,
  re-enable, tombstones, conflict convergence, and sensitive-memory review;
- confirmation that every imported schedule is visibly retained but inert on
  both mobile devices.

## App Store Connect

Use these stable website URLs:

- Privacy policy: `https://nathanfennel.com/internet/privacy`
- Support URL: `https://nathanfennel.com/internet/support`
- Marketing URL: `https://nathanfennel.com/internet`

Complete description, keywords, review contact/notes, content rights, privacy
answers, and screenshots for the currently required 6.9-inch iPhone and
13-inch iPad sets. Because Browser provides unrestricted web access, answer the
age-rating questionnaire accordingly (currently 16+, or the legacy 17+
equivalent where App Store Connect still presents it).

The privacy answers must agree with the manifest and policy: no tracking or
usage telemetry; the global browsing-history store stays local, while opted-in
open-tab records include each tab's visit history; only the documented browser
records and safe definition categories enter the user's private iCloud account
after explicit opt-in; website network traffic goes to sites the user visits;
optional provider/MCP traffic exists only in the macOS automation surface.
Declare Browsing History, Search History, Other User Content, and the random
per-install Device ID as linked to the user, used only for App Functionality,
and not used for tracking; each is transmitted only through an opted-in private
iCloud feature.

## Rollback

App Store builds are immutable. If a candidate is bad, stop phased/TestFlight
distribution, fix forward with a higher build number, rerun every gate, and
submit the replacement. Never move a published Git tag or reuse an uploaded
build number.
