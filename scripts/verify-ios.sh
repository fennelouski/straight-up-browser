#!/bin/bash
# Local iPhone + iPad release verification. No GitHub-hosted runner is used.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Straight Up Browser.xcodeproj"
SCHEME="Browser iOS"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$HOME/Library/Caches/straight-up-browser/ios-verification}"
RUN_IOS_UI_TESTS="${RUN_IOS_UI_TESTS:-1}"
RUN_IOS_UNIT_TESTS="${RUN_IOS_UNIT_TESTS:-1}"
IPHONE_SIMULATOR_NAME="${IPHONE_SIMULATOR_NAME:-iPhone 17 Pro}"
IPAD_SIMULATOR_NAME="${IPAD_SIMULATOR_NAME:-iPad Pro 11-inch (M4)}"

COMMON_SETTINGS=(
    ENABLE_DEBUG_DYLIB=NO
    GCC_TREAT_WARNINGS_AS_ERRORS=YES
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)
UNSIGNED_SETTINGS=(CODE_SIGNING_ALLOWED=NO "${COMMON_SETTINGS[@]}")

rm -rf -- \
    "$DERIVED_DATA_ROOT/unit-tests.xcresult" \
    "$DERIVED_DATA_ROOT/iphone-ui-tests.xcresult" \
    "$DERIVED_DATA_ROOT/ipad-ui-tests.xcresult"
mkdir -p "$DERIVED_DATA_ROOT"

simulator_id_named() {
    local requested_name="$1"
    xcrun simctl list devices available -j | /usr/bin/ruby -rjson -e '
        requested = ARGV.fetch(0)
        devices = JSON.parse(STDIN.read).fetch("devices")
        matches = devices.keys.sort.reverse.flat_map do |runtime|
          devices.fetch(runtime).select { |device| device["name"] == requested }
        end
        abort("No available simulator named #{requested}") if matches.empty?
        puts matches.first.fetch("udid")
    ' "$requested_name"
}

echo "Building the universal app for an App Store device..."
xcodebuild build -quiet \
    -onlyUsePackageVersionsFromResolvedFile \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA_ROOT/device-build" \
    "${UNSIGNED_SETTINGS[@]}"

echo "Building the universal app for Apple Silicon simulators..."
xcodebuild build -quiet \
    -onlyUsePackageVersionsFromResolvedFile \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA_ROOT/simulator-build" \
    "${UNSIGNED_SETTINGS[@]}"

DEVICE_APP="$DERIVED_DATA_ROOT/device-build/Build/Products/Release-iphoneos/Browser.app"
INFO_PLIST="$DEVICE_APP/Info.plist"
PRIVACY_MANIFEST="$DEVICE_APP/PrivacyInfo.xcprivacy"
[ -x "$DEVICE_APP/Browser" ] || { echo "Device app executable is missing." >&2; exit 1; }
[ -f "$PRIVACY_MANIFEST" ] || { echo "PrivacyInfo.xcprivacy is missing from the app root." >&2; exit 1; }
plutil -lint "$INFO_PLIST" "$PRIVACY_MANIFEST" >/dev/null
file "$DEVICE_APP/Browser" | grep -q "arm64" || {
    echo "The iOS device executable is not arm64." >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}
[ "$(plist_value CFBundleShortVersionString)" = "2.0.0" ] || {
    echo "Unexpected iOS marketing version." >&2
    exit 1
}
[ "$(plist_value ITSAppUsesNonExemptEncryption)" = "false" ] || {
    echo "Export-compliance declaration is missing." >&2
    exit 1
}
plist_value UIBackgroundModes | grep -q "remote-notification" || {
    echo "CloudKit remote-notification background mode is missing." >&2
    exit 1
}
plist_value CFBundleURLTypes | grep -q "https" || {
    echo "The browser URL registration is missing." >&2
    exit 1
}
plist_value SUCloudKitContainerIdentifiers | grep -q \
    "iCloud.com.nathanfennel.Straight-Up-Browser" || {
    echo "The declared CloudKit container is missing." >&2
    exit 1
}
if [ ! -f "$DEVICE_APP/Assets.car" ]; then
    echo "Compiled app-icon assets are missing." >&2
    exit 1
fi

IPHONE_ID="${IPHONE_SIMULATOR_ID:-$(simulator_id_named "$IPHONE_SIMULATOR_NAME")}"
IPAD_ID="${IPAD_SIMULATOR_ID:-$(simulator_id_named "$IPAD_SIMULATOR_NAME")}"

if [ "$RUN_IOS_UNIT_TESTS" = "1" ]; then
    xcrun simctl bootstatus "$IPHONE_ID" -b >/dev/null 2>&1 || true
    echo "Running focused mobile unit tests on iPhone..."
    xcodebuild test -quiet \
        -onlyUsePackageVersionsFromResolvedFile \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$IPHONE_ID" \
        -derivedDataPath "$DERIVED_DATA_ROOT/unit-tests" \
        -resultBundlePath "$DERIVED_DATA_ROOT/unit-tests.xcresult" \
        -only-testing:"Browser iOSTests" \
        -parallel-testing-enabled NO \
        -enableCodeCoverage YES \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 45 \
        -maximum-test-execution-time-allowance 90 \
        "${COMMON_SETTINGS[@]}"
else
    echo "Mobile unit tests skipped (RUN_IOS_UNIT_TESTS=0)."
fi

if [ "$RUN_IOS_UI_TESTS" = "1" ]; then
    for platform in iphone ipad; do
        if [ "$platform" = "iphone" ]; then
            simulator_id="$IPHONE_ID"
        else
            simulator_id="$IPAD_ID"
        fi
        xcrun simctl bootstatus "$simulator_id" -b >/dev/null 2>&1 || true
        echo "Running focused UI smoke tests on $platform..."
        xcodebuild test -quiet \
            -onlyUsePackageVersionsFromResolvedFile \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,id=$simulator_id" \
            -derivedDataPath "$DERIVED_DATA_ROOT/$platform-ui-tests" \
            -resultBundlePath "$DERIVED_DATA_ROOT/$platform-ui-tests.xcresult" \
            -only-testing:"Browser iOSUITests" \
            -parallel-testing-enabled NO \
            -test-timeouts-enabled YES \
            -default-test-execution-time-allowance 60 \
            -maximum-test-execution-time-allowance 120 \
            "${COMMON_SETTINGS[@]}"
    done
else
    echo "UI smoke tests skipped (RUN_IOS_UI_TESTS=0)."
fi

echo "iPhone and iPad local verification passed."
