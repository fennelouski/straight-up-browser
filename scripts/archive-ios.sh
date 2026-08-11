#!/bin/bash
# Archive and export the exact iPhone/iPad binary intended for App Store Connect.
# This script never uploads a build.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Straight Up Browser.xcodeproj"
SCHEME="Browser iOS"
BUILD_ROOT="${IOS_RELEASE_ROOT:-build/ios-release}"
ARCHIVE="$BUILD_ROOT/Browser-iOS.xcarchive"
EXPORT="$BUILD_ROOT/export"
TEAM_ID="EJLR2RPSV2"
APP_IDENTIFIER="$TEAM_ID.com.nathanfennel.Straight-Up-Browser"
CONTAINER_ID="iCloud.com.nathanfennel.Straight-Up-Browser"
EXPECTED_VERSION="${EXPECTED_IOS_VERSION:-2.0.0}"
EXPECTED_BUILD="${EXPECTED_IOS_BUILD:-23}"
EXPORT_OPTIONS="scripts/ios-export-options.plist"

case "$BUILD_ROOT" in
    ""|"/"|"$HOME")
        echo "Unsafe IOS_RELEASE_ROOT: $BUILD_ROOT" >&2
        exit 1
        ;;
esac

if [ "${ALLOW_DIRTY_IOS_ARCHIVE:-0}" != "1" ] && [ -n "$(git status --porcelain)" ]; then
    echo "Commit every iOS release change before archiving." >&2
    exit 1
fi

RUN_IOS_UI_TESTS="${RUN_IOS_UI_TESTS:-1}" ./scripts/verify-ios.sh

mkdir -p "$BUILD_ROOT"
rm -rf -- "$ARCHIVE" "$EXPORT"

echo "Creating the signed iPhone/iPad archive..."
xcodebuild archive -quiet \
    -onlyUsePackageVersionsFromResolvedFile \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates

echo "Exporting an App Store Connect IPA without uploading it..."
xcodebuild -exportArchive -quiet \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates

IPA="$(find "$EXPORT" -maxdepth 1 -name '*.ipa' -print -quit)"
[ -n "$IPA" ] || { echo "The App Store IPA was not exported." >&2; exit 1; }
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/straight-up-browser-ios.XXXXXX")"
cleanup() { rm -rf -- "$TEMP_ROOT"; }
trap cleanup EXIT
ditto -x -k "$IPA" "$TEMP_ROOT"
APP="$(find "$TEMP_ROOT/Payload" -maxdepth 1 -name '*.app' -type d -print -quit)"
[ -n "$APP" ] || { echo "The exported IPA has no app bundle." >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d \
    --entitlements "$TEMP_ROOT/effective-entitlements.plist" \
    --xml \
    "$APP"
plutil -lint "$TEMP_ROOT/effective-entitlements.plist" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$TEMP_ROOT/effective-entitlements.plist")" = "$APP_IDENTIFIER" ]
/usr/libexec/PlistBuddy -c \
    "Print :com.apple.developer.icloud-container-identifiers" \
    "$TEMP_ROOT/effective-entitlements.plist" | grep -q "$CONTAINER_ID"
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$TEMP_ROOT/effective-entitlements.plist")" = "Production" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$TEMP_ROOT/effective-entitlements.plist")" = "production" ]

INFO_PLIST="$APP/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" = "$EXPECTED_VERSION" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")" = "$EXPECTED_BUILD" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$INFO_PLIST")" = "false" ]
[ -f "$APP/PrivacyInfo.xcprivacy" ] || {
    echo "PrivacyInfo.xcprivacy is missing from the exported app." >&2
    exit 1
}
[ -f "$APP/Assets.car" ] || {
    echo "Compiled App Store icon assets are missing." >&2
    exit 1
}
xcrun assetutil --info "$APP/Assets.car" | grep -q 'StraightUpBrowser' || {
    echo "The Straight Up Browser app icon is missing from Assets.car." >&2
    exit 1
}

PROFILE="$APP/embedded.mobileprovision"
[ -f "$PROFILE" ] || { echo "The App Store profile is missing." >&2; exit 1; }
security cms -D -i "$PROFILE" > "$TEMP_ROOT/profile.plist"
/usr/libexec/PlistBuddy -c \
    "Print :Entitlements:com.apple.developer.icloud-container-identifiers" \
    "$TEMP_ROOT/profile.plist" | grep -q "$CONTAINER_ID"
[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$TEMP_ROOT/profile.plist")" = "false" ]

echo "App Store archive ready: $IPA"
