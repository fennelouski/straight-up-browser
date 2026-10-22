# iPadOS 18.5 WebKit launch investigation — Air, 2026-10-22

## Finding

The missing `libswiftWebKit.dylib` failure is the known **iOS 18.5 Simulator runtime loader/search-path defect, WebKit bug 293831**. It is not an omitted application framework or an erroneous 18.0 product deployment target. The existing app legitimately uses refined Swift WebKit APIs. The installed SDK redirects those symbols to the compatibility overlay for deployment targets below 18.4. The installed 18.5 runtime contains that overlay inside its Cryptex, outside the launch search path used by the failing run.

This classification is directly supported by [WebKit bug 293831](https://bugs.webkit.org/show_bug.cgi?id=293831) and [Apple Frameworks Engineering's accepted guidance](https://developer.apple.com/forums/thread/785964?answerId=841589022), plus the unchanged-binary retest described below. Apple's related [DTS linker analysis](https://developer.apple.com/forums/thread/780782) explains moved Swift WebKit symbols; its older incorrect-version-range issue is distinct from this installed SDK's correct `14.0..<18.4` range.

## Local evidence

- `Browser.debug.dylib` has a strong dependency on `/usr/lib/swift/libswiftWebKit.dylib`; it is not manually added by this project. Undefined symbols include `WKPDFConfiguration.rect`, JavaScript/content-world async wrappers, PDF creation and web-archive creation.
- Both the source setting and built metadata retain minimum iOS **18.0**. The existing standard `CopySwiftLibs` build step ran. The library in question is supplied by the Simulator runtime, rather than being an application dependency omitted from our bundle.
- The iPhoneSimulator 27.1 SDK WebKit stub contains `$ld$previous$` directives with Simulator platform 7 and version range `14.0..<18.4`. That explains why a minimum-18.0 binary refers to the compatibility overlay.
- In the installed iOS 18.5 / 22F77 runtime, `usr/lib/swift/libswiftWebKit.dylib` is absent, but `System/Cryptexes/OS/usr/lib/swift/libswiftWebKit.dylib` exists. It includes an arm64 slice and reexports the same runtime's WebKit framework.

Read-only evidence is in `build-air/webkit-overlay-investigation/`: SDK redirections and stub hash, original linker arguments, runtime library locations, dependency metadata, deployment metadata, and app executable/debug-library/Info.plist SHA256 values before and after the retest. No framework, runtime, toolchain, signing setting or deployment target was changed.

## Narrow fix and bounded verification

Added `scripts/mobile-simulator-environment.py`. For an exact existing Simulator UDID, it discovers the installed runtime and applies Apple's documented `DYLD_FALLBACK_LIBRARY_PATH` workaround **only for iOS 18.5**, pointing to the compatibility library already bundled in that same runtime. Other runtime versions receive no added environment. A missing bundled file fails explicitly. No library is copied, no global environment is changed, and no extra runtime is installed.

For test-without-building, it prepares a new xctestrun copy using Xcode's documented `EnvironmentVariables` and `UITargetAppEnvironmentVariables` dictionaries, preserving existing entries. This covers native app-host tests and the UI target app. The Air runner uses that helper and records the chosen runtime environment in its receipt.

The app binaries were **not rebuilt**. The only run repeated the two previously failed checks on the same owned iPad Pro 11-inch M4 / iOS 18.5 guest, with a 300-second process deadline and unique isolated test profiles. It completed in approximately 28 seconds:

| Check on actual iPadOS 18.5 | Result |
|---|---|
| App-host startup, existing host and native orientation-mask/domain precedence | Passed |
| URL selection, continued typing, background return and reopening | Passed |
| iPadOS 26 conditional-lock enforcement | Explicit API-unavailable skip |

`build-air/legacy-ipad-webkit-loader/summary.json` records **2 passed, 0 failed, 1 skipped**, with a successful finalized xcresult and joined process group. The original no-workaround run remains **0 passed, 2 failed, 1 skipped** in `build-air/legacy-ipad-availability/`; it was not overwritten. Hashes confirm the main executable, debug library and Info.plist stayed byte-for-byte unchanged. The prior newer-platform passes were not repeated.

These are limited, actual older-runtime passes. They do not establish all mobile behavior, rendered legacy domain locks, physical-device behavior or the unavailable iPadOS 26 feature. An ordinary launch on this installed 18.5 runtime still needs the documented process-local workaround until runtime support is corrected; this does not repair the runtime itself.

## Reproduction and recovery

Without rebuilding, use the helper to prepare a fresh test plan:

```sh
python3 scripts/mobile-simulator-environment.py \
  --device <existing-simulator-UDID> \
  --xctestrun /path/to/original.xctestrun \
  --output /path/to/new-18.5.xctestrun
```

Then run only the intended failed checks with `xcodebuild test-without-building -xctestrun /path/to/new-18.5.xctestrun -destination 'platform=iOS Simulator,id=<same-UDID>'` and explicit test selectors. The output must stay beside the original test products, or retain valid original product paths; no product files need rewriting. Without xctestrun arguments, the helper prints only the selected process environment and rationale.

The task-owned Simulator is shut down and the bounded test group ended. No services or heavy workers remain owned by this follow-up. Studio, published Mac 2.9.34, physical devices, accounts, credentials, system/privacy/security settings and app release/upload workflows were untouched. This follow-up installed nothing and made no broad rebuild or passed-test-suite rerun.
