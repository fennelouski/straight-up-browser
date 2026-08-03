#!/bin/bash
#
# Builds, signs, notarizes, and staples a distributable Browser.dmg.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate:
#      Xcode -> Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application
#   2. Store notarization credentials (app-specific password from account.apple.com):
#      xcrun notarytool store-credentials notary --apple-id nathanfennel@gmail.com --team-id EJLR2RPSV2
#
# Usage: ./scripts/release.sh          (override profile with NOTARY_PROFILE=name)
# Output: build/release/Browser.dmg — upload this to the website.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Straight Up Browser.xcodeproj"
SCHEME="Browser"
PROFILE="${NOTARY_PROFILE:-notary}"
BUILD="build/release"
SIGNING_IDENTITY="Developer ID Application: Nathan Fennel (EJLR2RPSV2)"

# The release scheme is shared in source control; verify it still resolves.
xcodebuild -list -project "$PROJECT" 2>/dev/null | grep -q "^        $SCHEME\$" || {
    echo "Shared scheme '$SCHEME' not found."
    exit 1
}

# A release must identify one immutable, published source revision. Version tags
# use the visible marketing version, for example v1.14.2. The build number stays
# separate in the bundle and release provenance.
if [ -n "$(git status --porcelain)" ]; then
    echo "Release worktree is not clean. Commit every source change before releasing."
    exit 1
fi
SOURCE_COMMIT="$(git rev-parse HEAD)"
SOURCE_TAG="$(git describe --tags --exact-match "$SOURCE_COMMIT" 2>/dev/null || true)"
BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -target "$SCHEME" -configuration Release -showBuildSettings)"
MARKETING_VERSION="$(printf '%s\n' "$BUILD_SETTINGS" | awk '/ MARKETING_VERSION = / { print $3; exit }')"
BUILD_NUMBER="$(printf '%s\n' "$BUILD_SETTINGS" | awk '/ CURRENT_PROJECT_VERSION = / { print $3; exit }')"
EXPECTED_TAG="v${MARKETING_VERSION}"
if [ "$SOURCE_TAG" != "$EXPECTED_TAG" ]; then
    echo "Release commit must have exact tag '$EXPECTED_TAG' (found '${SOURCE_TAG:-none}')."
    exit 1
fi
git fetch --quiet origin main
if ! git merge-base --is-ancestor "$SOURCE_COMMIT" origin/main; then
    echo "Release commit $SOURCE_COMMIT is not published on origin/main."
    exit 1
fi

# Fail before the costly build if any identity, notarization, or update-signing
# credential required by the finished release is unavailable.
security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\"" || {
    echo "Required signing identity '$SIGNING_IDENTITY' is not in the keychain."
    exit 1
}
security find-generic-password \
    -s "https://sparkle-project.org" \
    -a ed25519 >/dev/null || {
    echo "Sparkle EdDSA signing key is not in the keychain."
    exit 1
}
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null || {
    echo "Notarization profile '$PROFILE' is unavailable or invalid."
    exit 1
}

# Never archive a release that has not passed the same gates as CI.
RUN_UI_TESTS="${RUN_UI_TESTS:-1}" ./scripts/verify.sh

rm -rf "$BUILD"
mkdir -p "$BUILD"

xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -onlyUsePackageVersionsFromResolvedFile \
    -archivePath "$BUILD/Browser.xcarchive" -allowProvisioningUpdates \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES

cat > "$BUILD/exportOptions.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>EJLR2RPSV2</string>
    <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF

xcodebuild -exportArchive -archivePath "$BUILD/Browser.xcarchive" \
    -exportOptionsPlist "$BUILD/exportOptions.plist" -exportPath "$BUILD/export" \
    -allowProvisioningUpdates

STAGE="$BUILD/dmg"
DMG="$BUILD/Browser.dmg"
APP="$BUILD/export/Browser.app"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Verify that the exported bundle is the tagged build and that every nested
# executable has a valid Developer ID signature before notarization.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [ "$APP_VERSION" != "$MARKETING_VERSION" ] || [ "$APP_BUILD" != "$BUILD_NUMBER" ]; then
    echo "Exported app version $APP_VERSION ($APP_BUILD) does not match the expected build settings."
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize and staple the app itself before it goes into the DMG, so a
# first launch works offline; the DMG gets its own ticket below.
ditto -c -k --keepParent "$STAGE/Browser.app" "$BUILD/Browser.zip"
xcrun notarytool submit "$BUILD/Browser.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$STAGE/Browser.app"
xcrun stapler validate "$STAGE/Browser.app"
spctl -a -t exec -vv "$STAGE/Browser.app"

hdiutil create -volname "Browser" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

codesign --force --sign "$SIGNING_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

# Verify the actual application inside the finished disk image, not only the
# staging copy used to create it.
MOUNT_POINT="$(mktemp -d /tmp/straight-up-browser-release.XXXXXX)"
cleanup_mount() {
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
test -x "$MOUNT_POINT/Browser.app/Contents/MacOS/Browser"
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/Browser.app"
spctl -a -t exec -vv "$MOUNT_POINT/Browser.app"
cleanup_mount
trap - EXIT

# Sparkle appcast: reads the version out of the stapled DMG and signs it with
# the EdDSA private key in this Mac's Keychain (scripts/sparkle-bin/generate_keys
# put it there — see DEPLOYMENT.md). $BUILD holds only this release's DMG, so
# the feed always describes just the latest version (no delta patches).
# Browser.zip was only an intermediate for notarizing the .app before it went
# into the DMG — generate_appcast would otherwise see it as a duplicate of the
# same version and refuse to run.
# Filename is "browser-appcast.xml", not the generic "appcast.xml" — that name
# is already taken by another app's feed (Dictate) in the same downloads
# folder on nathanfennel.com. Must match SUFeedURL in Browser-Info.plist.
rm -f "$BUILD/Browser.zip"
./scripts/sparkle-bin/generate_appcast \
    --download-url-prefix "https://nathanfennel.com/downloads/" \
    --link "https://nathanfennel.com/internet" \
    -o "$BUILD/browser-appcast.xml" \
    "$BUILD"

APPCAST="$BUILD/browser-appcast.xml"
APPCAST_URL="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$APPCAST")"
APPCAST_VERSION="$(xmllint --xpath 'string(//*[local-name()="item"]/*[local-name()="shortVersionString"])' "$APPCAST")"
APPCAST_BUILD="$(xmllint --xpath 'string(//*[local-name()="item"]/*[local-name()="version"])' "$APPCAST")"
APPCAST_LENGTH="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@length)' "$APPCAST")"
APPCAST_SIGNATURE="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST")"
DMG_LENGTH="$(stat -f%z "$DMG")"
EXPECTED_APPCAST_URL="https://nathanfennel.com/downloads/Browser.dmg"
if [ "$APPCAST_URL" != "$EXPECTED_APPCAST_URL" ] ||
   [ "$APPCAST_VERSION" != "$MARKETING_VERSION" ] ||
   [ "$APPCAST_BUILD" != "$BUILD_NUMBER" ] ||
   [ "$APPCAST_LENGTH" != "$DMG_LENGTH" ] ||
   [ -z "$APPCAST_SIGNATURE" ]; then
    echo "Generated appcast does not match the signed DMG." >&2
    exit 1
fi

DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
APPCAST_SHA256="$(shasum -a 256 "$APPCAST" | awk '{ print $1 }')"
printf '%s  %s\n' "$DMG_SHA256" "Browser.dmg" > "$BUILD/Browser.dmg.sha256"

PROVENANCE="$BUILD/release-provenance.json"
jq -n \
    --arg commit "$SOURCE_COMMIT" \
    --arg tag "$SOURCE_TAG" \
    --arg commit_timestamp "$(git show -s --format=%cI "$SOURCE_COMMIT")" \
    --arg marketing_version "$MARKETING_VERSION" \
    --arg build_number "$BUILD_NUMBER" \
    --arg xcode "$(xcodebuild -version | paste -sd ' ' -)" \
    --arg dmg_sha256 "$DMG_SHA256" \
    --arg appcast_sha256 "$APPCAST_SHA256" \
    '{
      source: {
        commit: $commit,
        tag: $tag,
        commitTimestamp: $commit_timestamp
      },
      build: {
        marketingVersion: $marketing_version,
        number: $build_number,
        xcode: $xcode,
        architecture: "arm64"
      },
      artifacts: {
        dmgSHA256: $dmg_sha256,
        appcastSHA256: $appcast_sha256
      }
    }' > "$PROVENANCE"

echo "Ready to upload:"
echo "  $DMG"
echo "  $BUILD/browser-appcast.xml"
echo "  $BUILD/Browser.dmg.sha256"
echo "  $PROVENANCE"
