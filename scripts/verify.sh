#!/bin/bash
#
# Runs every build and test gate required before merging or releasing.
#
# Usage: ./scripts/verify.sh
# Override the build cache with DERIVED_DATA_ROOT=/path/to/cache.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Straight Up Browser.xcodeproj"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-build/verification}"
COMMON_SETTINGS=(
    CODE_SIGNING_ALLOWED=NO
    GCC_TREAT_WARNINGS_AS_ERRORS=YES
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)
UI_TEST_SETTINGS=(
    CODE_SIGN_IDENTITY=-
    CODE_SIGNING_REQUIRED=NO
    GCC_TREAT_WARNINGS_AS_ERRORS=YES
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)
RUN_UI_TESTS="${RUN_UI_TESTS:-0}"

./scripts/validate-ci.sh
./scripts/validate-release-policy.sh
./scripts/validate-security-policy.sh

echo "Running macOS unit tests..."
xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme "Browser" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_ROOT/macos-tests" \
    -parallel-testing-enabled NO \
    "${COMMON_SETTINGS[@]}"

echo "Building the iOS app in Release..."
xcodebuild build -quiet \
    -project "$PROJECT" \
    -scheme "Browser iOS" \
    -configuration Release \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA_ROOT/ios-build" \
    "${COMMON_SETTINGS[@]}"

echo "Building the universal macOS app in Release..."
xcodebuild build -quiet \
    -project "$PROJECT" \
    -scheme "Browser" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_ROOT/macos-release" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    "${COMMON_SETTINGS[@]}"

MAC_EXECUTABLE="$DERIVED_DATA_ROOT/macos-release/Build/Products/Release/Browser.app/Contents/MacOS/Browser"
CLI_EXECUTABLE="$DERIVED_DATA_ROOT/macos-release/Build/Products/Release/Browser.app/Contents/Helpers/browser-cli"
./scripts/validate-macos-architectures.sh "$MAC_EXECUTABLE" "$CLI_EXECUTABLE"

if [ "$RUN_UI_TESTS" = "1" ]; then
    echo "Running macOS UI tests..."
    xcodebuild test -quiet \
        -project "$PROJECT" \
        -scheme "Browser UI" \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$DERIVED_DATA_ROOT/macos-ui-tests" \
        -resultBundlePath "$DERIVED_DATA_ROOT/macos-ui-tests.xcresult" \
        -parallel-testing-enabled NO \
        "${UI_TEST_SETTINGS[@]}"

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
    xcodebuild test -quiet \
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
    echo "UI test execution skipped (set RUN_UI_TESTS=1 on a UI-automation-enabled host)."
    echo "Building macOS UI tests..."
    xcodebuild build-for-testing -quiet \
        -project "$PROJECT" \
        -scheme "Browser UI" \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$DERIVED_DATA_ROOT/macos-ui-tests" \
        "${COMMON_SETTINGS[@]}"
fi

echo "All verification gates passed."
