#!/bin/bash
#
# Runs every build and test gate required before merging or releasing.
#
# Usage: ./scripts/verify.sh
# Override the build cache with DERIVED_DATA_ROOT=/path/to/cache.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Straight Up Browser.xcodeproj"
# Build and run the tests outside the repository. When the derived data lives
# under ~/Documents, launching the test host trips macOS file-access consent:
# the app comes up but blocks before it connects, and xcodebuild reports "The
# test runner hung before establishing connection" after ~350s of nothing. The
# identical invocation passes in seconds from an unprotected directory —
# bisected 2026-08-05, in-repo hangs, ~/Library/Caches and /tmp both pass.
# The .xcresult diagnostics move here too.
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$HOME/Library/Caches/straight-up-browser/verification}"
COMMON_SETTINGS=(
    CODE_SIGNING_ALLOWED=NO
    ENABLE_DEBUG_DYLIB=NO
    GCC_TREAT_WARNINGS_AS_ERRORS=YES
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)
UI_TEST_SETTINGS=(
    ENABLE_DEBUG_DYLIB=NO
    GCC_TREAT_WARNINGS_AS_ERRORS=YES
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)
RUN_UI_TESTS="${RUN_UI_TESTS:-0}"
# The iPadOS UI suite gates the iOS app, which ships on its own schedule. Set
# this to 0 to release the Mac app without it. The iOS Release build below is
# unconditional either way, so a macOS release still cannot land iOS code that
# fails to compile.
RUN_IOS_UI_TESTS="${RUN_IOS_UI_TESTS:-1}"
RUN_TSAN="${RUN_TSAN:-1}"
MIN_APP_COVERAGE_PERCENT="${MIN_APP_COVERAGE_PERCENT:-25}"

./scripts/validate-ci.sh
./scripts/validate-release-policy.sh
./scripts/validate-security-policy.sh

# xcodebuild refuses to overwrite an existing result bundle. Remove only the
# named diagnostic artifacts so repeated local runs remain deterministic.
for result_bundle in \
    "$DERIVED_DATA_ROOT/macos-tests.xcresult" \
    "$DERIVED_DATA_ROOT/macos-tsan.xcresult" \
    "$DERIVED_DATA_ROOT/macos-ui-tests.xcresult" \
    "$DERIVED_DATA_ROOT/ios-ui-tests.xcresult"; do
    if [ -e "$result_bundle" ]; then
        rm -rf -- "$result_bundle"
    fi
done

echo "Running macOS unit tests..."
xcodebuild test -quiet \
    -onlyUsePackageVersionsFromResolvedFile \
    -project "$PROJECT" \
    -scheme "Browser" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_ROOT/macos-tests" \
    -resultBundlePath "$DERIVED_DATA_ROOT/macos-tests.xcresult" \
    -parallel-testing-enabled NO \
    -enableCodeCoverage YES \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 120 \
    "${COMMON_SETTINGS[@]}"

APP_COVERAGE_PERCENT="$(
    xcrun xccov view --report "$DERIVED_DATA_ROOT/macos-tests.xcresult" |
        awk '$1 == "Browser.app" { gsub("%", "", $2); print $2; exit }'
)"
if [ -z "$APP_COVERAGE_PERCENT" ]; then
    echo "Coverage gate failed: Browser.app coverage was not found." >&2
    exit 1
fi
if ! awk -v actual="$APP_COVERAGE_PERCENT" -v minimum="$MIN_APP_COVERAGE_PERCENT" \
    'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
    echo "Coverage gate failed: Browser.app is ${APP_COVERAGE_PERCENT}%; minimum is ${MIN_APP_COVERAGE_PERCENT}%." >&2
    exit 1
fi
echo "Coverage gate passed: Browser.app is ${APP_COVERAGE_PERCENT}% (minimum ${MIN_APP_COVERAGE_PERCENT}%)."

if [ "$RUN_TSAN" = "1" ]; then
    echo "Running macOS unit tests with Thread Sanitizer..."
    xcodebuild test -quiet \
        -onlyUsePackageVersionsFromResolvedFile \
        -project "$PROJECT" \
        -scheme "Browser" \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$DERIVED_DATA_ROOT/macos-tsan" \
        -resultBundlePath "$DERIVED_DATA_ROOT/macos-tsan.xcresult" \
        -parallel-testing-enabled NO \
        -enableThreadSanitizer YES \
        ENABLE_DEBUG_DYLIB=NO \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 60 \
        -maximum-test-execution-time-allowance 120 \
        "${COMMON_SETTINGS[@]}"
fi

echo "Building the iOS app in Release..."
xcodebuild build -quiet \
    -onlyUsePackageVersionsFromResolvedFile \
    -project "$PROJECT" \
    -scheme "Browser iOS" \
    -configuration Release \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA_ROOT/ios-build" \
    "${COMMON_SETTINGS[@]}"

echo "Building the Apple Silicon macOS app in Release..."
xcodebuild build -quiet \
    -onlyUsePackageVersionsFromResolvedFile \
    -project "$PROJECT" \
    -scheme "Browser" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_ROOT/macos-release" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    "${COMMON_SETTINGS[@]}"

MAC_EXECUTABLE="$DERIVED_DATA_ROOT/macos-release/Build/Products/Release/Browser.app/Contents/MacOS/Browser"
CLI_EXECUTABLE="$DERIVED_DATA_ROOT/macos-release/Build/Products/Release/Browser.app/Contents/Helpers/browser-cli"
./scripts/validate-macos-architectures.sh "$MAC_EXECUTABLE" "$CLI_EXECUTABLE"

if [ "$RUN_UI_TESTS" = "1" ]; then
    echo "Running macOS UI tests..."
    xcodebuild test -quiet \
        -onlyUsePackageVersionsFromResolvedFile \
        -project "$PROJECT" \
        -scheme "Browser UI" \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$DERIVED_DATA_ROOT/macos-ui-tests" \
        -resultBundlePath "$DERIVED_DATA_ROOT/macos-ui-tests.xcresult" \
        -parallel-testing-enabled NO \
        "${UI_TEST_SETTINGS[@]}"

    if [ "$RUN_IOS_UI_TESTS" = "1" ]; then
        echo "Running iPadOS UI tests..."
        IOS_SIMULATOR_ID="$(
            xcrun simctl create \
                "Straight Up Browser Verify" \
                "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB" \
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
        )"
        cleanup_simulator() {
            xcrun simctl shutdown "$IOS_SIMULATOR_ID" >/dev/null 2>&1 || true
            xcrun simctl delete "$IOS_SIMULATOR_ID" >/dev/null 2>&1 || true
        }
        trap cleanup_simulator EXIT
        # xcodebuild boots the device itself, but starts the test before the
        # simulator finishes coming up, which surfaces as "Failed to get
        # background assertion for target app with pid 0" — the app never
        # launched. Wait for the boot to complete first.
        xcrun simctl bootstatus "$IOS_SIMULATOR_ID" -b >/dev/null 2>&1 || true
        xcodebuild test -quiet \
            -onlyUsePackageVersionsFromResolvedFile \
            -project "$PROJECT" \
            -scheme "Browser iOS" \
            -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_ID" \
            -derivedDataPath "$DERIVED_DATA_ROOT/ios-ui-tests" \
            -resultBundlePath "$DERIVED_DATA_ROOT/ios-ui-tests.xcresult" \
            -parallel-testing-enabled NO \
            "${UI_TEST_SETTINGS[@]}"
        cleanup_simulator
        trap - EXIT
    else
        echo "iPadOS UI test execution skipped (RUN_IOS_UI_TESTS=0)."
    fi
else
    echo "UI test execution skipped (set RUN_UI_TESTS=1 on a UI-automation-enabled host)."
    echo "Building macOS UI tests..."
    xcodebuild build-for-testing -quiet \
        -onlyUsePackageVersionsFromResolvedFile \
        -project "$PROJECT" \
        -scheme "Browser UI" \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$DERIVED_DATA_ROOT/macos-ui-tests" \
        "${COMMON_SETTINGS[@]}"
fi

# Every app bundle built above registers with LaunchServices under the shipping
# bundle identifier, and an unsigned build can outrank /Applications/Browser.app
# when the user double-clicks — which fails with "The application Browser can't
# be opened", because an unsigned bundle cannot launch. Unregistering alone does
# not hold (LaunchServices re-adds anything still on disk), so the bundles have
# to go. Only the .app products are removed; the compiled objects and the
# .xcresult diagnostics stay, so the next run is still incremental.
unregister_built_apps() {
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$lsregister" ] || return 0
    find "$DERIVED_DATA_ROOT" -name "*.app" -type d -path "*/Build/Products/*" -prune 2>/dev/null |
        while IFS= read -r bundle; do
            "$lsregister" -u "$bundle" >/dev/null 2>&1 || true
            rm -rf -- "$bundle"
        done
}
unregister_built_apps

echo "All verification gates passed."
