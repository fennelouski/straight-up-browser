#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:---verify}"
case "$MODE" in
    --verify|--ui-testing|--logs) ;;
    *) echo "Usage: $0 [--verify|--ui-testing|--logs]" >&2; exit 2 ;;
esac

BUILD_ROOT="${DERIVED_DATA_ROOT:-$HOME/Library/Caches/straight-up-browser/development}"
APP="$BUILD_ROOT/Build/Products/Debug/Browser.app"
# A separate sandbox keeps development launches out of the shipping
# browser's tabs, preferences, history, and LaunchServices registration.
BUNDLE_ID="com.nathanfennel.Browser.Development"
if pgrep -f "^$APP/Contents/MacOS/Browser" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit"
fi

mkdir -p "$BUILD_ROOT"
cp Browser.entitlements "$BUILD_ROOT/development.entitlements"
for key in com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-services com.apple.developer.ubiquity-container-identifiers; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$BUILD_ROOT/development.entitlements"
done
xcodebuild build -quiet -onlyUsePackageVersionsFromResolvedFile \
    -project "Straight Up Browser.xcodeproj" -scheme Browser \
    -configuration Debug -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$BUILD_ROOT" ENABLE_DEBUG_DYLIB=NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGN_ENTITLEMENTS="$BUILD_ROOT/development.entitlements" \
    DEVELOPMENT_TEAM= PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

ARGS=(-tabSyncEnabled NO -globalOmnibarHotkey off -SUEnableAutomaticChecks NO)
if [ "$MODE" = "--ui-testing" ]; then
    ARGS+=(-uiTesting -ApplePersistenceIgnoreState YES -acceptedEULAVersion 1 -memorySaverEnabled YES -defaultBrowserPromptEnabled NO)
fi
/usr/bin/open -n "$APP" \
    --stdout "$BUILD_ROOT/run.log" --stderr "$BUILD_ROOT/run.log" --args "${ARGS[@]}"
if [ "$MODE" = "--logs" ]; then
    /usr/bin/log stream --info --style compact --predicate "processImagePath == '$APP/Contents/MacOS/Browser'"
else
    for ((attempt = 0; attempt < 20; attempt++)); do
        if pgrep -f "^$APP/Contents/MacOS/Browser" >/dev/null; then
            # Deliver the reopen event after launch, as the UI-test helper does.
            /usr/bin/open "$APP"
            echo "Launched $APP"
            exit 0
        fi
        sleep 0.25
    done
    echo "Browser did not launch. See $BUILD_ROOT/run.log" >&2
    exit 1
fi
